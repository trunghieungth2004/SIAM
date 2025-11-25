#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| API Gateway Component              |--/ /-|#
#|-/ /--| Creates REST API for data queries  |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

update_frontend_config() {
    print_log -c "[frontend] " "Updating frontend configuration..."
    
    # Get S3 frontend bucket name and API key
    local setup_dir="$(dirname "$(dirname "$0")")"
    local resource_file="${setup_dir}/${PROJECT_NAME}_resources.txt"
    
    if [ -f "$resource_file" ]; then
        local frontend_bucket=$(grep "S3_FRONTEND_BUCKET" "$resource_file" | cut -d'=' -f2)
        local api_key=$(grep "API_KEY=" "$resource_file" | grep -v "API_KEY_ID" | cut -d'=' -f2)
        
        if [ -n "$frontend_bucket" ]; then
            # Check if Application directory exists
            local app_dir="$(dirname "$(dirname "$0")")/Application"
            if [ -d "$app_dir" ]; then
                # Create temporary directory
                local temp_dir="/tmp/siam-frontend-update-$$"
                mkdir -p "$temp_dir"
                
                # Copy and update app.js with API endpoint and key
                if [ -f "$app_dir/app.js" ]; then
                    cp "$app_dir/app.js" "$temp_dir/app.js"
                    sed -i "s|API_GATEWAY_ENDPOINT_PLACEHOLDER|$API_URL|g" "$temp_dir/app.js"
                    
                    # Inject API key securely
                    if [ -n "$api_key" ]; then
                        sed -i "s|API_KEY_PLACEHOLDER|$api_key|g" "$temp_dir/app.js"
                    fi
                    
                    # Upload updated app.js
                    if aws s3 cp "$temp_dir/app.js" "s3://${frontend_bucket}/app.js"; then
                        print_log -g "[ok] " "Frontend configuration updated with API endpoint and key"
                    else
                        print_log -y "[warn] " "Failed to update frontend configuration"
                    fi
                fi
                
                rm -rf "$temp_dir"
            fi
        fi
    fi
}setup_api_gateway() {
    print_log -b "[config] " "Setting up API Gateway..."
    validate_inputs
    setup_aws_environment

    API_NAME="${PROJECT_NAME}-api"
    QUERY_LAMBDA_NAME="${PROJECT_NAME}-query-lambda"
    
    # Create REST API
    print_log -c "[create] " "Creating REST API..."
    API_ID=$(aws apigateway create-rest-api --name "$API_NAME" --description "SIAM IoT Data Query API" --query 'id' --output text)
    if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
        print_log -r "[error] " "Failed to create REST API"
        return 1
    fi
    print_log -g "[created] " "API ID: $API_ID"

    # Get root resource ID
    ROOT_RESOURCE_ID=$(aws apigateway get-resources --rest-api-id "$API_ID" --query 'items[0].id' --output text)
    
    # Create /data resource
    print_log -c "[create] " "Creating /data resource..."
    DATA_RESOURCE_ID=$(aws apigateway create-resource \
        --rest-api-id "$API_ID" \
        --parent-id "$ROOT_RESOURCE_ID" \
        --path-part "data" \
        --query 'id' --output text)
    
    # Create OPTIONS method for CORS preflight
    print_log -c "[create] " "Creating OPTIONS method for CORS..."
    aws apigateway put-method \
        --rest-api-id "$API_ID" \
        --resource-id "$DATA_RESOURCE_ID" \
        --http-method OPTIONS \
        --authorization-type NONE
    
    # Add mock integration for OPTIONS
    aws apigateway put-integration \
        --rest-api-id "$API_ID" \
        --resource-id "$DATA_RESOURCE_ID" \
        --http-method OPTIONS \
        --type MOCK \
        --request-templates '{"application/json":"{\"statusCode\": 200}"}'
    
    # Add OPTIONS method response
    aws apigateway put-method-response \
        --rest-api-id "$API_ID" \
        --resource-id "$DATA_RESOURCE_ID" \
        --http-method OPTIONS \
        --status-code 200 \
        --response-parameters '{"method.response.header.Access-Control-Allow-Headers":false,"method.response.header.Access-Control-Allow-Methods":false,"method.response.header.Access-Control-Allow-Origin":false}'
    
    # Add OPTIONS integration response
    aws apigateway put-integration-response \
        --rest-api-id "$API_ID" \
        --resource-id "$DATA_RESOURCE_ID" \
        --http-method OPTIONS \
        --status-code 200 \
        --response-parameters '{"method.response.header.Access-Control-Allow-Headers":"'\''Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'\''","method.response.header.Access-Control-Allow-Methods":"'\''GET,OPTIONS'\''","method.response.header.Access-Control-Allow-Origin":"'\''*'\''"}' 
    
    # Create GET method on /data with API Key required
    print_log -c "[create] " "Creating GET method..."
    aws apigateway put-method \
        --rest-api-id "$API_ID" \
        --resource-id "$DATA_RESOURCE_ID" \
        --http-method GET \
        --authorization-type NONE \
        --api-key-required
    
    # Get Lambda function ARN
    LAMBDA_ARN=$(aws lambda get-function --function-name "$QUERY_LAMBDA_NAME" --query 'Configuration.FunctionArn' --output text 2>/dev/null)
    if [ -z "$LAMBDA_ARN" ] || [ "$LAMBDA_ARN" = "None" ]; then
        print_log -r "[error] " "Query Lambda function not found: $QUERY_LAMBDA_NAME"
        print_log -y "[info] " "Make sure Lambda component is deployed first"
        return 1
    fi
    
    # Set up Lambda integration
    print_log -c "[integrate] " "Integrating with Lambda function..."
    aws apigateway put-integration \
        --rest-api-id "$API_ID" \
        --resource-id "$DATA_RESOURCE_ID" \
        --http-method GET \
        --type AWS_PROXY \
        --integration-http-method POST \
        --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations"
    
    # Add Lambda permission for API Gateway
    print_log -c "[permission] " "Adding Lambda invoke permission..."
    aws lambda add-permission \
        --function-name "$QUERY_LAMBDA_NAME" \
        --statement-id "apigateway-invoke-${API_ID}" \
        --action lambda:InvokeFunction \
        --principal apigateway.amazonaws.com \
        --source-arn "arn:aws:execute-api:${AWS_REGION}:${ACCOUNT_ID}:${API_ID}/*/*" 2>/dev/null || true
    
    # Deploy API
    print_log -c "[deploy] " "Deploying API to prod stage..."
    aws apigateway create-deployment \
        --rest-api-id "$API_ID" \
        --stage-name prod \
        --description "Production deployment"
    
    # Create API Key
    print_log -c "[create] " "Creating API Key..."
    API_KEY_ID=$(aws apigateway create-api-key \
        --name "${PROJECT_NAME}-dashboard-key" \
        --description "API key for SIAM dashboard" \
        --enabled \
        --query 'id' --output text)
    
    API_KEY_VALUE=$(aws apigateway get-api-key \
        --api-key "$API_KEY_ID" \
        --include-value \
        --query 'value' --output text)
    
    # Create Usage Plan with throttling
    print_log -c "[create] " "Creating usage plan with rate limiting..."
    USAGE_PLAN_ID=$(aws apigateway create-usage-plan \
        --name "${PROJECT_NAME}-dashboard-plan" \
        --description "Usage plan for SIAM dashboard" \
        --throttle "rateLimit=10.0,burstLimit=20" \
        --quota "limit=10000,period=DAY" \
        --api-stages "apiId=${API_ID},stage=prod" \
        --query 'id' --output text)
    
    # Associate API key with usage plan
    print_log -c "[associate] " "Associating API key with usage plan..."
    aws apigateway create-usage-plan-key \
        --usage-plan-id "$USAGE_PLAN_ID" \
        --key-id "$API_KEY_ID" \
        --key-type API_KEY
    
    # Get API endpoint URL
    API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/prod/data"
    
    # Save API key securely
    local setup_dir="$(dirname "$(dirname "$0")")"
    local resource_file="${setup_dir}/${PROJECT_NAME}_resources.txt"
    echo "API_KEY=${API_KEY_VALUE}" >> "$resource_file"
    echo "API_KEY_ID=${API_KEY_ID}" >> "$resource_file"
    echo "USAGE_PLAN_ID=${USAGE_PLAN_ID}" >> "$resource_file"
    
    print_log -g "[ok] " "API Gateway setup complete!"
    print_log -m "[API Name] " "$API_NAME"
    print_log -m "[API ID] " "$API_ID"
    print_log -m "[Endpoint] " "$API_URL"
    print_log -m "[API Key] " "${API_KEY_VALUE:0:8}...${API_KEY_VALUE: -4}"
    print_log -y "[security] " "Full API key saved to ${resource_file}"
    
    # Export variables for other components
    export API_ID API_URL API_KEY_VALUE
    
    # Update frontend with API endpoint if S3 frontend bucket exists
    update_frontend_config
}

cleanup_api_gateway() {
    print_log -b "[delete] " "Cleaning up API Gateway..."
    validate_inputs
    setup_aws_environment

    API_NAME="${PROJECT_NAME}-api"
    local setup_dir="$(dirname "$(dirname "$0")")"
    local resource_file="${setup_dir}/${PROJECT_NAME}_resources.txt"
    
    # Get stored IDs from resource file
    if [ -f "$resource_file" ]; then
        local usage_plan_id=$(grep "USAGE_PLAN_ID=" "$resource_file" | cut -d'=' -f2)
        local api_key_id=$(grep "API_KEY_ID=" "$resource_file" | cut -d'=' -f2)
        
        # Delete usage plan
        if [ -n "$usage_plan_id" ] && [ "$usage_plan_id" != "None" ]; then
            print_log -c "[delete] " "Deleting usage plan: $usage_plan_id"
            aws apigateway delete-usage-plan --usage-plan-id "$usage_plan_id" 2>/dev/null || true
        fi
        
        # Delete API key
        if [ -n "$api_key_id" ] && [ "$api_key_id" != "None" ]; then
            print_log -c "[delete] " "Deleting API key: $api_key_id"
            aws apigateway delete-api-key --api-key "$api_key_id" 2>/dev/null || true
        fi
    fi
    
    # Find API by name
    API_ID=$(aws apigateway get-rest-apis --query "items[?name=='${API_NAME}'].id" --output text)
    
    if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
        print_log -c "[delete] " "Deleting REST API: $API_ID"
        if aws apigateway delete-rest-api --rest-api-id "$API_ID"; then
            print_log -g "[ok] " "API Gateway deleted successfully"
        else
            print_log -r "[error] " "Failed to delete API Gateway"
            return 1
        fi
    else
        print_log -y "[skip] " "API Gateway '$API_NAME' not found"
    fi
}

# Main execution
case "${1:-}" in
    setup)
        if ! setup_api_gateway; then
            print_log -r "[error] " "API Gateway setup failed"
            exit 1
        fi
        ;;
    cleanup)
        if ! cleanup_api_gateway; then
            print_log -r "[error] " "API Gateway cleanup failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac