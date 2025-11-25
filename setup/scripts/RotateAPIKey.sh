#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| API Key Rotation Script            |--/ /-|#
#|-/ /--| Rotates API Gateway key securely   |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../components/common.sh"

rotate_api_key() {
    print_log -b "[rotate] " "Starting API key rotation..."
    validate_inputs
    setup_aws_environment
    
    local api_name="${PROJECT_NAME}-api"
    local usage_plan_name="${PROJECT_NAME}-dashboard-plan"
    
    # Discover API Gateway
    print_log -c "[discover] " "Finding API Gateway..."
    local api_id=$(aws apigateway get-rest-apis --query "items[?name=='${api_name}'].id" --output text)
    
    if [ -z "$api_id" ] || [ "$api_id" == "None" ]; then
        print_log -r "[error] " "API Gateway '${api_name}' not found"
        return 1
    fi
    
    local api_url="https://${api_id}.execute-api.${AWS_REGION}.amazonaws.com/prod/data"
    print_log -g "[found] " "API: ${api_id}"
    
    # Discover usage plan
    print_log -c "[discover] " "Finding usage plan..."
    local usage_plan_id=$(aws apigateway get-usage-plans --query "items[?name=='${usage_plan_name}'].id" --output text)
    
    if [ -z "$usage_plan_id" ] || [ "$usage_plan_id" == "None" ]; then
        print_log -r "[error] " "Usage plan '${usage_plan_name}' not found"
        return 1
    fi
    print_log -g "[found] " "Usage Plan: ${usage_plan_id}"
    
    # Get current API key from usage plan
    print_log -c "[discover] " "Finding current API key..."
    local old_api_key_id=$(aws apigateway get-usage-plan-keys \
        --usage-plan-id "$usage_plan_id" \
        --query 'items[0].id' --output text)
    
    if [ -n "$old_api_key_id" ] && [ "$old_api_key_id" != "None" ]; then
        print_log -g "[found] " "Current API Key: ${old_api_key_id}"
    fi
    
    # Discover S3 frontend bucket
    print_log -c "[discover] " "Finding S3 frontend bucket..."
    local project_clean=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    local frontend_bucket=$(aws s3api list-buckets --query "Buckets[?starts_with(Name, '${project_clean}') && contains(Name, 'frontend')].Name" --output text | head -n1)
    
    if [ -n "$frontend_bucket" ] && [ "$frontend_bucket" != "None" ]; then
        print_log -g "[found] " "Frontend Bucket: ${frontend_bucket}"
    else
        print_log -y "[warn] " "Frontend bucket not found, will skip frontend update"
    fi
    
    # Create new API key
    print_log -c "[create] " "Creating new API key..."
    local new_api_key_id=$(aws apigateway create-api-key \
        --name "${PROJECT_NAME}-dashboard-key-$(date +%Y%m%d-%H%M%S)" \
        --description "API key for SIAM dashboard (rotated)" \
        --enabled \
        --query 'id' --output text)
    
    local new_api_key_value=$(aws apigateway get-api-key \
        --api-key "$new_api_key_id" \
        --include-value \
        --query 'value' --output text)
    
    # Associate new key with usage plan
    print_log -c "[associate] " "Associating new key with usage plan..."
    aws apigateway create-usage-plan-key \
        --usage-plan-id "$usage_plan_id" \
        --key-id "$new_api_key_id" \
        --key-type API_KEY
    
    # Update frontend with new API key
    if [ -n "$frontend_bucket" ]; then
        print_log -c "[update] " "Updating frontend with new API key..."
        local temp_dir="/tmp/siam-api-rotation-$$"
        mkdir -p "$temp_dir"
        
        # Download current app.js
        if aws s3 cp "s3://${frontend_bucket}/app.js" "$temp_dir/app_orig.js" 2>/dev/null; then
            # Create new app.js with updated credentials
            cat > "$temp_dir/app.js" <<EOF
// Configuration - API Gateway endpoint will be injected here
const API_ENDPOINT = '${api_url}';
const API_KEY = '${new_api_key_value}';
EOF
            # Append the rest of the original file (skip first 3 lines)
            tail -n +4 "$temp_dir/app_orig.js" >> "$temp_dir/app.js"
            
            # Upload updated file
            if aws s3 cp "$temp_dir/app.js" "s3://${frontend_bucket}/app.js"; then
                print_log -g "[ok] " "Frontend updated with new API key"
            else
                print_log -y "[warn] " "Failed to update frontend"
            fi
        else
            print_log -y "[warn] " "Could not download app.js from S3"
        fi
        
        rm -rf "$temp_dir"
    fi
    
    # Save to resource file for reference
    local setup_dir="$(dirname "$SCRIPT_DIR")"
    local resource_file="${setup_dir}/${PROJECT_NAME}_resources.txt"
    if [ -f "$resource_file" ]; then
        print_log -c "[update] " "Updating resource file..."
        sed -i "/API_KEY=/d" "$resource_file"
        sed -i "/API_KEY_ID=/d" "$resource_file"
        echo "API_KEY=${new_api_key_value}" >> "$resource_file"
        echo "API_KEY_ID=${new_api_key_id}" >> "$resource_file"
    fi
    
    # Remove old API key from usage plan and delete it
    if [ -n "$old_api_key_id" ] && [ "$old_api_key_id" != "None" ]; then
        print_log -c "[delete] " "Removing old API key from usage plan..."
        aws apigateway delete-usage-plan-key \
            --usage-plan-id "$usage_plan_id" \
            --key-id "$old_api_key_id" 2>/dev/null || true
        
        print_log -c "[delete] " "Deleting old API key..."
        aws apigateway delete-api-key --api-key "$old_api_key_id" 2>/dev/null || true
    fi
    
    print_log -g "[ok] " "API key rotation complete!"
    print_log -m "[API Gateway] " "${api_id}"
    print_log -m "[Old Key ID] " "${old_api_key_id:-N/A}"
    print_log -m "[New Key ID] " "${new_api_key_id}"
    print_log -m "[New Key] " "${new_api_key_value:0:8}...${new_api_key_value: -4}"
    if [ -f "$resource_file" ]; then
        print_log -y "[security] " "Full API key saved to ${resource_file}"
    fi
    print_log -y "[info] " "Old API key has been revoked"
}

# Main execution
if [ -z "${PROJECT_NAME:-}" ] || [ -z "${THING_NAME:-}" ]; then
    echo "Error: Required environment variables not set"
    echo "Usage: PROJECT_NAME=<name> THING_NAME=<thing> $0"
    exit 1
fi

rotate_api_key
