#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| SQS Queue Component                |--/ /-|#
#|-/ /--| Creates SQS queues for messaging   |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

setup_sqs() {
    print_log -b "[queue] " "Setting up SQS..."
    validate_inputs
    setup_aws_environment

    SQS_QUEUE_NAME="dlq-${PROJECT_NAME}"
    if ! SQS_QUEUE_URL=$(aws sqs get-queue-url --queue-name $SQS_QUEUE_NAME --query QueueUrl --output text 2>/dev/null); then
        SQS_QUEUE_URL=""
    fi
    
    if [ -z "$SQS_QUEUE_URL" ] || [ "$SQS_QUEUE_URL" = "None" ]; then
        print_log -c "[create] " "Creating SQS Queue (DLQ)..."
        if ! SQS_QUEUE_URL=$(aws sqs create-queue --queue-name $SQS_QUEUE_NAME --query QueueUrl --output text); then
            print_log -r "[error] " "Failed to create SQS queue: ${SQS_QUEUE_NAME}"
            return 1
        fi
        
        # Verify queue was created successfully
        if [ -z "$SQS_QUEUE_URL" ] || [ "$SQS_QUEUE_URL" = "None" ]; then
            print_log -r "[error] " "SQS queue creation returned invalid URL"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for SQS queue to be available..."
        local retry_count=0
        while [ $retry_count -lt 10 ]; do
            if aws sqs get-queue-attributes --queue-url $SQS_QUEUE_URL --attribute-names QueueArn > /dev/null 2>&1; then
                print_log -g "[ready] " "SQS queue is available."
                break
            fi
            retry_count=$((retry_count + 1))
            print_log -y "[waiting] " "Still waiting for SQS queue to be ready... (attempt $retry_count/10)"
            sleep 2
        done
        
        if [ $retry_count -eq 10 ]; then
            print_log -r "[error] " "Timeout waiting for SQS queue to become available"
            return 1
        fi
        
        print_log -g "[ok] " "SQS Queue created: ${SQS_QUEUE_NAME}"
    else
        print_log -y "[skip] " "SQS Queue '${SQS_QUEUE_NAME}' already exists."
        # Verify the existing queue is accessible
        if ! aws sqs get-queue-attributes --queue-url $SQS_QUEUE_URL --attribute-names QueueArn > /dev/null 2>&1; then
            print_log -r "[error] " "Existing SQS queue is not accessible"
            return 1
        fi
        print_log -g "[verified] " "Existing SQS queue is accessible."
    fi
    
    # Get queue ARN
    if ! SQS_QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url $SQS_QUEUE_URL --attribute-names QueueArn --query "Attributes.QueueArn" --output text); then
        print_log -r "[error] " "Failed to get SQS queue ARN"
        return 1
    fi
    
    if [ -z "$SQS_QUEUE_ARN" ] || [ "$SQS_QUEUE_ARN" = "None" ]; then
        print_log -r "[error] " "Invalid SQS queue ARN received"
        return 1
    fi

    print_log -g "[ok] " "SQS setup complete!"
    print_log -m "[SQS Queue ARN] " "${SQS_QUEUE_ARN}"
    
    # Export variables for other components
    export SQS_QUEUE_ARN
    export SQS_QUEUE_URL
    export SQS_QUEUE_NAME
}

cleanup_sqs() {
    print_log -b "[delete] " "Cleaning up SQS..."
    validate_inputs
    setup_aws_environment

    SQS_QUEUE_NAME="dlq-${PROJECT_NAME}"
    print_log -b "[delete] " "Deleting SQS Queue..."
    
    if ! SQS_QUEUE_URL=$(aws sqs get-queue-url --queue-name $SQS_QUEUE_NAME --query QueueUrl --output text 2>/dev/null); then
        SQS_QUEUE_URL=""
    fi
    
    if [ ! -z "$SQS_QUEUE_URL" ] && [ "$SQS_QUEUE_URL" != "None" ]; then
        print_log -c "[delete] " "Deleting SQS Queue: ${SQS_QUEUE_NAME}"
        print_log -c "[info] " "Queue URL: ${SQS_QUEUE_URL}"
        
        # First, purge all messages from the queue
        print_log -c "[cleanup] " "Purging all messages from queue..."
        if ! aws sqs purge-queue --queue-url $SQS_QUEUE_URL 2>/dev/null; then
            print_log -y "[warn] " "Failed to purge queue messages (queue might be empty)"
        else
            print_log -y "[wait] " "Waiting for queue purge to complete..."
            sleep 5
        fi
        
        # Now delete the queue
        if ! aws sqs delete-queue --queue-url $SQS_QUEUE_URL; then
            print_log -r "[error] " "Failed to delete SQS queue: ${SQS_QUEUE_URL}"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for SQS queue to be fully deleted..."
        local retry_count=0
        while [ $retry_count -lt 10 ]; do
            if ! aws sqs get-queue-attributes --queue-url $SQS_QUEUE_URL --attribute-names QueueArn > /dev/null 2>&1; then
                print_log -g "[ok] " "SQS Queue deleted successfully."
                return 0
            fi
            retry_count=$((retry_count + 1))
            print_log -y "[waiting] " "Still waiting for queue deletion... (attempt $retry_count/10)"
            sleep 3
        done
        
        # Final check by queue name
        if aws sqs get-queue-url --queue-name $SQS_QUEUE_NAME > /dev/null 2>&1; then
            print_log -r "[error] " "Timeout waiting for SQS queue deletion to complete"
            return 1
        else
            print_log -g "[ok] " "SQS Queue deleted successfully."
        fi
    else
        print_log -y "[skip] " "SQS Queue '${SQS_QUEUE_NAME}' not found."
    fi
}

# Main execution
case "${1:-}" in
    setup)
        if ! setup_sqs; then
            print_log -r "[error] " "SQS setup failed"
            exit 1
        fi
        ;;
    cleanup)
        if ! cleanup_sqs; then
            print_log -r "[error] " "SQS cleanup failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac