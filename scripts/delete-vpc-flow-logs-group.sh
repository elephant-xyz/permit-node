#!/usr/bin/env bash
set -euo pipefail

# Delete the CloudWatch Logs log group used by VPC Flow Logs for this stack.
# Note: This does NOT delete the Flow Log resource itself. If a Flow Log still
# references the log group, deletion will fail. Disable/delete Flow Logs first if needed.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

STACK_NAME="${STACK_NAME:-elephant-permit-node}"
LOG_GROUP_NAME="${FLOW_LOG_GROUP_NAME:-/aws/vpc/flow-logs/${STACK_NAME}}"

require_cmd() { command -v "$1" >/dev/null || { err "$1 not found"; exit 1; }; }

main() {
  require_cmd aws

  info "Deleting CloudWatch Logs log group: ${LOG_GROUP_NAME}"
  if aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP_NAME" \
      --query 'logGroups[?logGroupName==`'"$LOG_GROUP_NAME"'`].logGroupName' \
      --output text | grep -q "^${LOG_GROUP_NAME}$"; then
    aws logs delete-log-group --log-group-name "$LOG_GROUP_NAME"
    info "Deleted log group: ${LOG_GROUP_NAME}"
  else
    warn "Log group not found: ${LOG_GROUP_NAME} (nothing to do)"
  fi
}

main "$@"


