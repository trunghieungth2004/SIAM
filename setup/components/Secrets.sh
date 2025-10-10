#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| Secrets Manager Component          |--/ /-|#
#|-/ /--| Creates secrets for secure storage |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

setup_secrets() {
    print_log -b "[config] " "Setting up Secrets Manager..."
    validate_inputs
    setup_aws_environment

    SECRET_NAME="${PROJECT_NAME}/api-keys"
    if ! aws secretsmanager describe-secret --secret-id $SECRET_NAME > /dev/null 2>&1; then
        print_log -c "[create] " "Creating Secrets Manager Secret..."
        if ! aws secretsmanager create-secret --name $SECRET_NAME --secret-string '{"apikey":"12345-abcde","description":"IoT API keys and configuration"}'; then
            print_log -r "[error] " "Failed to create secret: ${SECRET_NAME}"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for secret to be available..."
        local retry_count=0
        while [ $retry_count -lt 10 ]; do
            if aws secretsmanager describe-secret --secret-id $SECRET_NAME > /dev/null 2>&1; then
                print_log -g "[ready] " "Secret is available."
                break
            fi
            retry_count=$((retry_count + 1))
            print_log -y "[waiting] " "Still waiting for secret to be ready... (attempt $retry_count/10)"
            sleep 2
        done
        
        if [ $retry_count -eq 10 ]; then
            print_log -r "[error] " "Timeout waiting for secret to become available"
            return 1
        fi
    else
        print_log -y "[skip] " "Secret '${SECRET_NAME}' already exists."
        # Verify the secret is accessible
        if ! aws secretsmanager get-secret-value --secret-id $SECRET_NAME > /dev/null 2>&1; then
            print_log -r "[error] " "Existing secret is not accessible"
            return 1
        fi
        print_log -g "[verified] " "Existing secret is accessible."
    fi

    print_log -g "[ok] " "Secrets Manager setup complete!"
    print_log -m "[Secret Name] " "${SECRET_NAME}"
    
    # Export variables for other components
    export SECRET_NAME
}

cleanup_secrets() {
    print_log -b "[delete] " "Cleaning up Secrets Manager..."
    validate_inputs
    setup_aws_environment

    SECRET_NAME="${PROJECT_NAME}/api-keys"
    print_log -b "[delete] " "Deleting Secrets Manager Secret..."
    
    # Check if secret exists before attempting deletion
    if aws secretsmanager describe-secret --secret-id $SECRET_NAME > /dev/null 2>&1; then
        print_log -c "[delete] " "Deleting secret: ${SECRET_NAME}"
        if ! aws secretsmanager delete-secret --secret-id $SECRET_NAME --force-delete-without-recovery; then
            print_log -r "[error] " "Failed to delete secret: ${SECRET_NAME}"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for secret to be fully deleted..."
        local retry_count=0
        while [ $retry_count -lt 10 ]; do
            if ! aws secretsmanager describe-secret --secret-id $SECRET_NAME > /dev/null 2>&1; then
                print_log -g "[ok] " "Secret deleted successfully."
                return 0
            fi
            retry_count=$((retry_count + 1))
            print_log -y "[waiting] " "Still waiting for secret deletion... (attempt $retry_count/10)"
            sleep 2
        done
        
        print_log -r "[error] " "Timeout waiting for secret deletion to complete"
        return 1
    else
        print_log -y "[skip] " "Secret '${SECRET_NAME}' does not exist."
    fi
}

# Main execution
case "${1:-}" in
    setup)
        if ! setup_secrets; then
            print_log -r "[error] " "Secrets Manager setup failed"
            exit 1
        fi
        ;;
    cleanup)
        if ! cleanup_secrets; then
            print_log -r "[error] " "Secrets Manager cleanup failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac