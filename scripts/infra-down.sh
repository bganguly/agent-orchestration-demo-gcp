#!/usr/bin/env bash
# infra-down.sh — tear down local Docker, GCP Cloud Run, or AWS ECS resources
# Local:  ./scripts/infra-down.sh
# GCP:    ./scripts/infra-down.sh --cloud
# AWS:    ./scripts/infra-down.sh --aws [lite|full]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env.gcp"

if [[ "${1:-}" == "--aws" ]]; then
  DEPLOY_WORKSPACE="${2:-lite}"
  TF_VAR_name_prefix="agent-${DEPLOY_WORKSPACE}"

  _update_ecs_schedules() {
    local _state="$1"
    for _sched in "${TF_VAR_name_prefix}-start-be" "${TF_VAR_name_prefix}-stop-be" \
                  "${TF_VAR_name_prefix}-start-fe" "${TF_VAR_name_prefix}-stop-fe"; do
      if ! _cur=$(aws scheduler get-schedule --name "$_sched" --output json 2>/dev/null); then
        printf '  (schedule %s not found — run a full deploy first)\n' "$_sched"; continue
      fi
      _expr=$(printf '%s' "$_cur" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['ScheduleExpression'])" 2>/dev/null || true)
      _tz=$(printf '%s' "$_cur" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('ScheduleExpressionTimezone','America/Los_Angeles'))" 2>/dev/null || echo "America/Los_Angeles")
      _tgt=$(printf '%s' "$_cur" | python3 -c "import sys,json;d=json.load(sys.stdin);print(json.dumps(d['Target']))" 2>/dev/null || true)
      if aws scheduler update-schedule --name "$_sched" --state "$_state" \
          --schedule-expression "$_expr" --schedule-expression-timezone "$_tz" \
          --flexible-time-window '{"Mode":"OFF"}' --target "$_tgt" \
          --no-cli-pager >/dev/null 2>&1; then
        printf '  %-50s → %s\n' "$_sched" "$_state"
      else
        printf '  ERROR: failed to update %s\n' "$_sched"
      fi
    done
  }

  _CLUSTER="${TF_VAR_name_prefix}-cluster"
  _BE_SVC="${TF_VAR_name_prefix}-backend"
  _FE_SVC="${TF_VAR_name_prefix}-frontend"
  _BE_DESIRED=$(aws ecs describe-services --cluster "$_CLUSTER" --services "$_BE_SVC" \
    --query "services[0].desiredCount" --output text 2>/dev/null || echo "0")
  _FE_DESIRED=$(aws ecs describe-services --cluster "$_CLUSTER" --services "$_FE_SVC" \
    --query "services[0].desiredCount" --output text 2>/dev/null || echo "0")
  _SCHED_STATE=$(aws scheduler get-schedule --name "${TF_VAR_name_prefix}-start-be" \
    --query "State" --output text 2>/dev/null || echo "NOT_CREATED")

  printf '\n  Backend desired=%s  Frontend desired=%s  schedule=%s\n' \
    "$_BE_DESIRED" "$_FE_DESIRED" "$_SCHED_STATE"
  printf '  [1] Start now  [2] Stop now  [3] Suspend schedule  [4] Resume schedule  [enter] Tear down: '
  read -r _PRE
  case "${_PRE:-}" in
    1)
      aws ecs update-service --cluster "$_CLUSTER" --service "$_BE_SVC" --desired-count 1 --no-cli-pager >/dev/null
      aws ecs update-service --cluster "$_CLUSTER" --service "$_FE_SVC" --desired-count 1 --no-cli-pager >/dev/null
      printf '  Services starting.\n'; exit 0 ;;
    2)
      aws ecs update-service --cluster "$_CLUSTER" --service "$_BE_SVC" --desired-count 0 --no-cli-pager >/dev/null
      aws ecs update-service --cluster "$_CLUSTER" --service "$_FE_SVC" --desired-count 0 --no-cli-pager >/dev/null
      printf '  Services stopped.\n'; exit 0 ;;
    3)
      [[ "$_SCHED_STATE" == "NOT_CREATED" ]] && { printf '  Schedules not created yet — run a full deploy first.\n'; exit 1; }
      aws ecs update-service --cluster "$_CLUSTER" --service "$_BE_SVC" --desired-count 0 --no-cli-pager >/dev/null 2>&1 || true
      aws ecs update-service --cluster "$_CLUSTER" --service "$_FE_SVC" --desired-count 0 --no-cli-pager >/dev/null 2>&1 || true
      _update_ecs_schedules "DISABLED"; printf '  Schedule suspended.\n'; exit 0 ;;
    4)
      [[ "$_SCHED_STATE" == "NOT_CREATED" ]] && { printf '  Schedules not created yet — run a full deploy first.\n'; exit 1; }
      _update_ecs_schedules "ENABLED"; printf '  Schedule resumed.\n'; exit 0 ;;
  esac

  INFRA_DIR="$ROOT/infra/aws"

  printf 'Tearing down AWS resources for %s...\n' "$TF_VAR_name_prefix"
  cd "$INFRA_DIR"
  terraform init -upgrade -input=false >/dev/null
  terraform workspace select "$DEPLOY_WORKSPACE" 2>/dev/null || { printf 'Workspace %s not found.\n' "$DEPLOY_WORKSPACE"; exit 0; }
  terraform destroy -auto-approve -var "name_prefix=${TF_VAR_name_prefix}"

  PORTFOLIO_SET_LIVE="$(cd "$ROOT/../../portfolio/scripts" 2>/dev/null && pwd || true)/set-live-url.sh"
  if [[ -f "$PORTFOLIO_SET_LIVE" ]]; then
    bash "$PORTFOLIO_SET_LIVE" --tier "$DEPLOY_WORKSPACE" --down agent
  fi
  printf 'AWS infrastructure torn down.\n'

elif [[ "${1:-}" == "--cloud" ]]; then
  [[ -f "$ENV_FILE" ]] || { printf '.env.gcp not found — nothing to tear down.\n'; exit 0; }
  source "$ENV_FILE"
  printf 'Tearing down GCP resources for project %s...\n' "$GCP_PROJECT"

  gcloud run services delete agent-frontend \
    --region="$GCP_REGION" --project="$GCP_PROJECT" --quiet 2>/dev/null || true
  gcloud run services delete agent-backend \
    --region="$GCP_REGION" --project="$GCP_PROJECT" --quiet 2>/dev/null || true

  rm -f "$ENV_FILE"
  printf 'GCP infrastructure torn down.\n'

else
  docker compose -f "$ROOT/docker-compose.yml" down -v
  printf 'Local infrastructure torn down.\n'
fi
