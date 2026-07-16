#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT_DIR/infra/aws"

cd "$INFRA_DIR"
terraform init -upgrade -input=false

terraform workspace select "$DEPLOY_WORKSPACE" 2>/dev/null \
  || terraform workspace new "$DEPLOY_WORKSPACE"

terraform apply -auto-approve \
  -var "name_prefix=${TF_VAR_name_prefix}" \
  -var "be_task_cpu=${TF_VAR_be_task_cpu:-512}" \
  -var "be_task_memory=${TF_VAR_be_task_memory:-1024}" \
  -var "fe_task_cpu=${TF_VAR_fe_task_cpu:-256}" \
  -var "fe_task_memory=${TF_VAR_fe_task_memory:-512}"
