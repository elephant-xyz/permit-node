#!/usr/bin/env bash
set -euo pipefail

# Configure S3 bucket notifications for the permit processing workflow

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

# Config with defaults
STACK_NAME="${STACK_NAME:-elephant-permit-node}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Configure S3 bucket notifications to trigger the permit processing workflow.

Options:
    --stack-name <name>    CloudFormation stack name (default: elephant-permit-node)
    --help                 Show this help message

Environment Variables:
    STACK_NAME             CloudFormation stack name (default: elephant-permit-node)

Examples:
    # Configure with default stack name
    $0
    
    # Configure with custom stack name
    $0 --stack-name my-permit-stack
    
    # Using environment variable
    STACK_NAME=my-permit-stack $0
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Check prerequisites
check_prereqs() {
    command -v aws >/dev/null || { err "aws CLI not found"; exit 1; }
    command -v jq >/dev/null || { err "jq not found"; exit 1; }
    aws sts get-caller-identity >/dev/null || { err "AWS credentials not configured"; exit 1; }
}

# Get stack outputs
get_stack_output() {
    local key="$1"
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue" \
        --output text 2>/dev/null || echo ""
}

main() {
    info "Configuring S3 bucket notifications for stack: $STACK_NAME"
    
    check_prereqs
    
    # Get required values from CloudFormation outputs
    INPUT_BUCKET=$(get_stack_output "InputBucketName")
    WORKFLOW_STARTER_ARN=$(get_stack_output "WorkflowStarterFunctionArn")
    
    if [[ -z "$INPUT_BUCKET" ]]; then
        err "Could not find InputBucketName output in stack $STACK_NAME"
        err "Make sure the stack is deployed and has the InputBucketName output"
        exit 1
    fi
    
    if [[ -z "$WORKFLOW_STARTER_ARN" ]]; then
        err "Could not find WorkflowStarterFunctionArn output in stack $STACK_NAME"
        err "Make sure the stack is deployed and has the WorkflowStarterFunctionArn output"
        exit 1
    fi
    
    info "Input Bucket: $INPUT_BUCKET"
    info "WorkflowStarter ARN: $WORKFLOW_STARTER_ARN"
    
    # Create notification configuration
    NOTIFICATION_CONFIG=$(cat <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "csv-upload-trigger",
      "LambdaFunctionArn": "$WORKFLOW_STARTER_ARN",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "suffix", "Value": ".csv"}
          ]
        }
      }
    }
  ]
}
EOF
)
    
    info "Configuring S3 bucket notification..."
    
    # Apply the notification configuration
    echo "$NOTIFICATION_CONFIG" | aws s3api put-bucket-notification-configuration \
        --bucket "$INPUT_BUCKET" \
        --notification-configuration file:///dev/stdin
    
    info "✅ S3 bucket notification configured successfully!"
    info ""
    info "The workflow is now ready to use:"
    info "1. Upload CSV files to: s3://$INPUT_BUCKET/"
    info "2. The workflow will start automatically when .csv files are uploaded"
    info "3. Check the step function execution in the AWS console"
}

main "$@"
