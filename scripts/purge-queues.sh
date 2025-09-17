#!/usr/bin/env bash
set -euo pipefail

# Purge all SQS queues and verify they are successfully purged
# This script purges both primary queues and dead letter queues

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }
step() { echo -e "${BLUE}[STEP]${NC} $*"; }

STACK_NAME="${STACK_NAME:-elephant-permit-node}"
DRY_RUN="${DRY_RUN:-false}"

# Function to get queue URL from CloudFormation stack
get_queue_url() {
    local output_key="$1"
    aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue" \
        --output text
}

# Function to get queue attributes
get_queue_attributes() {
    local queue_url="$1"
    aws sqs get-queue-attributes \
        --queue-url "$queue_url" \
        --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible,ApproximateNumberOfMessagesDelayed \
        --query 'Attributes' \
        --output json
}

# Function to purge a queue
purge_queue() {
    local queue_name="$1"
    local queue_url="$2"
    
    step "Processing queue: $queue_name"
    info "Queue URL: $queue_url"
    
    # Get current message counts
    local attributes
    attributes=$(get_queue_attributes "$queue_url")
    local visible_msgs=$(echo "$attributes" | jq -r '.ApproximateNumberOfMessages // "0"')
    local in_flight_msgs=$(echo "$attributes" | jq -r '.ApproximateNumberOfMessagesNotVisible // "0"')
    local delayed_msgs=$(echo "$attributes" | jq -r '.ApproximateNumberOfMessagesDelayed // "0"')
    
    info "Current messages: $visible_msgs visible, $in_flight_msgs in-flight, $delayed_msgs delayed"
    
    if [[ "$visible_msgs" == "0" && "$in_flight_msgs" == "0" && "$delayed_msgs" == "0" ]]; then
        info "✅ Queue is already empty"
        return 0
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY RUN: Would purge $visible_msgs visible messages from $queue_name"
        return 0
    fi
    
    # Purge the queue
    info "Purging queue..."
    if aws sqs purge-queue --queue-url "$queue_url" 2>/dev/null; then
        info "✅ Purge command sent successfully"
    else
        err "❌ Failed to purge queue"
        return 1
    fi
    
    # Wait for purge to complete (can take up to 60 seconds)
    info "Waiting for purge to complete (this may take up to 60 seconds)..."
    local attempts=0
    local max_attempts=12  # 60 seconds with 5-second intervals
    
    while [[ $attempts -lt $max_attempts ]]; do
        sleep 5
        attributes=$(get_queue_attributes "$queue_url")
        visible_msgs=$(echo "$attributes" | jq -r '.ApproximateNumberOfMessages // "0"')
        in_flight_msgs=$(echo "$attributes" | jq -r '.ApproximateNumberOfMessagesNotVisible // "0"')
        delayed_msgs=$(echo "$attributes" | jq -r '.ApproximateNumberOfMessagesDelayed // "0"')
        
        if [[ "$visible_msgs" == "0" && "$in_flight_msgs" == "0" && "$delayed_msgs" == "0" ]]; then
            info "✅ Queue successfully purged!"
            return 0
        fi
        
        attempts=$((attempts + 1))
        info "Still purging... ($visible_msgs visible, $in_flight_msgs in-flight, $delayed_msgs delayed) - attempt $attempts/$max_attempts"
    done
    
    warn "⚠️  Purge may still be in progress. Queue shows: $visible_msgs visible, $in_flight_msgs in-flight, $delayed_msgs delayed"
    return 1
}

# Function to verify queue is empty
verify_queue_empty() {
    local queue_name="$1"
    local queue_url="$2"
    
    step "Verifying $queue_name is empty"
    
    local attributes
    attributes=$(get_queue_attributes "$queue_url")
    local visible_msgs=$(echo "$attributes" | jq -r '.ApproximateNumberOfMessages // "0"')
    local in_flight_msgs=$(echo "$attributes" | jq -r '.ApproximateNumberOfMessagesNotVisible // "0"')
    local delayed_msgs=$(echo "$attributes" | jq -r '.ApproximateNumberOfMessagesDelayed // "0"')
    
    if [[ "$visible_msgs" == "0" && "$in_flight_msgs" == "0" && "$delayed_msgs" == "0" ]]; then
        info "✅ $queue_name is confirmed empty"
        return 0
    else
        err "❌ $queue_name still has messages: $visible_msgs visible, $in_flight_msgs in-flight, $delayed_msgs delayed"
        return 1
    fi
}

main() {
    info "Starting SQS queue purge process for stack: $STACK_NAME"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY RUN MODE - No actual purging will be performed"
    fi
    
    # Define queues to purge
    declare -A queues=(
        ["MWAA Primary Queue"]="MwaaSqsQueueUrl"
        ["MWAA Dead Letter Queue"]="MwaaDeadLetterQueueUrl"
        ["Workflow Queue"]="WorkflowQueueUrl"
        ["Workflow Dead Letter Queue"]="WorkflowDeadLetterQueueUrl"
    )
    
    local failed_queues=()
    local successful_queues=()
    
    # Purge each queue
    for queue_name in "${!queues[@]}"; do
        local output_key="${queues[$queue_name]}"
        
        step "Getting queue URL for $queue_name"
        local queue_url
        queue_url=$(get_queue_url "$output_key")
        
        if [[ -z "$queue_url" || "$queue_url" == "None" ]]; then
            err "Could not find queue URL for $queue_name (output key: $output_key)"
            failed_queues+=("$queue_name")
            continue
        fi
        
        if purge_queue "$queue_name" "$queue_url"; then
            successful_queues+=("$queue_name")
        else
            failed_queues+=("$queue_name")
        fi
        
        echo
    done
    
    # Final verification
    if [[ "$DRY_RUN" == "false" ]]; then
        step "Final verification of all queues"
        echo
        
        for queue_name in "${!queues[@]}"; do
            local output_key="${queues[$queue_name]}"
            local queue_url
            queue_url=$(get_queue_url "$output_key")
            
            if [[ -n "$queue_url" && "$queue_url" != "None" ]]; then
                verify_queue_empty "$queue_name" "$queue_url"
            fi
        done
    fi
    
    # Summary
    echo
    step "Purge Summary"
    echo "============="
    
    if [[ ${#successful_queues[@]} -gt 0 ]]; then
        info "✅ Successfully processed queues:"
        for queue in "${successful_queues[@]}"; do
            echo "   - $queue"
        done
    fi
    
    if [[ ${#failed_queues[@]} -gt 0 ]]; then
        err "❌ Failed to process queues:"
        for queue in "${failed_queues[@]}"; do
            echo "   - $queue"
        done
        exit 1
    fi
    
    info "🎉 All queues processed successfully!"
}

# Check dependencies
require_cmd() { command -v "$1" >/dev/null || { err "$1 not found"; exit 1; }; }

require_cmd aws
require_cmd jq

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--dry-run] [--stack-name STACK_NAME]"
            echo ""
            echo "Options:"
            echo "  --dry-run     Show what would be purged without actually purging"
            echo "  --stack-name  CloudFormation stack name (default: elephant-permit-node)"
            echo "  --help        Show this help message"
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

main "$@"
