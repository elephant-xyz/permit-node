#!/usr/bin/env bash
set -euo pipefail

# Unified deployment for SAM stack (MWAA + VPC + SQS + Lambdas)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

# Config with sane defaults
STACK_NAME="${STACK_NAME:-elephant-permit-node}"
SAM_TEMPLATE="prepare/template.yaml"
BUILT_TEMPLATE=".aws-sam/build/template.yaml"
STARTUP_SCRIPT="infra/startup.sh"
PYPROJECT_FILE="infra/pyproject.toml"
BUILD_DIR="infra/build"
REQUIREMENTS_FILE="${BUILD_DIR}/requirements.txt"
AIRFLOW_CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-2.10.3/constraints-3.12.txt"
WORKFLOW_DIR="workflow"
TRANSFORMS_SRC_DIR="transform"
TRANSFORMS_TARGET_ZIP="${WORKFLOW_DIR}/lambdas/post/transforms.zip"

mkdir -p "$BUILD_DIR"

check_prereqs() {
  info "Checking prerequisites..."
  command -v aws >/dev/null || { err "aws CLI not found"; exit 1; }
  aws sts get-caller-identity >/dev/null || { err "AWS credentials not configured"; exit 1; }
  command -v jq >/dev/null || { err "jq not found"; exit 1; }
  command -v zip >/dev/null || { err "zip not found"; exit 1; }
  command -v curl >/dev/null || { err "curl not found"; exit 1; }
  command -v uv >/dev/null || { err "uv not found. Install: https://docs.astral.sh/uv/getting-started/installation/"; exit 1; }
  command -v sam >/dev/null || { err "sam CLI not found. Install: https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html"; exit 1; }
  command -v git >/dev/null || { err "git not found"; exit 1; }
  command -v npm >/dev/null || { err "npm not found"; exit 1; }
  [[ -f "$SAM_TEMPLATE" && -f "$STARTUP_SCRIPT" && -f "$PYPROJECT_FILE" ]] || { err "Missing required files"; exit 1; }
}


get_bucket() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query 'Stacks[0].Outputs[?OutputKey==`EnvironmentBucketName`].OutputValue' \
    --output text
}

get_output() {
  local key=$1
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text
}

sam_build() {
  info "Building SAM application"
  sam build --template-file "$SAM_TEMPLATE" >/dev/null
}

sam_deploy() {
  info "Deploying SAM stack (initial)"
  sam deploy \
    --template-file "$BUILT_TEMPLATE" \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --resolve-s3 \
    --no-confirm-changeset \
    --no-fail-on-empty-changeset \
    --parameter-overrides "${PARAM_OVERRIDES:-}" >/dev/null
}

sam_deploy_with_versions() {
  local script_ver=$1 req_ver=$2
  info "Deploying SAM stack with MWAA artifact versions"
  sam deploy \
    --template-file "$BUILT_TEMPLATE" \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    --resolve-s3 \
    --no-confirm-changeset \
    --no-fail-on-empty-changeset \
    --parameter-overrides \
      "${PARAM_OVERRIDES:-}" \
      StartupScriptS3Path="startup.sh" \
      StartupScriptS3ObjectVersion="$script_ver" \
      RequirementsS3Path="requirements.txt" \
      RequirementsS3ObjectVersion="$req_ver" >/dev/null
}

