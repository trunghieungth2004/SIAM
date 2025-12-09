#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| API Gateway Component              |--/ /-|#
#|-/ /--| Creates REST API for data queries  |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

update_frontend_config() {
    print_log -c "[frontend] " "Updating frontend configuration..."
    
    # Ensure environment is set up
    validate_inputs
    setup_aws_environment
    
    # Discover frontend bucket by naming pattern
    local project_clean=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    local frontend_bucket=$(aws s3api list-buckets --query "Buckets[?contains(Name, '${project_clean}') && contains(Name, 'frontend')].Name" --output text 2>/dev/null | head -1)
    
    if [ -z "$frontend_bucket" ] || [ "$frontend_bucket" = "None" ]; then
        print_log -y "[warn] " "Frontend bucket not found, skipping frontend update"
        return 0
    fi
    
    print_log -g "[found] " "Frontend bucket: $frontend_bucket"
    
    # Discover API key from current API
    local api_name="${PROJECT_NAME}-api"
    local api_id=$(aws apigateway get-rest-apis --region "${AWS_REGION}" --query "items[?name=='${api_name}'].id" --output text 2>/dev/null)
    
    if [ -z "$api_id" ] || [ "$api_id" = "None" ]; then
        print_log -y "[warn] " "API Gateway not found, cannot retrieve API key"
        return 0
    fi
    
    # Construct API URL from discovered API ID
    local api_url="https://${api_id}.execute-api.${AWS_REGION}.amazonaws.com/prod/data"
    print_log -g "[found] " "API endpoint: $api_url"
    
    # Get usage plan associated with this API
    local usage_plan_id=$(aws apigateway get-usage-plans --region "${AWS_REGION}" --query "items[?contains(name, '${PROJECT_NAME}')].id" --output text 2>/dev/null | head -1)
    
    if [ -z "$usage_plan_id" ] || [ "$usage_plan_id" = "None" ]; then
        print_log -y "[warn] " "Usage plan not found, cannot retrieve API key"
        return 0
    fi
    
    # Get API key from usage plan
    local api_key_id=$(aws apigateway get-usage-plan-keys --region "${AWS_REGION}" --usage-plan-id "$usage_plan_id" --query 'items[0].id' --output text 2>/dev/null)
    
    if [ -z "$api_key_id" ] || [ "$api_key_id" = "None" ]; then
        print_log -y "[warn] " "API key not found in usage plan"
        return 0
    fi
    
    local api_key=$(aws apigateway get-api-key --region "${AWS_REGION}" --api-key "$api_key_id" --include-value --query 'value' --output text 2>/dev/null)
    
    # Check if Application directory exists
    local app_dir="$(dirname "$(dirname "$0")")/Application"
    if [ ! -d "$app_dir" ]; then
        print_log -y "[warn] " "Application directory not found: $app_dir"
        return 0
    fi
    
    # Create temporary directory
    local temp_dir="/tmp/siam-frontend-update-$$"
    mkdir -p "$temp_dir"
    
    # Copy and update app.js with API endpoint and key
    if [ -f "$app_dir/app.js" ]; then
        cp "$app_dir/app.js" "$temp_dir/app.js"
        sed -i "s|API_GATEWAY_ENDPOINT_PLACEHOLDER|$api_url|g" "$temp_dir/app.js"
        
        # Inject API key securely
        if [ -n "$api_key" ]; then
            sed -i "s|API_KEY_PLACEHOLDER|$api_key|g" "$temp_dir/app.js"
        fi
        
        # Upload updated app.js
        if aws s3 cp "$temp_dir/app.js" "s3://${frontend_bucket}/app.js"; then
            print_log -g "[ok] " "Frontend app.js updated with API endpoint and key"
        else
            print_log -y "[warn] " "Failed to update app.js"
        fi
    fi
    
    # Copy and update swagger.html with API endpoint
    if [ -f "$app_dir/swagger.html" ]; then
        cp "$app_dir/swagger.html" "$temp_dir/swagger.html"
        sed -i "s|API_GATEWAY_ENDPOINT_PLACEHOLDER|$api_url|g" "$temp_dir/swagger.html"
        
        # Upload updated swagger.html
        if aws s3 cp "$temp_dir/swagger.html" "s3://${frontend_bucket}/swagger.html"; then
            print_log -g "[ok] " "Swagger page updated with API endpoint"
        else
            print_log -y "[warn] " "Failed to update swagger.html"
        fi
    fi
    
    rm -rf "$temp_dir"
}

setup_api_gateway() {
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
    
    # Add method response with CORS headers for GET
    aws apigateway put-method-response \
        --rest-api-id "$API_ID" \
        --resource-id "$DATA_RESOURCE_ID" \
        --http-method GET \
        --status-code 200 \
        --response-parameters '{"method.response.header.Access-Control-Allow-Origin":false}'
    
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
    
    # Add integration response with CORS headers
    aws apigateway put-integration-response \
        --rest-api-id "$API_ID" \
        --resource-id "$DATA_RESOURCE_ID" \
        --http-method GET \
        --status-code 200 \
        --response-parameters '{"method.response.header.Access-Control-Allow-Origin":"'\''*'\''"}' \
        --response-templates '{"application/json":""}'
    
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
    
    print_log -g "[ok] " "API Gateway setup complete!"
    print_log -m "[API Name] " "$API_NAME"
    print_log -m "[API ID] " "$API_ID"
    print_log -m "[Endpoint] " "$API_URL"
    print_log -m "[API Key] " "$API_KEY_VALUE"
    print_log -c "[info] " "For Swagger UI: Enter API key in the input box at the top-right of swagger.html"
    print_log -y "[security] " "Store this API key securely - it won't be shown again"
    
    # Export OpenAPI specification
    print_log -c "[export] " "Exporting OpenAPI specification..."
    if aws apigateway get-export \
        --rest-api-id "$API_ID" \
        --stage-name prod \
        --export-type swagger \
        --accepts application/json \
        openapi.json 2>/dev/null; then
        print_log -g "[ok] " "OpenAPI spec exported to openapi.json"
    else
        print_log -y "[warn] " "Failed to export OpenAPI specification"
    fi
    
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
    
    # Check if any APIs exist first
    local api_ids=$(aws apigateway get-rest-apis --query "items[?name=='${API_NAME}'].id" --output text 2>/dev/null)
    
    if [ -n "$api_ids" ] && [ "$api_ids" != "None" ]; then
        for API_ID in $api_ids; do
            if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
                print_log -c "[delete] " "Deleting REST API: $API_ID"
                while true; do
                    if aws apigateway delete-rest-api --rest-api-id "$API_ID" 2>/dev/null; then
                        print_log -g "[ok] " "API Gateway $API_ID deleted successfully"
                        break
                    fi
                    print_log -y "[retry] " "Delete API failed, retrying..."
                    sleep 2
                done
            fi
        done
    else
        print_log -y "[skip] " "No API Gateway found with name '$API_NAME'"
    fi
    
    # Check if any usage plans exist
    local usage_plan_ids=$(aws apigateway get-usage-plans --query "items[?contains(name, '${PROJECT_NAME}')].id" --output text 2>/dev/null)
    
    if [ -n "$usage_plan_ids" ] && [ "$usage_plan_ids" != "None" ]; then
        print_log -c "[delete] " "Found usage plans to delete"
        for usage_plan_id in $usage_plan_ids; do
            if [ -n "$usage_plan_id" ] && [ "$usage_plan_id" != "None" ]; then
                # Get API keys associated with this usage plan
                local api_key_ids=$(aws apigateway get-usage-plan-keys --usage-plan-id "$usage_plan_id" --query 'items[].id' --output text 2>/dev/null)
                
                # Delete each API key with retry
                for api_key_id in $api_key_ids; do
                    if [ -n "$api_key_id" ] && [ "$api_key_id" != "None" ]; then
                        print_log -c "[delete] " "Deleting API key: $api_key_id"
                        while true; do
                            if aws apigateway delete-api-key --api-key "$api_key_id" 2>/dev/null; then
                                break
                            fi
                            sleep 2
                        done
                    fi
                done
                
                # Delete usage plan with retry
                print_log -c "[delete] " "Deleting usage plan: $usage_plan_id"
                while true; do
                    if aws apigateway delete-usage-plan --usage-plan-id "$usage_plan_id" 2>/dev/null; then
                        break
                    fi
                    sleep 2
                done
            fi
        done
    else
        print_log -y "[skip] " "No usage plans found for project '${PROJECT_NAME}'"
    fi
    
    # Verify cleanup success
    print_log -c "[verify] " "Verifying cleanup completion..."
    local remaining_apis=$(aws apigateway get-rest-apis --query "items[?name=='${API_NAME}'].id" --output text 2>/dev/null)
    local remaining_plans=$(aws apigateway get-usage-plans --query "items[?contains(name, '${PROJECT_NAME}')].id" --output text 2>/dev/null)
    
    if [ -z "$remaining_apis" ] || [ "$remaining_apis" = "None" ]; then
        if [ -z "$remaining_plans" ] || [ "$remaining_plans" = "None" ]; then
            print_log -g "[verified] " "API Gateway cleanup completed successfully"
        else
            print_log -y "[warn] " "Some usage plans may still exist"
        fi
    else
        print_log -r "[error] " "Some API Gateway resources may still exist"
        return 1
    fi
}

rotate_api_key() {
    print_log -b "[rotate] " "Manually triggering API key rotation..."
    validate_inputs
    setup_aws_environment

    ROTATE_LAMBDA_NAME="func-rotate-api-${PROJECT_NAME}"
    
    # Check if Lambda exists
    if ! aws lambda get-function --function-name "$ROTATE_LAMBDA_NAME" > /dev/null 2>&1; then
        print_log -r "[error] " "Rotation Lambda not found: $ROTATE_LAMBDA_NAME"
        print_log -y "[info] " "Please run EventBridge setup first: ./AWS.sh setup (select EventBridge)"
        return 1
    fi
    
    # Invoke Lambda
    print_log -c "[invoke] " "Invoking rotation Lambda..."
    if aws lambda invoke --function-name "$ROTATE_LAMBDA_NAME" /tmp/rotate-output.json > /dev/null 2>&1; then
        print_log -g "[ok] " "API key rotation completed successfully"
        if [ -f /tmp/rotate-output.json ]; then
            print_log -y "[result] " "$(cat /tmp/rotate-output.json | jq -r '.body' 2>/dev/null || cat /tmp/rotate-output.json)"
            rm -f /tmp/rotate-output.json
        fi
    else
        print_log -r "[error] " "API key rotation failed"
        return 1
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
    rotate)
        if ! rotate_api_key; then
            print_log -r "[error] " "API key rotation failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup|rotate}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac