#!/usr/bin/env bash
# deploy.sh — agent-orchestration-demo: local dev or GCP (Cloud Run / GKE)
# Usage: ./scripts/deploy.sh
set -euo pipefail
_STEP="startup"
_on_exit() { local c=$?; [[ $c -ne 0 ]] && printf '\n[deploy.sh] ABORTED (exit %d) at step: %s\n' "$c" "$_STEP" >&2; }
trap _on_exit EXIT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env.gcp"
BACKEND_SVC="agent-backend"
FRONTEND_SVC="agent-frontend"
AR_REPO="agent-demo"
SA_NAME="agent-runner"
GKE_CLUSTER="agent-demo-cluster"

_local_running=0
lsof -ti:8002 >/dev/null 2>&1 && _local_running=1 || true
_gcp_deployed=0
[[ -f "$ENV_FILE" ]] && _gcp_deployed=1 || true
_current_runtime="cr"
if [[ -f "$ENV_FILE" ]]; then
  _cr=$(grep '^BACKEND_RUNTIME=' "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
  _current_runtime="${_cr:-cr}"
fi

printf '\n=== agent-orchestration-demo ===\n\n'
printf '  [1] Local  — uvicorn + npm dev, no Docker (Redis via .env)'
(( _local_running )) && printf ' [running]' || printf ' [not detected]'
printf '\n'
printf '  [2] Cloud  — GCP'
if (( _gcp_deployed )); then
  printf ' [deployed: %s]' "$_current_runtime"
else
  printf ' [not deployed]'
fi
printf '\n'
printf '\nChoice [1/2, default 2]: '
read -r _MODE
_MODE="${_MODE:-2}"
case "$_MODE" in
  2) TARGET="cloud" ;;
  *) TARGET="local" ;;
esac

# ── local mode (no Docker) ────────────────────────────────────────────────────
if [[ "$TARGET" == "local" ]]; then
  [[ -f "$ROOT/.env" ]] || { echo "Error: .env not found. Copy .env.example and fill in ANTHROPIC_API_KEY and REDIS_URL."; exit 1; }
  source "$ROOT/.env"
  if [[ -z "${REDIS_URL:-}" ]]; then
    printf '\nREDIS_URL not set in .env.\n'
    printf '  Remote: add the Redis URL from your deployed Cloud Run stack.\n'
    printf '  Local:  brew install redis && brew services start redis\n'
    printf '          then set REDIS_URL=redis://localhost:6379 in .env\n\n'
    exit 1
  fi

  cd "$ROOT/backend"
  [[ -d .venv ]] || python3 -m venv .venv
  source .venv/bin/activate
  pip install -q -r requirements.txt
  cp "$ROOT/.env" "$ROOT/backend/.env" 2>/dev/null || true
  uvicorn app.main:app --host 0.0.0.0 --port 8002 --reload &
  BACKEND_PID=$!
  echo "Backend  → http://localhost:8002/docs"

  cd "$ROOT/frontend"
  [[ -d node_modules ]] || npm install
  grep -E '^(ANTHROPIC|NVIDIA|BACKEND)' "$ROOT/.env" > "$ROOT/frontend/.env.local" 2>/dev/null || true
  echo "BACKEND_URL=http://localhost:8002" >> "$ROOT/frontend/.env.local"
  npm run dev &
  FRONTEND_PID=$!
  echo "Frontend → http://localhost:3011"

  _cleanup() { kill "$BACKEND_PID" "$FRONTEND_PID" 2>/dev/null || true; }
  trap _cleanup EXIT INT TERM
  wait "$BACKEND_PID" "$FRONTEND_PID"
  exit 0
fi

# ── Cloud mode: choose backend runtime ────────────────────────────────────────
printf '\n  Backend runtime:\n'
printf '  [1] Cloud Run — serverless, scales to zero\n'
printf '  [2] GKE       — Kubernetes on e2-standard-2 node (~$50/mo while running)\n'
if [[ "$_current_runtime" == "gke" ]]; then
  printf '\nChoice [1/2, default 2 — gke (current)]: '
else
  printf '\nChoice [1/2, default 1 — cr]: '
fi
read -r _BR
case "$_BR" in
  1) BACKEND_RUNTIME="cr" ;;
  2) BACKEND_RUNTIME="gke" ;;
  *) BACKEND_RUNTIME="$_current_runtime" ;;
