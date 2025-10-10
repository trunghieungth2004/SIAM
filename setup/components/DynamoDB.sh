#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| DynamoDB Component                 |--/ /-|#
#|-/ /--| Creates DynamoDB tables            |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

setup_dynamodb() {
    print_log -b "[database] " "Setting up DynamoDB..."
    validate_inputs
    setup_aws_environment

    DDB_TABLE_NAME="${PROJECT_NAME}-sensor-readings"
    if ! aws dynamodb describe-table --table-name $DDB_TABLE_NAME > /dev/null 2>&1; then
        print_log -c "[create] " "Creating DynamoDB Table..."
        if ! aws dynamodb create-table \
            --table-name $DDB_TABLE_NAME \
            --attribute-definitions AttributeName=device_id,AttributeType=S AttributeName=timestamp,AttributeType=N \
            --key-schema AttributeName=device_id,KeyType=HASH AttributeName=timestamp,KeyType=RANGE \
            --billing-mode PAY_PER_REQUEST; then
            print_log -r "[error] " "Failed to create DynamoDB table: ${DDB_TABLE_NAME}"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for DynamoDB table '${DDB_TABLE_NAME}' to become available..."
        if ! aws dynamodb wait table-exists --table-name $DDB_TABLE_NAME; then
            print_log -r "[error] " "Timeout waiting for DynamoDB table to become available"
            return 1
        fi
        print_log -g "[ready] " "DynamoDB table is now active."
        
        print_log -c "[config] " "Enabling Time-To-Live on table..."
        if ! aws dynamodb update-time-to-live --table-name $DDB_TABLE_NAME --time-to-live-specification "Enabled=true, AttributeName=ttl"; then
            print_log -r "[error] " "Failed to enable TTL on DynamoDB table"
            return 1
        fi
        print_log -g "[ok] " "TTL enabled successfully."
    else
        print_log -y "[skip] " "DynamoDB table '${DDB_TABLE_NAME}' already exists."
        print_log -y "[verify] " "Verifying table is active..."
        if ! aws dynamodb wait table-exists --table-name $DDB_TABLE_NAME; then
            print_log -r "[error] " "Existing DynamoDB table is not in active state"
            return 1
        fi
    fi

    print_log -g "[ok] " "DynamoDB setup complete!"
    print_log -m "[DynamoDB Table] " "${DDB_TABLE_NAME}"
    
    # Export variables for other components
    export DDB_TABLE_NAME
}

cleanup_dynamodb() {
    print_log -b "[delete] " "Cleaning up DynamoDB..."
    validate_inputs
    setup_aws_environment

    DDB_TABLE_NAME="${PROJECT_NAME}-sensor-readings"
    print_log -b "[delete] " "Deleting DynamoDB Table..."
    
    # Check if table exists before attempting deletion
    if aws dynamodb describe-table --table-name $DDB_TABLE_NAME > /dev/null 2>&1; then
        print_log -c "[delete] " "Deleting table: ${DDB_TABLE_NAME}"
        if ! aws dynamodb delete-table --table-name $DDB_TABLE_NAME; then
            print_log -r "[error] " "Failed to initiate DynamoDB table deletion"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for table to be fully deleted..."
        if ! aws dynamodb wait table-not-exists --table-name $DDB_TABLE_NAME; then
            print_log -r "[error] " "Timeout waiting for DynamoDB table deletion"
            return 1
        fi
        print_log -g "[ok] " "DynamoDB table deleted successfully."
    else
        print_log -y "[skip] " "DynamoDB table '${DDB_TABLE_NAME}' does not exist."
    fi
}

# Main execution
case "${1:-}" in
    setup)
        if ! setup_dynamodb; then
            print_log -r "[error] " "DynamoDB setup failed"
            exit 1
        fi
        ;;
    cleanup)
        if ! cleanup_dynamodb; then
            print_log -r "[error] " "DynamoDB cleanup failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac