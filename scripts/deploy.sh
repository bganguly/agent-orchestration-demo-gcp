#!/usr/bin/env bash
# deploy.sh — build and deploy agent-orchestration-demo to GCP Cloud Run
# Provisions: Artifact Registry, Cloud Run (backend + frontend)
# No local Docker required — images built via Cloud Build.
# Usage: ./scripts/deploy.sh [local]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env.gcp"
BACKEND_SVC="agent-backend"
FRONTEND_SVC="agent-frontend"
AR_REPO="agent-demo"
SA_NAME="agent-runner"
TARGET="${1:-cloud}"

# ── local mode (no Docker) ────────────────────────────────────────────────────
# Redis runs remotely (deployed Cloud Run stack) or locally via brew.
# No Docker Compose needed — set REDIS_URL in .env to point at either.
#
# Remote Redis (already deployed):  REDIS_URL=<Cloud Run redis URL>
# Local Redis (brew):               brew install redis && brew services start redis
#                                   REDIS_URL=redis://localhost:6379
if [[ "$TARGET" == "local" ]]; then
  [[ -f "$ROOT/.env" ]] || { echo "Error: .env not found. Copy .env.example and fill in ANTHROPIC_API_KEY and REDIS_URL."; exit 1; }
  # shellcheck source=/dev/null
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
  # shellcheck source=/dev/null
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

# ── gcloud ────────────────────────────────────────────────────────────────────
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

# ── project / region ──────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
_CONFIG_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
GCP_PROJECT="${_CONFIG_PROJECT:-${GCP_PROJECT:-}}"
[[ -n "$GCP_PROJECT" ]] || { printf 'Set GCP_PROJECT or: gcloud config set project <id>\n' >&2; exit 1; }
_CONFIG_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
GCP_REGION="${_CONFIG_REGION:-${GCP_REGION:-us-central1}}"
printf '\n=== deployment config ===\n  Project: %s\n  Region:  %s\n' "$GCP_PROJECT" "$GCP_REGION"

_GIT_HASH=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)
TAG="${_GIT_HASH:+${_GIT_HASH}-}$(date +%Y%m%d%H%M%S)"

# ── enable APIs ───────────────────────────────────────────────────────────────
printf '\nEnabling APIs...\n'
gcloud services enable \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  secretmanager.googleapis.com \
  --project "$GCP_PROJECT" --quiet

# ── Artifact Registry ─────────────────────────────────────────────────────────
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
function upsert_secret() {
  local NAME="$1" VALUE="$2"
  [[ -z "$VALUE" ]] && return
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

# ── build images via Cloud Build (no local Docker required) ───────────────────
printf '\n[1/2] building backend via Cloud Build...\n'
gcloud builds submit \
  --tag "$BACKEND_IMAGE" \
  --project "$GCP_PROJECT" \
  "$ROOT/backend"

printf '\n[2/2] building frontend via Cloud Build...\n'
gcloud builds submit \
  --tag "$FRONTEND_IMAGE" \
  --project "$GCP_PROJECT" \
  "$ROOT/frontend"

# ── deploy backend ────────────────────────────────────────────────────────────
printf '\nDeploying %s to Cloud Run...\n' "$BACKEND_SVC"
gcloud run deploy "$BACKEND_SVC" \
  --image="$BACKEND_IMAGE" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT" \
  --service-account="$SA_EMAIL" \
  --set-env-vars="ANTHROPIC_API_KEY=${ANTHROPIC_KEY},OPENAI_API_KEY=${OPENAI_KEY}" \
  --allow-unauthenticated \
  --min-instances=1 \
  --quiet

BACKEND_URL=$(gcloud run services describe "$BACKEND_SVC" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" \
  --format="value(status.url)")
printf '  Backend: %s\n' "$BACKEND_URL"

# ── deploy frontend ───────────────────────────────────────────────────────────
printf '\nDeploying %s to Cloud Run...\n' "$FRONTEND_SVC"
gcloud run deploy "$FRONTEND_SVC" \
  --image="$FRONTEND_IMAGE" \
  --region="$GCP_REGION" \
  --project="$GCP_PROJECT" \
  --service-account="$SA_EMAIL" \
  --set-env-vars="BACKEND_URL=${BACKEND_URL},ANTHROPIC_API_KEY=${ANTHROPIC_KEY}" \
  --allow-unauthenticated \
  --min-instances=1 \
  --quiet

FRONTEND_URL=$(gcloud run services describe "$FRONTEND_SVC" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" \
  --format="value(status.url)")

# ── persist cloud config ──────────────────────────────────────────────────────
cat > "$ENV_FILE" <<ENVEOF
GCP_PROJECT=${GCP_PROJECT}
GCP_REGION=${GCP_REGION}
AR_REPO=${AR_REPO}
BACKEND_URL=${BACKEND_URL}
FRONTEND_URL=${FRONTEND_URL}
ENVEOF

printf '\n=== Agent Orchestration Demo deployed ===\n'
printf '  App:  %s\n' "$FRONTEND_URL"
printf '  API:  %s/docs\n' "$BACKEND_URL"
printf '\nTear down: ./scripts/infra-down.sh\n'