esac

# ── gcloud check ──────────────────────────────────────────────────────────────
if ! command -v gcloud >/dev/null 2>&1; then
  printf '\ngcloud CLI not found.\n'
  if command -v brew >/dev/null 2>&1; then
    printf 'Installing via Homebrew...\n'
    brew install --cask google-cloud-sdk
    source "$(brew --prefix)/share/google-cloud-sdk/path.bash.inc" 2>/dev/null || true
  else
    printf 'Install from: https://cloud.google.com/sdk/docs/install\n'
    exit 1
  fi
fi

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
if [[ -z "$ACTIVE_ACCOUNT" ]]; then
  printf '\nNot authenticated — logging in...\n'
  gcloud auth login
  ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1 || true)
  [[ -n "$ACTIVE_ACCOUNT" ]] || { printf 'Login did not complete.\n' >&2; exit 1; }
fi
printf '\nAuthenticated as: %s\n' "$ACTIVE_ACCOUNT"

printf '  Checking Application Default Credentials...\n'
if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  printf '  Setting up Application Default Credentials...\n'
  gcloud auth application-default login
fi

# ── project / region ──────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
_CONFIG_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
GCP_PROJECT="${_CONFIG_PROJECT:-${GCP_PROJECT:-}}"
[[ -n "$GCP_PROJECT" ]] || { printf 'Set GCP_PROJECT or: gcloud config set project <id>\n' >&2; exit 1; }
_CONFIG_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
GCP_REGION="${_CONFIG_REGION:-${GCP_REGION:-us-central1}}"
printf '\n=== deployment config ===\n  Project: %s\n  Region:  %s\n  Runtime: %s\n' "$GCP_PROJECT" "$GCP_REGION" "$BACKEND_RUNTIME"

_shasum() { shasum -a 256 "$@" 2>/dev/null || sha256sum "$@" 2>/dev/null; }
TAG=$(find "$ROOT/backend" "$ROOT/frontend" -type f \
  \( -name "*.py" -o -name "*.ts" -o -name "*.tsx" -o -name "*.js" \
     -o -name "Dockerfile" -o -name "requirements.txt" -o -name "package.json" \) \
  | sort | xargs cat 2>/dev/null | _shasum | cut -c1-16 || true)
TAG="${TAG:-$(date +%Y%m%d%H%M%S)}"

# ── enable APIs ───────────────────────────────────────────────────────────────
_STEP="enable APIs"
printf '\nEnabling APIs...\n'
_APIS="artifactregistry.googleapis.com run.googleapis.com cloudbuild.googleapis.com secretmanager.googleapis.com"
[[ "$BACKEND_RUNTIME" == "gke" ]] && _APIS="$_APIS container.googleapis.com"
gcloud services enable $_APIS --project "$GCP_PROJECT" --quiet

# ── Artifact Registry ─────────────────────────────────────────────────────────
_STEP="artifact registry"
if ! gcloud artifacts repositories describe "$AR_REPO" \
     --project="$GCP_PROJECT" --location="$GCP_REGION" &>/dev/null; then
  printf '\nCreating Artifact Registry repo %s...\n' "$AR_REPO"
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker \
    --location="$GCP_REGION" \
    --project="$GCP_PROJECT"
fi
AR_HOST="${GCP_REGION}-docker.pkg.dev"
BACKEND_IMAGE="${AR_HOST}/${GCP_PROJECT}/${AR_REPO}/${BACKEND_SVC}:${TAG}"
FRONTEND_IMAGE="${AR_HOST}/${GCP_PROJECT}/${AR_REPO}/${FRONTEND_SVC}:${TAG}"

# ── service account ───────────────────────────────────────────────────────────
_STEP="service account"
SA_EMAIL="${SA_NAME}@${GCP_PROJECT}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT" &>/dev/null; then
  printf '\nCreating service account %s...\n' "$SA_EMAIL"
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="Agent Demo Cloud Run SA" \
    --project="$GCP_PROJECT"
fi
gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" --quiet 2>/dev/null || true