compute_param_overrides() {
  # Check if using keystore mode
  if [[ -n "${ELEPHANT_KEYSTORE_FILE:-}" ]]; then
    # Keystore mode - verify requirements
    [[ ! -f "$ELEPHANT_KEYSTORE_FILE" ]] && { err "Keystore file not found: $ELEPHANT_KEYSTORE_FILE"; exit 1; }
    : "${ELEPHANT_KEYSTORE_PASSWORD?Set ELEPHANT_KEYSTORE_PASSWORD when using keystore}"
    : "${ELEPHANT_RPC_URL?Set ELEPHANT_RPC_URL}"
    : "${ELEPHANT_PINATA_JWT?Set ELEPHANT_PINATA_JWT}"

    # Upload keystore to S3 and get the S3 key
    info "Uploading keystore file to S3..."
    local keystore_s3_key="keystores/keystore-$(date +%s).json"
    local bucket=$(get_bucket 2>/dev/null || echo "")

    if [[ -z "$bucket" ]]; then
      # Bucket will be created during first deploy
      info "Bucket will be created during initial deployment"
      KEYSTORE_S3_KEY_PENDING="$keystore_s3_key"
      KEYSTORE_FILE_PENDING="$ELEPHANT_KEYSTORE_FILE"
    else
      aws s3 cp "$ELEPHANT_KEYSTORE_FILE" "s3://$bucket/$keystore_s3_key"
      ELEPHANT_KEYSTORE_S3_KEY="$keystore_s3_key"
    fi

    local parts=()
    parts+=("ElephantRpcUrl=\"$ELEPHANT_RPC_URL\"")
    parts+=("ElephantPinataJwt=\"$ELEPHANT_PINATA_JWT\"")
    parts+=("ElephantKeystoreS3Key=\"${ELEPHANT_KEYSTORE_S3_KEY:-pending}\"")
    parts+=("ElephantKeystorePassword=\"$ELEPHANT_KEYSTORE_PASSWORD\"")
  else
    # Traditional mode - require all API credentials
    : "${ELEPHANT_DOMAIN?Set ELEPHANT_DOMAIN}"
    : "${ELEPHANT_API_KEY?Set ELEPHANT_API_KEY}"
    : "${ELEPHANT_ORACLE_KEY_ID?Set ELEPHANT_ORACLE_KEY_ID}"
    : "${ELEPHANT_FROM_ADDRESS?Set ELEPHANT_FROM_ADDRESS}"
    : "${ELEPHANT_RPC_URL?Set ELEPHANT_RPC_URL}"
    : "${ELEPHANT_PINATA_JWT?Set ELEPHANT_PINATA_JWT}"

    local parts=()
    parts+=("ElephantDomain=\"$ELEPHANT_DOMAIN\"")
    parts+=("ElephantApiKey=\"$ELEPHANT_API_KEY\"")
    parts+=("ElephantOracleKeyId=\"$ELEPHANT_ORACLE_KEY_ID\"")
    parts+=("ElephantFromAddress=\"$ELEPHANT_FROM_ADDRESS\"")
    parts+=("ElephantRpcUrl=\"$ELEPHANT_RPC_URL\"")
    parts+=("ElephantPinataJwt=\"$ELEPHANT_PINATA_JWT\"")
  fi

  [[ -n "${WORKFLOW_QUEUE_NAME:-}" ]] && parts+=("WorkflowQueueName=\"$WORKFLOW_QUEUE_NAME\"")
  [[ -n "${WORKFLOW_STARTER_RESERVED_CONCURRENCY:-}" ]] && parts+=("WorkflowStarterReservedConcurrency=\"$WORKFLOW_STARTER_RESERVED_CONCURRENCY\"")
  [[ -n "${WORKFLOW_STATE_MACHINE_NAME:-}" ]] && parts+=("WorkflowStateMachineName=\"$WORKFLOW_STATE_MACHINE_NAME\"")

  # Prepare function flags (only add if set locally)
  [[ -n "${ELEPHANT_PREPARE_USE_BROWSER:-}" ]] && parts+=("ElephantPrepareUseBrowser=\"$ELEPHANT_PREPARE_USE_BROWSER\"")
  [[ -n "${ELEPHANT_PREPARE_NO_FAST:-}" ]] && parts+=("ElephantPrepareNoFast=\"$ELEPHANT_PREPARE_NO_FAST\"")
  [[ -n "${ELEPHANT_PREPARE_NO_CONTINUE:-}" ]] && parts+=("ElephantPrepareNoContinue=\"$ELEPHANT_PREPARE_NO_CONTINUE\"")
  
  # Updater schedule rate (only add if set locally)
  [[ -n "${UPDATER_SCHEDULE_RATE:-}" ]] && parts+=("UpdaterScheduleRate=\"$UPDATER_SCHEDULE_RATE\"")

  PARAM_OVERRIDES="${parts[*]}"
}

bundle_transforms_for_lambda() {
  if [[ ! -d "$TRANSFORMS_SRC_DIR" ]]; then
    warn "Transforms source dir not found: $TRANSFORMS_SRC_DIR (skipping bundle)"
    return 1
  fi
  mkdir -p "$(dirname "$TRANSFORMS_TARGET_ZIP")"
  # Create a temp directory to hold the zip to avoid mktemp creating
  # an empty file that confuses `zip` with "Zip file structure invalid".
  local tmp_dir tmp_zip
  tmp_dir=$(mktemp -d -t transforms.XXXXXX)
  tmp_zip="$tmp_dir/transforms.zip"
  info "Bundling transforms from $TRANSFORMS_SRC_DIR to $TRANSFORMS_TARGET_ZIP"
  pushd "$TRANSFORMS_SRC_DIR" >/dev/null
  zip -r "$tmp_zip" .
  popd >/dev/null
  mv -f "$tmp_zip" "$TRANSFORMS_TARGET_ZIP"
  # Cleanup temp directory
  rm -rf "$tmp_dir"
}


# Check the Lambda "Concurrent executions" service quota and request an increase if it's 10
ensure_lambda_concurrency_quota() {
  info "Checking Lambda 'Concurrent executions' service quota"
  local quota_code="L-B99A9384" # Concurrent executions
  local current desired=1000 resp req_id status

  # Try to fetch quota directly by code
  current=$(aws service-quotas get-service-quota \
    --service-code lambda \
    --quota-code "$quota_code" \
    --query 'Quota.Value' --output text 2>/dev/null || true)

  # Fallback via list if direct call didn't return a value
  if [[ -z "$current" || "$current" == "None" || "$current" == "null" ]]; then
    current=$(aws service-quotas list-service-quotas \
      --service-code lambda \
      --query "Quotas[?QuotaCode=='$quota_code'].Value | [0]" \
      --output text 2>/dev/null || true)
  fi

  if [[ -z "$current" || "$current" == "None" || "$current" == "null" ]]; then
    warn "Could not determine Lambda 'Concurrent executions' quota; skipping quota request"
    return 0
  fi

  info "Current Lambda concurrent executions quota: $current"

  # If the quota is 10 (handle values like 10 or 10.0), request increase to 1000
  local current_int
  current_int=${current%%.*}
  if [[ "$current_int" =~ ^[0-9]+$ && "$current_int" -eq 10 ]]; then
    info "Requesting quota increase to ${desired}"
    resp=$(aws service-quotas request-service-quota-increase \
      --service-code lambda \
      --quota-code "$quota_code" \
      --desired-value "$desired" 2>/dev/null || true)
    req_id=$(echo "$resp" | jq -r '.RequestedQuota.Id // empty')
    status=$(echo "$resp" | jq -r '.RequestedQuota.Status // empty')
    if [[ -n "$req_id" ]]; then
      info "Submitted quota increase request. Id: $req_id Status: $status"
    else
      warn "Failed to submit quota increase request. Response: $resp"
    fi
  else
    info "No increase requested (quota not equal to 10)"
  fi
}

handle_pending_keystore_upload() {
  if [[ -n "${KEYSTORE_S3_KEY_PENDING:-}" && -n "${KEYSTORE_FILE_PENDING:-}" ]]; then
    local bucket=$(get_bucket)
    if [[ -n "$bucket" ]]; then
      info "Uploading pending keystore file to S3..."
      aws s3 cp "$KEYSTORE_FILE_PENDING" "s3://$bucket/$KEYSTORE_S3_KEY_PENDING"

      # Update the stack with the actual S3 key
      ELEPHANT_KEYSTORE_S3_KEY="$KEYSTORE_S3_KEY_PENDING"
      compute_param_overrides
      info "Updating stack with keystore S3 key..."
      sam_deploy
    fi
  fi
}

main() {
  check_prereqs
  ensure_lambda_concurrency_quota

  compute_param_overrides
  bundle_transforms_for_lambda

  sam_build
  sam_deploy

  handle_pending_keystore_upload

  bucket=$(get_bucket)
  echo
  info "Done!"
  info "Environment bucket: $bucket"
}

main "$@"
