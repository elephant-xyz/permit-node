#!/bin/bash
#
# Auto Queue Fixer
# ================
#
# This script automatically finds the SQS queue and fixes malformed messages.
# It handles AWS profile selection, queue discovery, and batch processing.
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${PURPLE}[HEADER]${NC} $1"
}

print_progress() {
    echo -e "${CYAN}[PROGRESS]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to check prerequisites
check_prerequisites() {
    print_info "Checking prerequisites..."
    
    # Check if we're in the right directory
    if [ ! -f "dags/elephant_workflow.py" ]; then
        print_error "Please run this script from the permit-node project root directory"
        exit 1
    fi
    
    # Check if Python is available
    if ! command_exists python3; then
        print_error "Python 3 is required but not installed"
        exit 1
    fi
    
    # Check if AWS CLI is available
    if ! command_exists aws; then
        print_error "AWS CLI is required but not installed"
        exit 1
    fi
    
    # Check if boto3 is available
    if ! python3 -c "import boto3" 2>/dev/null; then
        print_error "boto3 Python library is required. Install with: pip install boto3"
        exit 1
    fi
    
    print_success "All prerequisites met"
}

# Function to check AWS credentials
check_aws_credentials() {
    local profile=$1
    print_info "Checking AWS credentials for profile: $profile"
    
    if ! AWS_PROFILE="$profile" aws sts get-caller-identity >/dev/null 2>&1; then
        print_error "AWS credentials not valid for profile: $profile"
        print_info "Please run: aws configure --profile $profile"
        exit 1
    fi
    
    print_success "AWS credentials valid for profile: $profile"
}

# Function to discover SQS queues
discover_queues() {
    local profile=$1
    print_info "Discovering SQS queue..."
    
    # Get all elephant-related queues
    local queues
    queues=$(AWS_PROFILE="$profile" aws sqs list-queues --query 'QueueUrls[?contains(@, `elephant`)]' --output text 2>/dev/null || echo "")
    
    if [ -z "$queues" ]; then
        print_error "No elephant-related queues found"
        exit 1
    fi
    
    # Count queues
    local queue_count
    queue_count=$(echo "$queues" | wc -w)
    print_info "Found $queue_count elephant-related queue(s)"
    
    # Display queues
    print_info "Available queues:"
    echo "$queues" | while read -r queue; do
        if [ -n "$queue" ]; then
            echo "  - $queue"
        fi
    done
    
    # Select the main queue (not dead letter queue)
    local main_queue
    main_queue=$(echo "$queues" | grep -v "DeadLetter" | head -n1)
    
    if [ -z "$main_queue" ]; then
        print_warning "No main queue found, using first available queue"
        main_queue=$(echo "$queues" | head -n1)
    fi
    
    print_success "Selected queue: $main_queue"
    echo "$main_queue"
}

# Function to get queue statistics
get_queue_stats() {
    local profile=$1
    local queue_url=$2
    
    print_info "Getting queue statistics..."
    
    local stats
    stats=$(AWS_PROFILE="$profile" aws sqs get-queue-attributes \
        --queue-url "$queue_url" \
        --attribute-names All \
        --query 'Attributes.{ApproximateNumberOfMessages:ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible:ApproximateNumberOfMessagesNotVisible,ApproximateNumberOfMessagesDelayed:ApproximateNumberOfMessagesDelayed}' \
        --output table 2>/dev/null || echo "")
    
    if [ -n "$stats" ]; then
        echo "$stats"
    else
        print_warning "Could not retrieve queue statistics"
    fi
}

# Function to fix malformed messages using Python
fix_messages() {
    local profile=$1
    local queue_url=$2
    local batch_size=${3:-100}
    local max_batches=${4:-1000}
    
    print_progress "Starting message fixing process..."
    print_info "Profile: $profile"
    print_info "Queue: $queue_url"
    print_info "Batch size: $batch_size"
    print_info "Max batches: $max_batches"
    
    # Create a temporary Python script for fixing messages
    local temp_script
    temp_script=$(mktemp)
    
    cat > "$temp_script" << 'EOF'
#!/usr/bin/env python3
import json
import logging
import sys
import time
import boto3
from botocore.exceptions import ClientError, BotoCoreError

# Set up logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

def is_malformed_message(message_body):
    """Check if a message is malformed (contains entire SQS message object instead of just body)."""
    if not message_body or not message_body.strip():
        return False
    
    try:
        # Try to parse as JSON
        parsed = json.loads(message_body)
        
        # Check if it looks like an SQS message object
        if isinstance(parsed, dict):
            # If it has MessageId, Body, ReceiptHandle, it's likely a malformed SQS message
            if all(key in parsed for key in ['MessageId', 'Body', 'ReceiptHandle']):
                return True
                
        return False
    except json.JSONDecodeError:
        return False

def extract_original_body(malformed_message):
    """Extract the original message body from a malformed SQS message."""
    try:
        parsed = json.loads(malformed_message)
        if isinstance(parsed, dict) and 'Body' in parsed:
            return parsed['Body']
    except json.JSONDecodeError:
        pass
    return None

def fix_queue_messages(queue_url, batch_size=100, max_batches=1000):
    """Fix malformed messages in the SQS queue."""
    sqs = boto3.client('sqs')
    
    total_processed = 0
    malformed_found = 0
    successfully_fixed = 0
    failed_to_fix = 0
    errors = 0
    
    print(f"Starting to process up to {max_batches} batches of {batch_size} messages each...")
    
    for batch_num in range(1, max_batches + 1):
        try:
            # Receive messages
            response = sqs.receive_message(
                QueueUrl=queue_url,
                MaxNumberOfMessages=min(batch_size, 10),  # SQS max is 10
                WaitTimeSeconds=1
            )
            
            messages = response.get('Messages', [])
            if not messages:
                print(f"No more messages found after batch {batch_num - 1}")
                break
                
            print(f"Processing batch {batch_num}/{max_batches} - {len(messages)} messages")
            
            batch_malformed = 0
            batch_fixed = 0
            
            for message in messages:
                try:
                    message_body = message['Body']
                    message_id = message.get('MessageId', 'unknown')
                    
                    if is_malformed_message(message_body):
                        malformed_found += 1
                        batch_malformed += 1
                        
                        # Extract original body
                        original_body = extract_original_body(message_body)
                        if original_body:
                            # Send corrected message
                            sqs.send_message(
                                QueueUrl=queue_url,
                                MessageBody=original_body,
                                DelaySeconds=0
                            )
                            
                            # Delete malformed message
                            sqs.delete_message(
                                QueueUrl=queue_url,
                                ReceiptHandle=message['ReceiptHandle']
                            )
                            
                            successfully_fixed += 1
                            batch_fixed += 1
                            print(f"Fixed malformed message: {message_id}")
                        else:
                            failed_to_fix += 1
                            print(f"Could not extract original body from: {message_id}")
                    else:
                        # Message is correctly formatted, delete it to avoid reprocessing
                        sqs.delete_message(
                            QueueUrl=queue_url,
                            ReceiptHandle=message['ReceiptHandle']
                        )
                        
                except Exception as e:
                    errors += 1
                    print(f"Error processing message {message.get('MessageId', 'unknown')}: {e}")
            
            total_processed += len(messages)
            print(f"Batch {batch_num} complete - Processed: {len(messages)}, Malformed: {batch_malformed}, Fixed: {batch_fixed}")
            
            # Small delay between batches
            time.sleep(0.1)
            
        except (ClientError, BotoCoreError) as e:
            print(f"AWS error in batch {batch_num}: {e}")
            errors += 1
            break
        except Exception as e:
            print(f"Unexpected error in batch {batch_num}: {e}")
            errors += 1
            break
    
    print("\n" + "="*60)
    print("FINAL STATISTICS")
    print("="*60)
    print(f"Batches processed: {batch_num}")
    print(f"Total messages processed: {total_processed}")
    print(f"Malformed messages found: {malformed_found}")
    print(f"Successfully fixed: {successfully_fixed}")
    print(f"Failed to fix: {failed_to_fix}")
    print(f"Errors: {errors}")
    
    return {
        'batches_processed': batch_num,
        'total_processed': total_processed,
        'malformed_found': malformed_found,
        'successfully_fixed': successfully_fixed,
        'failed_to_fix': failed_to_fix,
        'errors': errors
    }

if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python3 script.py <queue_url> <batch_size> <max_batches>")
        sys.exit(1)
    
    queue_url = sys.argv[1]
    batch_size = int(sys.argv[2])
    max_batches = int(sys.argv[3])
    
    fix_queue_messages(queue_url, batch_size, max_batches)
EOF
    
    # Make the script executable
    chmod +x "$temp_script"
    
    # Run the fix script
    print_info "Starting message fixing..."
    if AWS_PROFILE="$profile" python3 "$temp_script" "$queue_url" "$batch_size" "$max_batches"; then
        print_success "Message fixing completed successfully"
    else
        print_error "Message fixing failed"
        rm -f "$temp_script"
        exit 1
    fi
    
    # Clean up
    rm -f "$temp_script"
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --queue-url URL        SQS queue URL (if not provided, will auto-discover)"
    echo "  --batch-size SIZE      Number of messages per batch (default: 100)"
    echo "  --max-batches COUNT    Maximum number of batches to process (default: 1000)"
    echo "  --profile PROFILE      AWS profile to use (default: oracle-3)"
    echo "  --verbose              Enable verbose output"
    echo "  --help                 Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --queue-url https://sqs.us-east-1.amazonaws.com/123456789012/my-queue --batch-size 50 --max-batches 10"
    echo "  $0 --batch-size 100 --max-batches 1 --verbose"
    echo "  $0  # Auto-discover queue and use defaults"
}

# Function to parse command line arguments
parse_arguments() {
    QUEUE_URL=""
    BATCH_SIZE=100
    MAX_BATCHES=1000
    PROFILE="${AWS_PROFILE:-oracle-3}"
    VERBOSE=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --queue-url)
                QUEUE_URL="$2"
                shift 2
                ;;
            --batch-size)
                BATCH_SIZE="$2"
                shift 2
                ;;
            --max-batches)
                MAX_BATCHES="$2"
                shift 2
                ;;
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Main function
main() {
    print_header "Auto Queue Fixer"
    print_info "Starting queue fix process"
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Check prerequisites
    check_prerequisites
    
    print_info "Using AWS profile: $PROFILE"
    print_info "Batch size: $BATCH_SIZE"
    print_info "Max batches: $MAX_BATCHES"
    
    # Check AWS credentials
    check_aws_credentials "$PROFILE"
    
    # Get queue URL
    local queue_url="$QUEUE_URL"
    if [ -z "$queue_url" ]; then
        print_info "Auto-discovering SQS queue..."
        queue_url=$(discover_queues "$PROFILE")
        
        if [ -z "$queue_url" ]; then
            print_error "Could not discover SQS queue"
            exit 1
        fi
    else
        print_info "Using provided queue URL: $queue_url"
    fi
    
    # Get queue statistics
    print_info "Initial queue state:"
    get_queue_stats "$PROFILE" "$queue_url"
    
    # Ask for confirmation
    print_warning "This will process up to $MAX_BATCHES batches of $BATCH_SIZE messages each."
    print_info "Press Ctrl+C to cancel, or Enter to continue..."
    read -r
    
    # Fix messages
    fix_messages "$PROFILE" "$queue_url" "$BATCH_SIZE" "$MAX_BATCHES"
    
    print_success "Queue fixing process completed!"
}

# Run main function
main "$@"