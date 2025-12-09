#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| SNS Notification Component         |--/ /-|#
#|-/ /--| Creates SNS topics for alerts      |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

validate_email() {
    local email="$1"
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

setup_sns() {
    print_log -b "[messaging] " "Setting up SNS..."
    validate_inputs
    setup_aws_environment

    SNS_TOPIC_NAME="${PROJECT_NAME}-high-temp-alerts"
    if ! SNS_TOPIC_ARN=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':${SNS_TOPIC_NAME}')].TopicArn" --output text); then
        print_log -r "[error] " "Failed to check for existing SNS topics"
        return 1
    fi
    
    if [ -z "$SNS_TOPIC_ARN" ] || [ "$SNS_TOPIC_ARN" = "None" ]; then
        print_log -c "[create] " "Creating SNS Topic..."
        if ! SNS_TOPIC_ARN=$(aws sns create-topic --name $SNS_TOPIC_NAME --query TopicArn --output text); then
            print_log -r "[error] " "Failed to create SNS topic: ${SNS_TOPIC_NAME}"
            return 1
        fi
        
        # Verify topic was created successfully
        if [ -z "$SNS_TOPIC_ARN" ] || [ "$SNS_TOPIC_ARN" = "None" ]; then
            print_log -r "[error] " "SNS topic creation returned invalid ARN"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for SNS topic to be available..."
        local retry_count=0
        while [ $retry_count -lt 10 ]; do
            if aws sns get-topic-attributes --topic-arn $SNS_TOPIC_ARN > /dev/null 2>&1; then
                print_log -g "[ready] " "SNS topic is available."
                break
            fi
            retry_count=$((retry_count + 1))
            print_log -y "[waiting] " "Still waiting for SNS topic to be ready... (attempt $retry_count/10)"
            sleep 2
        done
        
        if [ $retry_count -eq 10 ]; then
            print_log -r "[error] " "Timeout waiting for SNS topic to become available"
            return 1
        fi
        
        print_log -g "[ok] " "SNS Topic created: ${SNS_TOPIC_NAME}"
    else
        print_log -y "[skip] " "SNS Topic '${SNS_TOPIC_NAME}' already exists."
        # Verify the existing topic is accessible
        if ! aws sns get-topic-attributes --topic-arn $SNS_TOPIC_ARN > /dev/null 2>&1; then
            print_log -r "[error] " "Existing SNS topic is not accessible"
            return 1
        fi
        print_log -g "[verified] " "Existing SNS topic is accessible."
    fi

    # Use email addresses from environment variable
    local email_input="$SNS_EMAIL_ADDRESSES"
    
    # Skip if empty
    if [ -z "$email_input" ]; then
        print_log -y "[skip] " "No email addresses provided. Skipping subscriptions."
    else
        print_log -c "[subscribe] " "Email subscription setup"
        
        local emails_valid=false
        
        while [ "$emails_valid" = false ]; do
        
        # Split by comma and validate each email
        IFS=',' read -ra EMAIL_ARRAY <<< "$email_input"
        local all_valid=true
        local invalid_emails=()
        
        for email in "${EMAIL_ARRAY[@]}"; do
            # Trim whitespace
            email=$(echo "$email" | xargs)
            
            if ! validate_email "$email"; then
                all_valid=false
                invalid_emails+=("$email")
            fi
        done
        
            if [ "$all_valid" = true ]; then
                emails_valid=true
                
                # Subscribe each email
                print_log -c "[subscribe] " "Subscribing ${#EMAIL_ARRAY[@]} email(s) to SNS topic..."
                
                for email in "${EMAIL_ARRAY[@]}"; do
                    email=$(echo "$email" | xargs)
                    print_log -c "[email] " "Subscribing: $email"
                    
                    if aws sns subscribe \
                        --topic-arn "$SNS_TOPIC_ARN" \
                        --protocol email \
                        --notification-endpoint "$email" > /dev/null 2>&1; then
                        print_log -g "[ok] " "Subscription request sent to $email"
                    else
                        print_log -r "[error] " "Failed to subscribe $email"
                    fi
                done
                
                print_log -y "[action] " "Check email inbox(es) and confirm subscription(s) to receive alerts"
            else
                print_log -r "[error] " "Invalid email address(es): ${invalid_emails[*]}"
                print_log -r "[error] " "SNS setup failed due to invalid email addresses"
                return 1
            fi
        done
    fi

    print_log -g "[ok] " "SNS setup complete!"
    print_log -m "[SNS Topic ARN] " "${SNS_TOPIC_ARN}"
    
    # Export variables for other components
    export SNS_TOPIC_ARN
    export SNS_TOPIC_NAME
}

cleanup_sns() {
    print_log -b "[delete] " "Cleaning up SNS..."
    validate_inputs
    setup_aws_environment

    SNS_TOPIC_NAME="${PROJECT_NAME}-high-temp-alerts"
    print_log -b "[delete] " "Deleting SNS Topic..."
    
    if ! SNS_TOPIC_ARN=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':${SNS_TOPIC_NAME}')].TopicArn" --output text 2>/dev/null); then
        print_log -r "[error] " "Failed to check for existing SNS topics"
        return 1
    fi
    
    if [ ! -z "$SNS_TOPIC_ARN" ] && [ "$SNS_TOPIC_ARN" != "None" ]; then
        print_log -c "[delete] " "Deleting SNS Topic: ${SNS_TOPIC_NAME}"
        print_log -c "[info] " "Topic ARN: ${SNS_TOPIC_ARN}"
        
        # First, list and delete all subscriptions
        print_log -c "[cleanup] " "Removing all subscriptions from topic..."
        SUBSCRIPTIONS=$(aws sns list-subscriptions-by-topic --topic-arn $SNS_TOPIC_ARN --query "Subscriptions[].SubscriptionArn" --output text 2>/dev/null)
        if [ ! -z "$SUBSCRIPTIONS" ] && [ "$SUBSCRIPTIONS" != "None" ]; then
            for SUB_ARN in $SUBSCRIPTIONS; do
                if [ "$SUB_ARN" != "PendingConfirmation" ]; then
                    print_log -c "[unsubscribe] " "Removing subscription: ${SUB_ARN}"
                    aws sns unsubscribe --subscription-arn $SUB_ARN 2>/dev/null || true
                fi
            done
            print_log -y "[wait] " "Waiting for subscriptions to be removed..."
            sleep 3
        fi
        
        # Now delete the topic
        if ! aws sns delete-topic --topic-arn $SNS_TOPIC_ARN; then
            print_log -r "[error] " "Failed to delete SNS topic: ${SNS_TOPIC_ARN}"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for SNS topic to be fully deleted..."
        local retry_count=0
        while [ $retry_count -lt 10 ]; do
            if ! aws sns get-topic-attributes --topic-arn $SNS_TOPIC_ARN > /dev/null 2>&1; then
                print_log -g "[ok] " "SNS Topic deleted successfully."
                return 0
            fi
            retry_count=$((retry_count + 1))
            print_log -y "[waiting] " "Still waiting for topic deletion... (attempt $retry_count/10)"
            sleep 2
        done
        
        print_log -r "[error] " "Timeout waiting for SNS topic deletion to complete"
        return 1
    else
        print_log -y "[skip] " "SNS Topic '${SNS_TOPIC_NAME}' not found."
    fi
}

# Main execution
case "${1:-}" in
    setup)
        if ! setup_sns; then
            print_log -r "[error] " "SNS setup failed"
            exit 1
        fi
        ;;
    cleanup)
        if ! cleanup_sns; then
            print_log -r "[error] " "SNS cleanup failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac