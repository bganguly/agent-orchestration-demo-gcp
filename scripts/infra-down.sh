#!/usr/bin/env bash
# infra-down.sh — stop local dev processes or tear down GCP resources
# Usage: ./scripts/infra-down.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env.gcp"
BACKEND_SVC="agent-backend"
FRONTEND_SVC="agent-frontend"
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

printf '\n=== agent-orchestration-demo teardown ===\n\n'
printf '  [1] Local  — stop uvicorn + Next.js dev processes'
(( _local_running )) && printf ' [running]' || printf ' [not detected]'
printf '\n'
printf '  [2] Cloud  — delete GCP resources'
if (( _gcp_deployed )); then
  printf ' [deployed: %s]' "$_current_runtime"
else
  printf ' [not deployed]'
fi
printf '\n'
printf '\nChoice [1/2]: '
read -r _MODE
case "$_MODE" in
  2) _TARGET="cloud" ;;
  *) _TARGET="local" ;;
esac

# ── local ─────────────────────────────────────────────────────────────────────
if [[ "$_TARGET" == "local" ]]; then
  _stopped=0
  for _port in 8002 3011; do
    _pid="$(lsof -ti:${_port} 2>/dev/null || true)"
    if [[ -n "$_pid" ]]; then
      kill "$_pid" 2>/dev/null && printf '  Stopped process on :%s\n' "$_port" || true
      _stopped=1
    fi
  done
  (( _stopped )) || printf '  No processes found on :8002 or :3011.\n'
  printf 'Local processes stopped.\n'
  exit 0
fi

# ── GCP ───────────────────────────────────────────────────────────────────────
[[ -f "$ENV_FILE" ]] || { printf '.env.gcp not found — nothing to tear down.\n'; exit 0; }
source "$ENV_FILE"
printf '\nTearing down GCP resources for project %s...\n' "$GCP_PROJECT"

_GKE_ZONE="${GCP_REGION}-a"

gcloud run services delete "$FRONTEND_SVC" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" --quiet 2>/dev/null || true
gcloud run services delete "$BACKEND_SVC" \
  --region="$GCP_REGION" --project="$GCP_PROJECT" --quiet 2>/dev/null || true

if gcloud container clusters describe "$GKE_CLUSTER" \
    --zone "$_GKE_ZONE" --project "$GCP_PROJECT" >/dev/null 2>&1; then
  printf '  Deleting GKE cluster %s...\n' "$GKE_CLUSTER"
  gcloud container clusters delete "$GKE_CLUSTER" \
    --zone "$_GKE_ZONE" --project "$GCP_PROJECT" --quiet
fi

rm -f "$ENV_FILE"
printf 'GCP infrastructure torn down.\n'
