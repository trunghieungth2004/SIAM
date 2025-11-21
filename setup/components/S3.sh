#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| S3 Storage Component               |--/ /-|#
#|-/ /--| Creates S3 buckets for data & web  |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Exit on any error
set -e

# Source common utilities
source "$(dirname "$0")/common.sh"

deploy_frontend() {
    print_log -c "[deploy] " "Deploying frontend application..."
    
    # Get API Gateway endpoint from other components
    local api_endpoint=""
    if [ -n "$API_URL" ]; then
        api_endpoint="$API_URL"
    else
        # Try to discover API Gateway endpoint
        local api_name="${PROJECT_NAME}-api"
        local api_id=$(aws apigateway get-rest-apis --query "items[?name=='${api_name}'].id" --output text 2>/dev/null)
        if [ -n "$api_id" ] && [ "$api_id" != "None" ]; then
            api_endpoint="https://${api_id}.execute-api.${AWS_REGION}.amazonaws.com/prod/data"
            print_log -g "[found] " "Discovered API endpoint: $api_endpoint"
        else
            print_log -y "[warn] " "API Gateway not found, using placeholder"
            api_endpoint="API_GATEWAY_ENDPOINT_PLACEHOLDER"
        fi
    fi
    
    # Check if Application directory exists
    local app_dir="$(dirname "$(dirname "$0")")/Application"
    if [ ! -d "$app_dir" ]; then
        print_log -r "[error] " "Application directory not found: $app_dir"
        return 1
    fi
    
    # Create temporary directory for deployment
    local temp_dir="/tmp/siam-frontend-$$"
    mkdir -p "$temp_dir"
    
    # Copy frontend files
    cp "$app_dir"/* "$temp_dir/" 2>/dev/null || {
        print_log -r "[error] " "Failed to copy frontend files from $app_dir"
        return 1
    }
    
    # Inject API endpoint into app.js
    if [ -f "$temp_dir/app.js" ]; then
        sed -i "s|API_GATEWAY_ENDPOINT_PLACEHOLDER|$api_endpoint|g" "$temp_dir/app.js"
        print_log -g "[config] " "API endpoint injected: $api_endpoint"
    fi
    
    # Upload to S3
    print_log -c "[upload] " "Uploading frontend files to S3..."
    if aws s3 sync "$temp_dir/" "s3://${FRONTEND_BUCKET_NAME}/" --delete; then
        print_log -g "[ok] " "Frontend deployed successfully"
    else
        print_log -r "[error] " "Failed to upload frontend files"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
}

setup_s3() {
    print_log -b "[storage] " "Setting up S3 Storage..."
    validate_inputs
    setup_aws_environment

    # Generate a valid random suffix for bucket names (lowercase, no special chars)
    RANDOM_SUFFIX=$(date +%s | sha256sum | head -c 8)
    
    # --- Creating Storage Layers ---
    print_log -b "[storage] " "Creating Storage Layers..."
    
    # Look for resource file in the setup directory (parent of components)
    SETUP_DIR="$(dirname "$(dirname "$0")")"
    RESOURCE_FILE="${SETUP_DIR}/${PROJECT_NAME}_resources.txt"
    touch "$RESOURCE_FILE"
    
    BUCKET_NAME=$(grep "S3_DATA_BUCKET" "$RESOURCE_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -z "$BUCKET_NAME" ] || ! aws s3api head-bucket --bucket $BUCKET_NAME > /dev/null 2>&1; then
        print_log -c "[create] " "Creating S3 Data Bucket..."
        # Create a valid S3 bucket name (lowercase, no underscores, 3-63 chars)
        PROJECT_CLEAN=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        BUCKET_NAME="${PROJECT_CLEAN}-iot-data-${RANDOM_SUFFIX}"
        
        # Validate bucket name length
        if [ ${#BUCKET_NAME} -gt 63 ]; then
            BUCKET_NAME="iot-data-${RANDOM_SUFFIX}"
        fi
        
        print_log -c "[info] " "Creating bucket: ${BUCKET_NAME}"
        
        if [ "$AWS_REGION" = "us-east-1" ]; then
            if ! aws s3api create-bucket --bucket $BUCKET_NAME --region $AWS_REGION; then
                print_log -r "[error] " "Failed to create S3 data bucket: ${BUCKET_NAME}"
                return 1
            fi
        else
            if ! aws s3api create-bucket --bucket $BUCKET_NAME --region $AWS_REGION --create-bucket-configuration LocationConstraint=$AWS_REGION; then
                print_log -r "[error] " "Failed to create S3 data bucket: ${BUCKET_NAME}"
                return 1
            fi
        fi
        
        print_log -y "[wait] " "Waiting for data bucket to be available..."
        aws s3api wait bucket-exists --bucket $BUCKET_NAME
        print_log -g "[ready] " "Data bucket is available."
        
        if ! aws s3api put-bucket-versioning --bucket $BUCKET_NAME --versioning-configuration Status=Enabled; then
            print_log -r "[error] " "Failed to enable versioning on S3 data bucket: ${BUCKET_NAME}"
            return 1
        fi
        
        # Add lifecycle policy for cost optimization
        print_log -c "[lifecycle] " "Adding lifecycle policy for cost optimization..."
        cat > /tmp/s3-lifecycle.json << 'LIFECYCLE_EOF'
{
  "Rules": [
    {
      "Id": "DeleteOldVersions",
      "Status": "Enabled",
      "NoncurrentVersionExpiration": {
        "NoncurrentDays": 30
      }
    },
    {
      "Id": "TransitionOldData",
      "Status": "Enabled",
      "Transitions": [
        {
          "Days": 90,
          "StorageClass": "GLACIER_IR"
        }
      ]
    }
  ]
}
LIFECYCLE_EOF
        aws s3api put-bucket-lifecycle-configuration --bucket $BUCKET_NAME --lifecycle-configuration file:///tmp/s3-lifecycle.json
        rm -f /tmp/s3-lifecycle.json
        print_log -g "[ok] " "S3 Data Bucket created with lifecycle policy: ${BUCKET_NAME}"
    else
        print_log -y "[skip] " "S3 Data Bucket '${BUCKET_NAME}' already exists."
    fi

    # --- Setup Frontend Hosting ---
    print_log -b "[hosting] " "Setting up S3 bucket for Frontend Hosting..."
    FRONTEND_BUCKET_NAME=$(grep "S3_FRONTEND_BUCKET" "$RESOURCE_FILE" 2>/dev/null | cut -d'=' -f2)
    if [ -z "$FRONTEND_BUCKET_NAME" ] || ! aws s3api head-bucket --bucket $FRONTEND_BUCKET_NAME > /dev/null 2>&1; then
        print_log -c "[create] " "Creating S3 Frontend Hosting Bucket..."
        # Create a valid S3 bucket name for frontend
        PROJECT_CLEAN=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        FRONTEND_BUCKET_NAME="${PROJECT_CLEAN}-frontend-${RANDOM_SUFFIX}"
        
        # Validate bucket name length
        if [ ${#FRONTEND_BUCKET_NAME} -gt 63 ]; then
            FRONTEND_BUCKET_NAME="frontend-${RANDOM_SUFFIX}"
        fi
        
        print_log -c "[info] " "Creating frontend bucket: ${FRONTEND_BUCKET_NAME}"
        
        if [ "$AWS_REGION" = "us-east-1" ]; then
            if ! aws s3api create-bucket --bucket $FRONTEND_BUCKET_NAME --region $AWS_REGION; then
                print_log -r "[error] " "Failed to create S3 frontend bucket: ${FRONTEND_BUCKET_NAME}"
                return 1
            fi
        else
            if ! aws s3api create-bucket --bucket $FRONTEND_BUCKET_NAME --region $AWS_REGION --create-bucket-configuration LocationConstraint=$AWS_REGION; then
                print_log -r "[error] " "Failed to create S3 frontend bucket: ${FRONTEND_BUCKET_NAME}"
                return 1
            fi
        fi
        
        print_log -y "[wait] " "Waiting for bucket to be available..."
        aws s3api wait bucket-exists --bucket $FRONTEND_BUCKET_NAME
        print_log -g "[ready] " "Frontend bucket is available."
        
        print_log -c "[config] " "Configuring frontend bucket for static website hosting..."
        if ! aws s3api put-public-access-block --bucket $FRONTEND_BUCKET_NAME --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"; then
            print_log -r "[error] " "Failed to configure public access block for frontend bucket"
            return 1
        fi
        
        cat > s3-website-policy.json << EOL
{ "Version": "2012-10-17", "Statement": [{ "Sid": "PublicReadGetObject", "Effect": "Allow", "Principal": "*", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::${FRONTEND_BUCKET_NAME}/*" }] }
EOL
        if ! aws s3api put-bucket-policy --bucket $FRONTEND_BUCKET_NAME --policy file://s3-website-policy.json; then
            print_log -r "[error] " "Failed to set bucket policy for frontend bucket"
            return 1
        fi
        
        if ! aws s3 website "s3://${FRONTEND_BUCKET_NAME}" --index-document index.html --error-document error.html; then
            print_log -r "[error] " "Failed to configure website hosting for frontend bucket"
            return 1
        fi
        
        print_log -g "[ok] " "S3 Frontend Bucket created: ${FRONTEND_BUCKET_NAME}"
    else
        print_log -y "[skip] " "S3 Frontend Bucket '${FRONTEND_BUCKET_NAME}' already exists."
    fi
    WEBSITE_URL="http://${FRONTEND_BUCKET_NAME}.s3-website-${AWS_REGION}.amazonaws.com"

    # Export variables for other components before deploying frontend
    export S3_DATA_BUCKET="$BUCKET_NAME"
    export S3_FRONTEND_BUCKET="$FRONTEND_BUCKET_NAME"
    export WEBSITE_URL

    # Deploy frontend application
    deploy_frontend
    
    print_log -g "[ok] " "S3 Storage setup complete!"
    print_log -m "[S3 Data Bucket] " "${BUCKET_NAME}"
    print_log -m "[S3 Frontend URL] " "${WEBSITE_URL}"

    # Save resource names to a file for cleanup and other components
    # Write to the setup directory (parent of components)
    SETUP_DIR="$(dirname "$(dirname "$0")")"
    RESOURCE_FILE="${SETUP_DIR}/${PROJECT_NAME}_resources.txt"
    
    print_log -c "[save] " "Writing resource file to: ${RESOURCE_FILE}"
    
    # Ensure directory exists
    mkdir -p "$(dirname "$RESOURCE_FILE")"
    
    # Create or update resource file
    if [ -f "$RESOURCE_FILE" ]; then
        grep -v "^S3_" "$RESOURCE_FILE" > "${RESOURCE_FILE}.tmp" 2>/dev/null || touch "${RESOURCE_FILE}.tmp"
        mv "${RESOURCE_FILE}.tmp" "$RESOURCE_FILE"
    else
        touch "$RESOURCE_FILE"
    fi
    
    echo "S3_DATA_BUCKET=${BUCKET_NAME}" >> "$RESOURCE_FILE"
    echo "S3_FRONTEND_BUCKET=${FRONTEND_BUCKET_NAME}" >> "$RESOURCE_FILE"
    
    # Verify file was written
    if [ -f "$RESOURCE_FILE" ] && grep -q "S3_DATA_BUCKET" "$RESOURCE_FILE"; then
        print_log -g "[ok] " "Resource file written successfully: ${RESOURCE_FILE}"
        print_log -y "[content] " "$(cat "$RESOURCE_FILE")"
    else
        print_log -r "[error] " "Failed to write resource file"
        return 1
    fi
    
    cleanup_temp_files
}

cleanup_s3() {
    print_log -b "[delete] " "Cleaning up S3 Storage..."
    validate_inputs
    setup_aws_environment

    print_log -b "[delete] " "Deleting S3 Buckets..."
    # Look for resource file in the setup directory (parent of components)
    SETUP_DIR="$(dirname "$(dirname "$0")")"
    RESOURCE_FILE="${SETUP_DIR}/${PROJECT_NAME}_resources.txt"
    
    # Initialize bucket variables
    S3_DATA_BUCKET=""
    S3_FRONTEND_BUCKET=""
    
    # Try to get bucket names from resource file first
    if [ -f "$RESOURCE_FILE" ]; then
        source "$RESOURCE_FILE"
        print_log -y "[info] " "Found resource file, using stored bucket names."
    else
        print_log -y "[warn] " "Resource file not found, discovering buckets..."
    fi
    
    # If we don't have bucket names from file, discover them
    if [ -z "$S3_DATA_BUCKET" ]; then
        PROJECT_CLEAN=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        print_log -y "[discover] " "Discovering S3 data bucket for project: ${PROJECT_CLEAN}"
        S3_DATA_BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name, '${PROJECT_CLEAN}') && contains(Name, 'iot-data')].Name" --output text | head -1)
        if [ -z "$S3_DATA_BUCKET" ] || [ "$S3_DATA_BUCKET" == "None" ]; then
            # Try alternative pattern
            S3_DATA_BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name, 'iot-data')].Name" --output text | grep "${PROJECT_CLEAN}" | head -1 || echo "")
        fi
        if [ ! -z "$S3_DATA_BUCKET" ] && [ "$S3_DATA_BUCKET" != "None" ]; then
            print_log -g "[found] " "Discovered S3 data bucket: ${S3_DATA_BUCKET}"
        fi
    fi
    
    if [ -z "$S3_FRONTEND_BUCKET" ]; then
        PROJECT_CLEAN=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        print_log -y "[discover] " "Discovering S3 frontend bucket for project: ${PROJECT_CLEAN}"
        S3_FRONTEND_BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name, '${PROJECT_CLEAN}') && contains(Name, 'frontend')].Name" --output text | head -1)
        if [ -z "$S3_FRONTEND_BUCKET" ] || [ "$S3_FRONTEND_BUCKET" == "None" ]; then
            # Try alternative pattern
            S3_FRONTEND_BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name, 'frontend')].Name" --output text | grep "${PROJECT_CLEAN}" | head -1 || echo "")
        fi
        if [ ! -z "$S3_FRONTEND_BUCKET" ] && [ "$S3_FRONTEND_BUCKET" != "None" ]; then
            print_log -g "[found] " "Discovered S3 frontend bucket: ${S3_FRONTEND_BUCKET}"
        fi
    fi
    
    # Proceed with cleanup if we have bucket names
    if [ ! -z "$S3_DATA_BUCKET" ] || [ ! -z "$S3_FRONTEND_BUCKET" ]; then
        if [ ! -z "$S3_DATA_BUCKET" ]; then
            print_log -c "[delete] " "Emptying S3 Data Bucket (including all versions)..."
            
            # Check if bucket exists first
            if aws s3api head-bucket --bucket "$S3_DATA_BUCKET" > /dev/null 2>&1; then
                print_log -y "[wait] " "Deleting all object versions and delete markers..."
                
                # Delete all object versions
                local version_loop_count=0
                local max_version_loops=20
                while [ $version_loop_count -lt $max_version_loops ]; do
                    VERSIONS=$(aws s3api list-object-versions --bucket "$S3_DATA_BUCKET" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --max-items 1000 2>/dev/null)
                    if [ "$VERSIONS" == '{"Objects": null}' ] || [ "$VERSIONS" == '{"Objects": []}' ] || [ -z "$VERSIONS" ]; then
                        print_log -g "[ok] " "All object versions deleted."
                        break
                    fi
                    
                    # Check if we actually have objects to delete
                    local object_count=$(echo "$VERSIONS" | jq -r '.Objects | length' 2>/dev/null || echo "0")
                    if [ "$object_count" == "0" ] || [ "$object_count" == "null" ]; then
                        print_log -g "[ok] " "No more object versions to delete."
                        break
                    fi
                    
                    if ! aws s3api delete-objects --bucket "$S3_DATA_BUCKET" --delete "$VERSIONS" > /dev/null 2>&1; then
                        print_log -y "[retry] " "Retrying deletion of object versions... (loop $version_loop_count/$max_version_loops)"
                        sleep 2
                        version_loop_count=$((version_loop_count + 1))
                        continue
                    fi
                    print_log -y "[progress] " "Deleted batch of $object_count object versions..."
                    version_loop_count=$((version_loop_count + 1))
                done
                
                if [ $version_loop_count -eq $max_version_loops ]; then
                    print_log -r "[error] " "Reached maximum attempts for object version deletion"
                fi
                
                # Delete all delete markers
                local marker_loop_count=0
                local max_marker_loops=20
                while [ $marker_loop_count -lt $max_marker_loops ]; do
                    DELETE_MARKERS=$(aws s3api list-object-versions --bucket "$S3_DATA_BUCKET" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --max-items 1000 2>/dev/null)
                    if [ "$DELETE_MARKERS" == '{"Objects": null}' ] || [ "$DELETE_MARKERS" == '{"Objects": []}' ] || [ -z "$DELETE_MARKERS" ]; then
                        print_log -g "[ok] " "All delete markers deleted."
                        break
                    fi
                    
                    # Check if we actually have markers to delete
                    local marker_count=$(echo "$DELETE_MARKERS" | jq -r '.Objects | length' 2>/dev/null || echo "0")
                    if [ "$marker_count" == "0" ] || [ "$marker_count" == "null" ]; then
                        print_log -g "[ok] " "No more delete markers to delete."
                        break
                    fi
                    
                    if ! aws s3api delete-objects --bucket "$S3_DATA_BUCKET" --delete "$DELETE_MARKERS" > /dev/null 2>&1; then
                        print_log -y "[retry] " "Retrying deletion of delete markers... (loop $marker_loop_count/$max_marker_loops)"
                        sleep 2
                        marker_loop_count=$((marker_loop_count + 1))
                        continue
                    fi
                    print_log -y "[progress] " "Deleted batch of $marker_count delete markers..."
                    marker_loop_count=$((marker_loop_count + 1))
                done
                
                if [ $marker_loop_count -eq $max_marker_loops ]; then
                    print_log -r "[error] " "Reached maximum attempts for delete marker deletion"
                fi
                
                # Final cleanup of any remaining objects
                aws s3 rm s3://${S3_DATA_BUCKET} --recursive > /dev/null 2>&1 || true
                
                print_log -y "[wait] " "Waiting for bucket to be empty..."
                sleep 5
                
                # Now delete the bucket
                RETRY_COUNT=0
                MAX_RETRIES=5
                while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                    if aws s3api delete-bucket --bucket ${S3_DATA_BUCKET} 2>/dev/null; then
                        print_log -g "[ok] " "S3 Data Bucket ($S3_DATA_BUCKET) deleted."
                        break
                    else
                        RETRY_COUNT=$((RETRY_COUNT + 1))
                        print_log -y "[retry] " "Bucket deletion failed, retrying... (attempt $RETRY_COUNT/$MAX_RETRIES)"
                        sleep 10
                    fi
                done
                
                if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
                    print_log -r "[error] " "Failed to delete S3 Data Bucket after $MAX_RETRIES attempts"
                fi
            else
                print_log -y "[skip] " "S3 Data Bucket ($S3_DATA_BUCKET) does not exist."
            fi
        fi
        if [ ! -z "$S3_FRONTEND_BUCKET" ]; then
            print_log -c "[delete] " "Emptying S3 Frontend Bucket..."
            
            # Check if bucket exists first
            if aws s3api head-bucket --bucket "$S3_FRONTEND_BUCKET" > /dev/null 2>&1; then
                print_log -y "[wait] " "Deleting all objects from frontend bucket..."
                
                # Delete all object versions (in case versioning was enabled)
                local version_loop_count=0
                local max_version_loops=20
                while [ $version_loop_count -lt $max_version_loops ]; do
                    VERSIONS=$(aws s3api list-object-versions --bucket "$S3_FRONTEND_BUCKET" --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --max-items 1000 2>/dev/null)
                    if [ "$VERSIONS" == '{"Objects": null}' ] || [ "$VERSIONS" == '{"Objects": []}' ] || [ -z "$VERSIONS" ]; then
                        print_log -g "[ok] " "All frontend object versions deleted."
                        break
                    fi
                    
                    # Check if we actually have objects to delete
                    local object_count=$(echo "$VERSIONS" | jq -r '.Objects | length' 2>/dev/null || echo "0")
                    if [ "$object_count" == "0" ] || [ "$object_count" == "null" ]; then
                        print_log -g "[ok] " "No more frontend object versions to delete."
                        break
                    fi
                    
                    aws s3api delete-objects --bucket "$S3_FRONTEND_BUCKET" --delete "$VERSIONS" > /dev/null 2>&1 || true
                    print_log -y "[progress] " "Deleted batch of $object_count frontend objects..."
                    version_loop_count=$((version_loop_count + 1))
                done
                
                # Delete all delete markers
                local marker_loop_count=0
                local max_marker_loops=20
                while [ $marker_loop_count -lt $max_marker_loops ]; do
                    DELETE_MARKERS=$(aws s3api list-object-versions --bucket "$S3_FRONTEND_BUCKET" --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --max-items 1000 2>/dev/null)
                    if [ "$DELETE_MARKERS" == '{"Objects": null}' ] || [ "$DELETE_MARKERS" == '{"Objects": []}' ] || [ -z "$DELETE_MARKERS" ]; then
                        print_log -g "[ok] " "All frontend delete markers deleted."
                        break
                    fi
                    
                    # Check if we actually have markers to delete
                    local marker_count=$(echo "$DELETE_MARKERS" | jq -r '.Objects | length' 2>/dev/null || echo "0")
                    if [ "$marker_count" == "0" ] || [ "$marker_count" == "null" ]; then
                        print_log -g "[ok] " "No more frontend delete markers to delete."
                        break
                    fi
                    
                    aws s3api delete-objects --bucket "$S3_FRONTEND_BUCKET" --delete "$DELETE_MARKERS" > /dev/null 2>&1 || true
                    print_log -y "[progress] " "Deleted batch of $marker_count delete markers..."
                    marker_loop_count=$((marker_loop_count + 1))
                done
                
                # Remove any remaining objects
                aws s3 rm s3://${S3_FRONTEND_BUCKET} --recursive > /dev/null 2>&1 || true
                
                print_log -y "[wait] " "Waiting for frontend bucket to be empty..."
                sleep 5
                
                # Now delete the bucket
                RETRY_COUNT=0
                MAX_RETRIES=5
                while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                    if aws s3api delete-bucket --bucket ${S3_FRONTEND_BUCKET} 2>/dev/null; then
                        print_log -g "[ok] " "S3 Frontend Bucket ($S3_FRONTEND_BUCKET) deleted."
                        break
                    else
                        RETRY_COUNT=$((RETRY_COUNT + 1))
                        print_log -y "[retry] " "Frontend bucket deletion failed, retrying... (attempt $RETRY_COUNT/$MAX_RETRIES)"
                        sleep 10
                    fi
                done
                
                if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
                    print_log -r "[error] " "Failed to delete S3 Frontend Bucket after $MAX_RETRIES attempts"
                fi
            else
                print_log -y "[skip] " "S3 Frontend Bucket ($S3_FRONTEND_BUCKET) does not exist."
            fi
        fi
        
        # Clean up resource file if it exists
        if [ -f "$RESOURCE_FILE" ]; then
            # Remove S3 entries from resource file
            grep -v "S3_" "$RESOURCE_FILE" > temp_resources.txt && mv temp_resources.txt "$RESOURCE_FILE"
            # Remove file if empty
            if [ ! -s "$RESOURCE_FILE" ]; then
                rm "$RESOURCE_FILE"
            fi
        fi
    else
        print_log -y "[info] " "No S3 buckets found for project '${PROJECT_NAME}'."
    fi
}

# Main execution
case "${1:-}" in
    setup)
        if ! setup_s3; then
            print_log -r "[error] " "S3 setup failed"
            exit 1
        fi
        ;;
    cleanup)
        if ! cleanup_s3; then
            print_log -r "[error] " "S3 cleanup failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac