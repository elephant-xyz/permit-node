#!/usr/bin/env bash
set -euo pipefail

# Enable VPC Flow Logs for the stack's VPC and publish to CloudWatch Logs.
# - Resolves VPC ID from CloudFormation stack output key "VPC".
# - Ensures the service-linked role for VPC Flow Logs exists.
# - Creates (or reuses) a CloudWatch Logs log group.
# - Creates a Flow Log with traffic type ALL and 60s aggregation.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

STACK_NAME="${STACK_NAME:-elephant-permit-node}"
LOG_GROUP_NAME="${FLOW_LOG_GROUP_NAME:-/aws/vpc/flow-logs/${STACK_NAME}}"
TRAFFIC_TYPE="${FLOW_LOGS_TRAFFIC_TYPE:-ALL}"     # ACCEPT | REJECT | ALL
AGG_INTERVAL="${FLOW_LOGS_MAX_AGG_SEC:-60}"       # 60 or 600
# Custom log format to enrich with AWS service mapping and path (version 5 fields)
# Ref: https://docs.aws.amazon.com/vpc/latest/userguide/flow-log-records.html
LOG_FORMAT_DEFAULT='${version} ${account-id} ${interface-id} ${srcaddr} ${dstaddr} ${srcport} ${dstport} ${protocol} ${packets} ${bytes} ${start} ${end} ${action} ${log-status} ${vpc-id} ${subnet-id} ${instance-id} ${tcp-flags} ${type} ${pkt-srcaddr} ${pkt-dstaddr} ${region} ${az-id} ${pkt-src-aws-service} ${pkt-dst-aws-service} ${flow-direction} ${traffic-path}'
LOG_FORMAT="${FLOW_LOGS_FORMAT:-$LOG_FORMAT_DEFAULT}"
RETENTION_DAYS="${FLOW_LOGS_RETENTION_DAYS:-}"   # e.g., 14 (optional)
RECREATE_EXISTING="${FLOW_LOGS_RECREATE:-true}"   # true|false

require_cmd() { command -v "$1" >/dev/null || { err "$1 not found"; exit 1; }; }

main() {
  require_cmd aws
  require_cmd jq

  info "Resolving VPC ID from stack outputs for stack: ${STACK_NAME}"
  local vpc_id
  vpc_id=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='VPC'].OutputValue" \
    --output text)
  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    err "Could not resolve VPC ID from CloudFormation output key 'VPC'"
    exit 1
  fi
  info "VPC ID: ${vpc_id}"

  info "Ensuring CloudWatch Logs log group exists: ${LOG_GROUP_NAME}"
  if ! aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" \
      --query 'logGroups[?logGroupName==`'"$LOG_GROUP_NAME"'`].logGroupName' \
      --output text | grep -q "^${LOG_GROUP_NAME}$"; then
    aws logs create-log-group --log-group-name "$LOG_GROUP_NAME" || true
    info "Created log group: ${LOG_GROUP_NAME}"
  else
    info "Log group already exists"
  fi
  if [[ -n "${RETENTION_DAYS}" ]]; then
    info "Setting log group retention to ${RETENTION_DAYS} days"
    aws logs put-retention-policy --log-group-name "$LOG_GROUP_NAME" --retention-in-days "$RETENTION_DAYS" || true
  fi

  info "Ensuring IAM role for publishing Flow Logs to CloudWatch exists"
  local role_name role_arn account_id
  role_name="VPCFlowLogsToCloudWatch-${STACK_NAME}"
  account_id=$(aws sts get-caller-identity --query Account --output text)
  if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    info "Creating IAM role: ${role_name}"
    # Trust policy allows the vpc-flow-logs service to assume the role
    local trust_file perm_file
    trust_file=$(mktemp)
    cat >"$trust_file" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "vpc-flow-logs.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON
    aws iam create-role \
      --role-name "$role_name" \
      --assume-role-policy-document file://"$trust_file" >/dev/null

    # Inline permissions policy required to publish to CloudWatch Logs
    perm_file=$(mktemp)
    cat >"$perm_file" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ],
      "Resource": "*"
    }
  ]
}
JSON
    aws iam put-role-policy \
      --role-name "$role_name" \
      --policy-name "VPCFlowLogsToCloudWatchPermissions" \
      --policy-document file://"$perm_file" >/dev/null
    rm -f "$trust_file" "$perm_file"
    info "Created IAM role and attached inline policy"
  else
    info "IAM role already exists: ${role_name}"
  fi

  role_arn=$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text)
  info "Using role ARN: ${role_arn}"

  info "Checking for existing Flow Logs on VPC and log group"
  local existing_ids
  existing_ids=$(aws ec2 describe-flow-logs \
    --filter Name=resource-id,Values="$vpc_id" \
    --query "FlowLogs[?LogGroupName=='${LOG_GROUP_NAME}'].FlowLogId" \
    --output text || true)
  if [[ -n "${existing_ids:-}" ]]; then
    if [[ "$RECREATE_EXISTING" == "true" ]]; then
      info "Deleting existing Flow Logs to apply custom log format: ${existing_ids}"
      aws ec2 delete-flow-logs --flow-log-ids ${existing_ids}
    else
      info "Existing Flow Logs preserved (FLOW_LOGS_RECREATE=false): ${existing_ids}"
      exit 0
    fi
  fi

  info "Creating VPC Flow Log (traffic: ${TRAFFIC_TYPE}, agg: ${AGG_INTERVAL}s)"
  local resp flow_log_id
  resp=$(aws ec2 create-flow-logs \
    --resource-type VPC \
    --resource-ids "$vpc_id" \
    --traffic-type "$TRAFFIC_TYPE" \
    --log-group-name "$LOG_GROUP_NAME" \
    --log-format "$LOG_FORMAT" \
    --deliver-logs-permission-arn "$role_arn" \
    --max-aggregation-interval "$AGG_INTERVAL")
  flow_log_id=$(echo "$resp" | jq -r '.FlowLogIds[0] // empty')
  if [[ -z "$flow_log_id" ]]; then
    err "Failed to create Flow Log"
    echo "$resp"
    exit 1
  fi
  info "Created Flow Log: ${flow_log_id}"
}

main "$@"


