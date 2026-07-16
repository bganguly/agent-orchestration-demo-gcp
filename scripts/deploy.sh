#!/usr/bin/env bash
# deploy.sh — agent-orchestration-demo: local dev, GCP Cloud Run, or AWS ECS
# Usage: ./scripts/deploy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env.gcp"
BACKEND_SVC="agent-backend"
FRONTEND_SVC="agent-frontend"
AR_REPO="agent-demo"
SA_NAME="agent-runner"

_aws_tf_ws_count() {
  local ws="$1"
  local state_file="$ROOT/infra/aws/terraform.tfstate.d/$ws/terraform.tfstate"
  [[ -f "$state_file" ]] || { printf '0'; return; }
  python3 -c "import json; d=json.load(open('$state_file')); print(sum(len(r.get('instances',[])) for r in d.get('resources',[])))" 2>/dev/null || printf '0'
}
_aws_lite_count=$(_aws_tf_ws_count lite)

printf '\n=== agent-orchestration-demo ===\n\n'
printf '  [1] Local  — uvicorn + npm dev, no Docker (Redis via .env)\n'
printf '  [2] Cloud  — GCP Cloud Run\n'
printf '  [3] Lite   — AWS: ECS Fargate  (~$20-35/mo if left running)'
(( _aws_lite_count > 0 )) && printf ' [%s resources active]' "$_aws_lite_count" || printf ' [not deployed]'
printf '\n\nChoice [1/2/3]: '
read -r _MODE
case "$_MODE" in
  2) TARGET="cloud" ;;
  3) TARGET="aws"; DEPLOY_WORKSPACE="lite"; TF_VAR_name_prefix="agent-lite"
     TF_VAR_be_task_cpu=512;  TF_VAR_be_task_memory=1024
     TF_VAR_fe_task_cpu=256;  TF_VAR_fe_task_memory=512
     export DEPLOY_WORKSPACE TF_VAR_name_prefix TF_VAR_be_task_cpu TF_VAR_be_task_memory
     export TF_VAR_fe_task_cpu TF_VAR_fe_task_memory
     ;;
  *) TARGET="local" ;;
esac

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

# ── GCP Cloud Run ─────────────────────────────────────────────────────────────
if [[ "$TARGET" == "cloud" ]]; then
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
  --set-env-vars="ANTHROPIC_API_KEY=${ANTHROPIC_KEY},OPENAI_API_KEY=${OPENAI_KEY},CORS_ORIGINS=*" \
  --allow-unauthenticated \
  --min-instances=0 \
  --timeout=300 \
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
BACKEND_URL=${BACKEND_URL}
FRONTEND_URL=${FRONTEND_URL}
ENVEOF

printf '\n=== Agent Orchestration Demo deployed ===\n'
printf '  App:  %s\n' "$FRONTEND_URL"
printf '  API:  %s/docs\n' "$BACKEND_URL"
printf '\nTear down: ./scripts/infra-down.sh --cloud\n'
exit 0
fi

# ── AWS ECS ───────────────────────────────────────────────────────────────────
printf '\n--- AWS Lite summary ---\n'
printf '  Backend:  ECS Fargate 0.5 vCPU / 1 GB + Redis sidecar\n'
printf '  Frontend: ECS Fargate 0.25 vCPU / 0.5 GB\n'
printf '  Cost est: ~$20-35/mo if left running — TEAR DOWN when done\n'
printf '\nProceed? [Y/n] '
read -r _CONFIRM
[[ -z "$_CONFIRM" || "$_CONFIRM" =~ ^[Yy]$ ]] || { printf 'Aborted.\n'; exit 0; }

echo ""
echo "[1/4] Checking AWS credentials..."
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  printf '  AWS credentials not found or invalid.\n'; exit 1
fi
printf '  Credentials valid.\n'
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo ""
echo "[2/4] Provisioning AWS infra (ECS cluster, ALB, ECR, EventBridge)..."
"$ROOT/scripts/infra-up-aws.sh"

INFRA_DIR="$ROOT/infra/aws"
cd "$INFRA_DIR"
terraform workspace select "$DEPLOY_WORKSPACE" >/dev/null

FRONTEND_URL=$(terraform output -raw frontend_url)
BACKEND_URL=$(terraform output -raw backend_url)
BE_ECR_URI=$(terraform output -raw backend_ecr_uri)
FE_ECR_URI=$(terraform output -raw frontend_ecr_uri)
CLUSTER_NAME=$(terraform output -raw cluster_name)
BE_SVC=$(terraform output -raw backend_service)
FE_SVC=$(terraform output -raw frontend_service)
AWS_REGION=$(terraform output -raw aws_region)

echo ""
echo "[3/4] Building and pushing Docker images to ECR..."
if ! docker info >/dev/null 2>&1; then
  printf '  Docker not running — start Docker Desktop and retry.\n'; exit 1
fi
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

TAG=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)

printf '  Building backend...\n'
docker build --platform linux/amd64 -t "${BE_ECR_URI}:${TAG}" "$ROOT/backend"
docker push "${BE_ECR_URI}:${TAG}"