# ── API key secrets ───────────────────────────────────────────────────────────
_STEP="secrets"
function upsert_secret() {
  local NAME="$1" VALUE="$2"
  [[ -z "$VALUE" ]] && return
  local _EXISTING
  _EXISTING=$(gcloud secrets versions access latest --secret="$NAME" --project="$GCP_PROJECT" 2>/dev/null || true)
  if [[ "$_EXISTING" == "$VALUE" ]]; then
    printf '  Secret %s unchanged — skipping.\n' "$NAME"; return
  fi
  if gcloud secrets describe "$NAME" --project="$GCP_PROJECT" &>/dev/null; then
    echo -n "$VALUE" | gcloud secrets versions add "$NAME" --data-file=- --project="$GCP_PROJECT"
  else
    echo -n "$VALUE" | gcloud secrets create "$NAME" --data-file=- --project="$GCP_PROJECT"
    gcloud secrets add-iam-policy-binding "$NAME" --project="$GCP_PROJECT" \
      --member="serviceAccount:${SA_EMAIL}" --role="roles/secretmanager.secretAccessor" --quiet 2>/dev/null || true
  fi
}
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env"
upsert_secret agent-anthropic-key "${ANTHROPIC_API_KEY:-}"
upsert_secret agent-openai-key    "${OPENAI_API_KEY:-}"

ANTHROPIC_KEY=$(gcloud secrets versions access latest --secret=agent-anthropic-key --project="$GCP_PROJECT" 2>/dev/null || echo "")
OPENAI_KEY=$(gcloud secrets versions access latest --secret=agent-openai-key --project="$GCP_PROJECT" 2>/dev/null || echo "")

# ── build images via Cloud Build ──────────────────────────────────────────────
_cloudbuild_submit() {
  local tag="$1" project="$2" srcdir="$3"
  local attempt=0
  while (( attempt < 3 )); do
    attempt=$(( attempt + 1 ))
    set +e
    gcloud builds submit --tag "$tag" --project "$project" "$srcdir"
    local rc=$?
    set -e
    [[ "$rc" == "0" ]] && return 0
    [[ "$rc" == "130" ]] && { printf '\n[deploy] Build cancelled.\n'; exit 130; }
    if (( attempt < 3 )); then
      printf '  Cloud Build submit failed (attempt %d/3) — waiting 20s...\n' "$attempt"
      sleep 20
    fi
  done
  printf '[deploy] Cloud Build failed after 3 attempts.\n' >&2
  return 1
}

_ar_tag_exists() {
  gcloud artifacts docker tags list "${AR_HOST}/${GCP_PROJECT}/${AR_REPO}/$1" \
    --filter="tag=$2" --format="value(tag)" \
    --project "$GCP_PROJECT" 2>/dev/null | grep -q .
}

_STEP="build backend"
if _ar_tag_exists "$BACKEND_SVC" "$TAG"; then
  printf '\n[1/2] backend image %s already in AR — skipping build.\n' "$TAG"
else
  printf '\n[1/2] building backend via Cloud Build...\n'
  _cloudbuild_submit "$BACKEND_IMAGE" "$GCP_PROJECT" "$ROOT/backend"
fi

_STEP="build frontend"
if _ar_tag_exists "$FRONTEND_SVC" "$TAG"; then
  printf '\n[2/2] frontend image %s already in AR — skipping build.\n' "$TAG"
else
  printf '\n[2/2] building frontend via Cloud Build...\n'
  _cloudbuild_submit "$FRONTEND_IMAGE" "$GCP_PROJECT" "$ROOT/frontend"
fi

_GKE_ZONE="${GCP_REGION}-a"

