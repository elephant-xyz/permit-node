#!/usr/bin/env bash
set -euo pipefail

# Start Step Function execution for S3 to SQS processing

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

# Config with defaults
STACK_NAME="${STACK_NAME:-elephant-permit-node}"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <bucket-name> [s3-object-key]

Start Step Function execution to process S3 objects and send SQS messages.

Arguments:
    bucket-name        Name of the S3 bucket to process
    s3-object-key      (Optional) Specific S3 object key to process directly

Options:
    --express          Directly invoke ElephantExpressWorkflow (bypasses S3ToSqsStateMachine)
    --help             Show this help message

Environment Variables:
    STACK_NAME         CloudFormation stack name (default: elephant-permit-node)

Examples:
    # Start S3 to SQS processing (default)
    $0 my-data-bucket
    
    # Start ElephantExpressWorkflow directly with specific S3 object
    $0 --express my-data-bucket source-data/county-data.json
    
    # Start ElephantExpressWorkflow with auto-generated S3 object key
    $0 --express my-data-bucket
EOF
}

# Check prerequisites
check_prereqs() {
    command -v aws >/dev/null || { err "aws CLI not found"; exit 1; }
    command -v jq >/dev/null || { err "jq not found"; exit 1; }
    aws sts get-caller-identity >/dev/null || { err "AWS credentials not configured"; exit 1; }
}

# Get Step Function ARN from CloudFormation stack
get_step_function_arn() {
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='S3ToSqsStateMachineArn'].OutputValue" \
        --output text
}

# Get SQS Queue URL from CloudFormation stack
get_sqs_queue_url() {
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='MwaaSqsQueueUrl'].OutputValue" \
        --output text
}

# Get the ElephantExpressWorkflow ARN from CloudFormation stack outputs
get_express_workflow_arn() {
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='ElephantExpressStateMachineArn'].OutputValue" \
        --output text
}

# Get Workflow SQS Queue URL from CloudFormation stack
get_workflow_sqs_queue_url() {
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='WorkflowQueueUrl'].OutputValue" \
        --output text
}

# Get ElephantExpressWorkflow ARN from CloudFormation stack
get_express_workflow_arn() {
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='ElephantExpressStateMachineArn'].OutputValue" \
        --output text
}

# Start Step Function execution
start_execution() {
    local bucket_name="$1"
    local step_function_arn="$2"
    local sqs_queue_url="$3"
    
    # Generate unique execution name with timestamp and bucket name
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local execution_name="s3-to-sqs-${bucket_name}-${timestamp}"

    info "Starting Step Function execution: $execution_name"
    info "Step Function ARN: $step_function_arn"
    info "S3 Bucket: $bucket_name"
    info "SQS Queue URL: $sqs_queue_url"

    # Create execution input
    local input_payload
    input_payload=$(jq -n \
        --arg bucket "$bucket_name" \
        --arg sqs_url "$sqs_queue_url" \
        '{bucketName: $bucket, sqsQueueUrl: $sqs_url}')

    # Start execution
    local execution_arn
    if execution_arn=$(aws stepfunctions start-execution \
        --state-machine-arn "$step_function_arn" \
        --name "$execution_name" \
        --input "$input_payload" \
        --query 'executionArn' \
        --output text 2>/dev/null); then

        info "✅ Step Function execution started successfully"
        info "Execution ARN: $execution_arn"
        echo "$execution_arn"
        return 0
    else
        local exit_code=$?
        local error_output
        error_output=$(aws stepfunctions start-execution \
            --state-machine-arn "$step_function_arn" \
            --name "$execution_name" \
            --input "$input_payload" 2>&1) || true

        # Check if error is about execution already exists
        if echo "$error_output" | grep -q "ExecutionAlreadyExists"; then
            warn "⚠️  Execution '$execution_name' already exists"
            err "An execution with this name is already running or has completed recently."
            err "This is unexpected since execution names are now unique with timestamps."
            err "Please try again in a moment."
            return 1
        else
            err "❌ Failed to start Step Function execution"
            err "Error: $error_output"
            return $exit_code
        fi
    fi
}

# Start ElephantExpressWorkflow directly
start_express_workflow() {
    local bucket_name="$1"
    local s3_object_key="$2"
    local express_workflow_arn="$3"
    
    # Generate unique execution name with timestamp and bucket name
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local execution_name="elephant-express-${bucket_name}-${timestamp}"

    info "Starting ElephantExpressWorkflow execution: $execution_name"
    info "Express Workflow ARN: $express_workflow_arn"
    info "S3 Bucket: $bucket_name"
    info "S3 Object Key: $s3_object_key"

    # Create S3 event record format for the workflow
    local input_payload
    input_payload=$(jq -n \
        --arg bucket "$bucket_name" \
        --arg key "$s3_object_key" \
        '{
            Records: [{
                s3: {
                    bucket: { name: $bucket },
                    object: { key: $key }
                }
            }]
        }')

    # Start execution
    local execution_arn
    if execution_arn=$(aws stepfunctions start-execution \
        --state-machine-arn "$express_workflow_arn" \
        --name "$execution_name" \
        --input "$input_payload" \
        --query 'executionArn' \
        --output text 2>/dev/null); then

        info "✅ ElephantExpressWorkflow execution started successfully"
        info "Execution ARN: $execution_arn"
        echo "$execution_arn"
        return 0
    else
        local exit_code=$?
        local error_output
        error_output=$(aws stepfunctions start-execution \
            --state-machine-arn "$express_workflow_arn" \
            --name "$execution_name" \
            --input "$input_payload" 2>&1) || true

        # Check if error is about execution already exists
        if echo "$error_output" | grep -q "ExecutionAlreadyExists"; then
            warn "⚠️  Execution '$execution_name' already exists"
            err "An execution with this name is already running or has completed recently."
            err "Please try again in a moment."
            return 1
        else
            err "❌ Failed to start ElephantExpressWorkflow execution"
            err "Error: $error_output"
            return $exit_code
        fi
    fi
}

# Directly invoke ElephantExpressWorkflow
start_express_workflow() {
    local bucket_name="$1"
    local s3_object_key="$2"
    local express_workflow_arn="$3"
    
    info "Directly invoking ElephantExpressWorkflow"
    info "S3 Bucket: $bucket_name"
    info "S3 Object Key: $s3_object_key"
    info "Express Workflow ARN: $express_workflow_arn"

    # Generate unique execution name
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local execution_name="elephant-express-${bucket_name}-${timestamp}"

    # Create S3 event record format for the workflow
    local input_payload
    input_payload=$(jq -n \
        --arg bucket "$bucket_name" \
        --arg key "$s3_object_key" \
        '{
            Records: [{
                s3: {
                    bucket: { name: $bucket },
                    object: { key: $key }
                }
            }]
        }')

    info "Starting Express Step Function execution: $execution_name"

    # Start the Express Step Function execution
    if aws stepfunctions start-execution \
        --state-machine-arn "$express_workflow_arn" \
        --name "$execution_name" \
        --input "$input_payload" \
        --query 'executionArn' \
        --output text >/dev/null; then

        info "✅ ElephantExpressWorkflow execution started successfully"
        info "Execution Name: $execution_name"
        info "Note: Express Step Functions don't maintain execution history"
        info "Check CloudWatch Logs at: /aws/vendedlogs/states/ElephantExpressWorkflow"
        return 0
    else
        err "❌ Failed to start ElephantExpressWorkflow execution"
        return 1
    fi
}

main() {
    local express_mode=false
    local bucket_name=""
    local s3_object_key=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --express)
                express_mode=true
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            -*)
                err "Unknown option: $1"
                usage
                exit 1
                ;;
            *)
                if [[ -z "$bucket_name" ]]; then
                    bucket_name="$1"
                elif [[ -z "$s3_object_key" ]]; then
                    s3_object_key="$1"
                else
                    err "Too many arguments"
                    usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Check if bucket name is provided
    if [[ -z "$bucket_name" ]]; then
        err "Bucket name is required"
        usage
        exit 1
    fi

    # Set default S3 object key if not provided
    if [[ -z "$s3_object_key" ]]; then
        s3_object_key="source-data/test-data-$(date +%Y%m%d-%H%M%S).json"
        warn "No S3 object key provided, using default: $s3_object_key"
    fi

    # Validate bucket name format
    if ! [[ "$bucket_name" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
        err "Invalid bucket name format: $bucket_name"
        err "Bucket names must be 3-63 characters long and contain only lowercase letters, numbers, hyphens, and periods."
        exit 1
    fi

    check_prereqs

    info "Using CloudFormation stack: $STACK_NAME"

    local step_function_arn
    step_function_arn=$(get_step_function_arn)
    if [[ -z "$step_function_arn" || "$step_function_arn" == "None" ]]; then
        err "Could not find Step Function ARN in stack outputs"
        err "Make sure the stack is deployed and contains S3ToSqsStateMachineArn output"
        exit 1
    fi

    if [[ "$express_mode" == "true" ]]; then
        # Express mode: Directly invoke ElephantExpressWorkflow
        local express_workflow_arn
        express_workflow_arn=$(get_express_workflow_arn)
        if [[ -z "$express_workflow_arn" || "$express_workflow_arn" == "None" ]]; then
            err "Could not find ElephantExpressWorkflow ARN in stack outputs"
            err "Make sure the stack is deployed and contains ElephantExpressStateMachineArn output"
            exit 1
        fi
        info "Express mode: Directly invoking ElephantExpressWorkflow"
        start_express_workflow "$bucket_name" "$s3_object_key" "$express_workflow_arn"
    else
        # Default mode: Use MwaaSqsQueue for MWAA workflow
        local sqs_queue_url
        sqs_queue_url=$(get_workflow_sqs_queue_url)
        if [[ -z "$sqs_queue_url" || "$sqs_queue_url" == "None" ]]; then
            err "Could not find SQS Queue URL in stack outputs"
            err "Make sure the stack is deployed and contains MwaaSqsQueueUrl output"
            exit 1
        fi
        info "Default mode: Using S3ToSqsStateMachine -> MwaaSqsQueue (MWAA workflow)"
        start_execution "$bucket_name" "$step_function_arn" "$sqs_queue_url"
    fi
}

main "$@"
