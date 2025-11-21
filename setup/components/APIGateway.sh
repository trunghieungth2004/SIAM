#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| API Gateway Component              |--/ /-|#
#|-/ /--| Creates REST API for data queries  |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

update_frontend_config() {
    print_log -c "[frontend] " "Updating frontend configuration..."
    
    # Get S3 frontend bucket name
    local setup_dir="$(dirname "$(dirname "$0")")" 
    local resource_file="${setup_dir}/${PROJECT_NAME}_resources.txt"
    
    if [ -f "$resource_file" ]; then
        local frontend_bucket=$(grep "S3_FRONTEND_BUCKET" "$resource_file" | cut -d'=' -f2)
        if [ -n "$frontend_bucket" ]; then
            # Check if Application directory exists
            local app_dir="$(dirname "$(dirname "$0")")/Application"
            if [ -d "$app_dir" ]; then
                # Create temporary directory
                local temp_dir="/tmp/siam-frontend-update-$$"
                mkdir -p "$temp_dir"
                
                # Copy and update app.js
                if [ -f "$app_dir/app.js" ]; then
                    cp "$app_dir/app.js" "$temp_dir/app.js"
                    sed -i "s|API_GATEWAY_ENDPOINT_PLACEHOLDER|$API_URL|g" "$temp_dir/app.js"
                    
                    # Upload updated app.js
                    if aws s3 cp "$temp_dir/app.js" "s3://${frontend_bucket}/app.js"; then
                        print_log -g "[ok] " "Frontend configuration updated with API endpoint"
                    else
                        print_log -y "[warn] " "Failed to update frontend configuration"
                    fi
                fi
                
                rm -rf "$temp_dir"
            fi
        fi
    fi
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
    
    # Create GET method on /data
    print_log -c "[create] " "Creating GET method..."
    aws apigateway put-method \
        --rest-api-id "$API_ID" \
        --resource-id "$DATA_RESOURCE_ID" \
        --http-method GET \
        --authorization-type NONE
    
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
    
    # Get API endpoint URL
    API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/prod/data"
    
    print_log -g "[ok] " "API Gateway setup complete!"
    print_log -m "[API Name] " "$API_NAME"
    print_log -m "[API ID] " "$API_ID"
    print_log -m "[Endpoint] " "$API_URL"
    
    # Export variables for other components
    export API_ID API_URL
    
    # Update frontend with API endpoint if S3 frontend bucket exists
    update_frontend_config
}

cleanup_api_gateway() {
    print_log -b "[delete] " "Cleaning up API Gateway..."
    validate_inputs
    setup_aws_environment

    API_NAME="${PROJECT_NAME}-api"
    
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