# ── deploy backend ────────────────────────────────────────────────────────────
_STEP="deploy backend"
if [[ "$BACKEND_RUNTIME" == "gke" ]]; then

  if gcloud container clusters describe "$GKE_CLUSTER" \
      --zone "$_GKE_ZONE" --project "$GCP_PROJECT" >/dev/null 2>&1; then
    printf '\n  GKE cluster %s already exists.\n' "$GKE_CLUSTER"
    _CURRENT_NODES=$(gcloud container clusters describe "$GKE_CLUSTER" \
      --zone "$_GKE_ZONE" --project "$GCP_PROJECT" \
      --format="value(currentNodeCount)" 2>/dev/null || echo "0")
    if [[ "${_CURRENT_NODES:-0}" == "0" ]]; then
      printf '  Cluster at 0 nodes — scaling up to 1...\n'
      gcloud container clusters resize "$GKE_CLUSTER" \
        --node-pool default-pool --num-nodes 1 \
        --zone "$_GKE_ZONE" --project "$GCP_PROJECT" --quiet
      printf '  Node coming up — waiting 60s for readiness...\n'
      sleep 60
    fi
  else
    printf '\n  Creating GKE cluster %s (e2-standard-2, 1 node)...\n' "$GKE_CLUSTER"
    gcloud container clusters create "$GKE_CLUSTER" \
      --zone "$_GKE_ZONE" --project "$GCP_PROJECT" \
      --machine-type e2-standard-2 --num-nodes 1 \
      --quiet
  fi

  printf '\n  Deploying to GKE via Cloud Build...\n'
  gcloud builds submit \
    --config "${ROOT}/cloudbuild-gke.yaml" \
    --project "$GCP_PROJECT" \
    --substitutions "_IMAGE=${BACKEND_IMAGE},_CLUSTER=${GKE_CLUSTER},_ZONE=${_GKE_ZONE}" \
    "${ROOT}/k8s"

  printf '  Waiting for LoadBalancer IP...\n'
  gcloud container clusters get-credentials "$GKE_CLUSTER" \
    --zone "$_GKE_ZONE" --project "$GCP_PROJECT" --quiet
  _LB_IP=""
  for _i in $(seq 1 60); do
    _LB_IP=$(kubectl get svc agent-backend -n agent-demo \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    [[ -n "$_LB_IP" ]] && break
    printf '  waiting for LoadBalancer (%d/60)...\n' "$_i"; sleep 10
  done
  [[ -n "$_LB_IP" ]] || { printf 'ERROR: LoadBalancer IP never assigned.\n' >&2; exit 1; }
  BACKEND_URL="http://${_LB_IP}"
  printf '  Backend (GKE): %s\n' "$BACKEND_URL"

else

  printf '\nDeploying %s to Cloud Run...\n' "$BACKEND_SVC"
  gcloud run deploy "$BACKEND_SVC" \
    --image="$BACKEND_IMAGE" \
    --region="$GCP_REGION" \
    --project="$GCP_PROJECT" \
    --service-account="$SA_EMAIL" \
    --set-env-vars="ANTHROPIC_API_KEY=${ANTHROPIC_KEY},OPENAI_API_KEY=${OPENAI_KEY},CORS_ORIGINS=*" \
    --allow-unauthenticated \
    --min-instances=0 \
    --timeout=300 \
    --quiet

  BACKEND_URL=$(gcloud run services describe "$BACKEND_SVC" \
    --region="$GCP_REGION" --project="$GCP_PROJECT" \
    --format="value(status.url)")
  printf '  Backend (Cloud Run): %s\n' "$BACKEND_URL"

  if gcloud container clusters describe "$GKE_CLUSTER" \
      --zone "$_GKE_ZONE" --project "$GCP_PROJECT" >/dev/null 2>&1; then
    printf '  Switched to Cloud Run — scaling GKE cluster to 0 nodes...\n'
    gcloud container clusters resize "$GKE_CLUSTER" \
      --node-pool default-pool --num-nodes 0 \
      --zone "$_GKE_ZONE" --project "$GCP_PROJECT" --quiet
    printf '  GKE cluster preserved at 0 nodes — no node charges until next GKE deploy.\n'
  fi

fi

# ── deploy frontend (always Cloud Run) ───────────────────────────────────────
_STEP="deploy frontend"
printf '\nDeploying %s to Cloud Run...\n' "$FRONTEND_SVC"
gcloud run deploy "$FRONTEND_SVC" \
  --image="$FRONTEND_IMAGE" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT" \
  --service-account="$SA_EMAIL" \
  --set-env-vars="BACKEND_URL=${BACKEND_URL},ANTHROPIC_API_KEY=${ANTHROPIC_KEY}" \
  --allow-unauthenticated \
  --min-instances=0 \
  --quiet

FRONTEND_URL=$(gcloud run services describe "$FRONTEND_SVC" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" \
  --format="value(status.url)")

# ── persist cloud config ──────────────────────────────────────────────────────
cat > "$ENV_FILE" <<ENVEOF
GCP_PROJECT=${GCP_PROJECT}
GCP_REGION=${GCP_REGION}
AR_REPO=${AR_REPO}
BACKEND_RUNTIME=${BACKEND_RUNTIME}
BACKEND_URL=${BACKEND_URL}
FRONTEND_URL=${FRONTEND_URL}
ENVEOF

printf '\n=== Agent Orchestration Demo deployed ===\n'
printf '  App:  %s\n' "$FRONTEND_URL"
printf '  API:  %s/docs\n' "$BACKEND_URL"

# ── GKE: scale down outside working hours ─────────────────────────────────────
if [[ "$BACKEND_RUNTIME" == "gke" ]]; then
  _HOUR_PST=$(TZ="America/Los_Angeles" date +%H)
  _DOW_PST=$(TZ="America/Los_Angeles" date +%u)
  _OUTSIDE=0
  (( 10#$_HOUR_PST < 8 || 10#$_HOUR_PST >= 17 )) && _OUTSIDE=1 || true
  (( _DOW_PST >= 6 )) && _OUTSIDE=1 || true
  if (( _OUTSIDE )); then
    printf '\n=== outside working hours — scaling GKE nodes to 0 ===\n'
    gcloud container clusters resize "$GKE_CLUSTER" \
      --node-pool default-pool --num-nodes 0 \
      --zone "$_GKE_ZONE" --project "$GCP_PROJECT" --quiet
    printf '  Nodes stopped — app unreachable until next 8am PST weekday.\n'
  else
    printf '\n  GKE nodes active (within 8am-5pm PST weekdays).\n'
  fi
fi

# ── post-deploy health checks ─────────────────────────────────────────────────
_STEP="health checks"
printf '\n=== post-deploy checks ===\n'
_CP=0; _CF=0
_chk() {
  local n="$1" label="$2" ok="$3" detail="${4:-}"
  if [[ "$ok" == "1" ]]; then
    printf '  [%s] PASS  %s%s\n' "$n" "$label" "${detail:+  ($detail)}"
    _CP=$(( _CP + 1 ))
  else
    printf '  [%s] FAIL  %s%s\n' "$n" "$label" "${detail:+  — $detail}"
    _CF=$(( _CF + 1 ))
  fi
}

if [[ "$BACKEND_RUNTIME" != "gke" ]]; then
  _CR_BACKEND=$(gcloud run services describe "$BACKEND_SVC" \
    --region="$GCP_REGION" --project="$GCP_PROJECT" \
    --format="value(status.conditions[0].status)" 2>/dev/null || echo "unknown")
  [[ "$_CR_BACKEND" == "True" ]] \
    && _chk 1 "Cloud Run backend ready" 1 \
    || _chk 1 "Cloud Run backend ready" 0 "status: ${_CR_BACKEND}"
else
  _GKE_READY=$(kubectl get deployment "agent-backend" -n "agent-demo" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  [[ "${_GKE_READY:-0}" -ge 1 ]] \
    && _chk 1 "GKE deployment ready" 1 "${_GKE_READY} replica(s)" \
    || _chk 1 "GKE deployment ready" 0 "readyReplicas=${_GKE_READY:-0}"
fi

_HEALTH=$(curl -sf "${BACKEND_URL}/health" --max-time 10 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('status','ok'))" 2>/dev/null || echo "")
[[ -n "$_HEALTH" ]] \
  && _chk 2 "GET /health → ${_HEALTH}" 1 \
  || _chk 2 "GET /health → unreachable" 0

_CR_FRONTEND=$(gcloud run services describe "$FRONTEND_SVC" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" \
  --format="value(status.conditions[0].status)" 2>/dev/null || echo "unknown")
[[ "$_CR_FRONTEND" == "True" ]] \
  && _chk 3 "Cloud Run frontend ready" 1 \
  || _chk 3 "Cloud Run frontend ready" 0 "status: ${_CR_FRONTEND}"

_HTTP=$(curl -sf -o /dev/null -w "%{http_code}" "$FRONTEND_URL" --max-time 10 2>/dev/null || echo "000")
[[ "$_HTTP" == "200" ]] \
  && _chk 4 "GET frontend → 200" 1 \
  || _chk 4 "GET frontend → 200" 0 "HTTP $_HTTP"

printf '\n  Results: %d passed, %d failed\n' "$_CP" "$_CF"
(( _CF > 0 )) && printf '\n  !! %d CHECK(S) FAILED — review above before presenting\n' "$_CF" || true

printf '\nTear down: ./scripts/infra-down.sh\n'