printf '  Building frontend...\n'
docker build --platform linux/amd64 \
  --build-arg NEXT_PUBLIC_BACKEND_URL="$BACKEND_URL" \
  -t "${FE_ECR_URI}:${TAG}" "$ROOT/frontend"
docker push "${FE_ECR_URI}:${TAG}"

echo ""
echo "[4/4] Updating SSM parameters and deploying to ECS..."
[[ -f "$ROOT/.env" ]] && source "$ROOT/.env" || true
for _pair in "anthropic-key:${ANTHROPIC_API_KEY:-}" "openai-key:${OPENAI_API_KEY:-}"; do
  _pname="/${TF_VAR_name_prefix}/${_pair%%:*}"
  _pval="${_pair#*:}"
  [[ -z "$_pval" ]] && continue
  aws ssm put-parameter --name "$_pname" --value "$_pval" \
    --type SecureString --overwrite --no-cli-pager >/dev/null
  printf '  Updated SSM: %s\n' "$_pname"
done

ANTHROPIC_API_KEY=$(aws ssm get-parameter --name "/${TF_VAR_name_prefix}/anthropic-key" --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")
OPENAI_API_KEY=$(aws ssm get-parameter --name "/${TF_VAR_name_prefix}/openai-key" --with-decryption --query Parameter.Value --output text 2>/dev/null || echo "")

_register_task_def() {
  local family="$1" image="$2" extra_env="$3"
  local cur_def
  cur_def=$(aws ecs describe-task-definition --task-definition "$family" --output json 2>/dev/null \
    | python3 -c "import json,sys; td=json.load(sys.stdin)['taskDefinition']; \
      [td.pop(k,None) for k in ['taskDefinitionArn','revision','status','requiresAttributes','compatibilities','registeredAt','registeredBy','deregisteredAt']]; \
      print(json.dumps(td))" 2>/dev/null || echo "")
  [[ -z "$cur_def" ]] && { printf '  Task definition %s not found.\n' "$family"; return 1; }
  local new_def
  new_def=$(printf '%s' "$cur_def" | python3 - "$image" "$extra_env" <<'PYEOF'
import json, sys
image, extra_env_json = sys.argv[1], sys.argv[2]
td = json.load(sys.stdin)
extra_env = json.loads(extra_env_json) if extra_env_json else []
app = next((c for c in td['containerDefinitions'] if c['name'] == 'app'), None)
if app:
    app['image'] = image
    existing = {e['name'] for e in app.get('environment', [])}
    for e in extra_env:
        if e['name'] not in existing:
            app.setdefault('environment', []).append(e)
print(json.dumps(td))
PYEOF
)
  aws ecs register-task-definition --cli-input-json "$new_def" \
    --query "taskDefinition.taskDefinitionArn" --output text --no-cli-pager
}

BE_EXTRA=$(python3 -c "import json; print(json.dumps([e for e in [
  {'name':'REDIS_URL','value':'redis://localhost:6379'},
  {'name':'ANTHROPIC_API_KEY','value':'${ANTHROPIC_API_KEY}'},
  {'name':'OPENAI_API_KEY','value':'${OPENAI_API_KEY}'},
] if e['value']]))")
BE_TASK_ARN=$(_register_task_def "${TF_VAR_name_prefix}-backend" "${BE_ECR_URI}:${TAG}" "$BE_EXTRA")
FE_EXTRA=$(python3 -c "import json; print(json.dumps([e for e in [
  {'name':'BACKEND_URL','value':'${BACKEND_URL}'},
  {'name':'ANTHROPIC_API_KEY','value':'${ANTHROPIC_API_KEY}'},
  {'name':'OPENAI_API_KEY','value':'${OPENAI_API_KEY}'},
] if e['value']]))")
FE_TASK_ARN=$(_register_task_def "${TF_VAR_name_prefix}-frontend" "${FE_ECR_URI}:${TAG}" "$FE_EXTRA")

aws ecs update-service --cluster "$CLUSTER_NAME" --service "$BE_SVC" \
  --task-definition "$BE_TASK_ARN" --force-new-deployment --no-cli-pager >/dev/null
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$FE_SVC" \
  --task-definition "$FE_TASK_ARN" --force-new-deployment --no-cli-pager >/dev/null

printf '\n  Waiting for services to stabilize...\n'
aws ecs wait services-stable --cluster "$CLUSTER_NAME" --services "$BE_SVC" "$FE_SVC" \
  --region "$AWS_REGION" || printf '  (wait timed out — check ECS console)\n'

printf '\n✓ Agent Orchestration Demo live on AWS\n'
printf '  App:         %s\n' "$FRONTEND_URL"
printf '  API Docs:    %s/docs\n' "$BACKEND_URL"
printf '  Schedule:    8 am \xc2\xb7 5 pm PT weekdays\n'
printf '  Tear down:   ./scripts/infra-down.sh --aws\n'

PORTFOLIO_SET_LIVE="$(cd "$ROOT/../../portfolio/scripts" 2>/dev/null && pwd || true)/set-live-url.sh"
if [[ -f "$PORTFOLIO_SET_LIVE" ]]; then
  printf '\n  Updating portfolio live-urls.js...\n'
  bash "$PORTFOLIO_SET_LIVE" --tier "lite" agent "$FRONTEND_URL" "${BACKEND_URL}/docs"
fi
