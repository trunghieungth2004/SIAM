#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| Lambda Functions Component         |--/ /-|#
#|-/ /--| Creates Lambda functions and IAM   |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"

setup_lambda() {
    print_log -b "[app] " "Setting up Lambda Functions..."
    validate_inputs
    setup_aws_environment

    # Get SQS queue ARN
    if [ -z "$SQS_QUEUE_ARN" ]; then
        SQS_QUEUE_NAME="dlq-${PROJECT_NAME}"
        if ! SQS_QUEUE_URL=$(aws sqs get-queue-url --queue-name $SQS_QUEUE_NAME --query QueueUrl --output text 2>/dev/null); then
            print_log -r "[error] " "Failed to get SQS queue URL for ${SQS_QUEUE_NAME}"
            return 1
        fi
        if ! SQS_QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url $SQS_QUEUE_URL --attribute-names QueueArn --query "Attributes.QueueArn" --output text); then
            print_log -r "[error] " "Failed to get SQS queue ARN"
            return 1
        fi
    fi

    if [ -z "$DDB_TABLE_NAME" ]; then
        DDB_TABLE_NAME="${PROJECT_NAME}-sensor-readings"
        # Verify table exists
        if ! aws dynamodb describe-table --table-name $DDB_TABLE_NAME > /dev/null 2>&1; then
            print_log -r "[error] " "DynamoDB table ${DDB_TABLE_NAME} not found. Please ensure DynamoDB setup completed successfully."
            return 1
        fi
    fi

    if [ -z "$S3_DATA_BUCKET" ]; then
        # Look for resource file in the setup directory (parent of components)
        SETUP_DIR="$(dirname "$(dirname "$0")")"
        RESOURCE_FILE="${SETUP_DIR}/${PROJECT_NAME}_resources.txt"
        
        if [ -f "$RESOURCE_FILE" ]; then
            S3_DATA_BUCKET=$(grep "S3_DATA_BUCKET" "$RESOURCE_FILE" | cut -d'=' -f2)
        fi
        
        # If not found in resource file or file doesn't exist, try to discover bucket
        if [ -z "$S3_DATA_BUCKET" ]; then
            print_log -y "[discover] " "Resource file not found or S3_DATA_BUCKET missing. Trying to discover S3 bucket..."
            print_log -y "[debug] " "Looking for resource file at: ${RESOURCE_FILE}"
            # Look for buckets with the project name pattern
            PROJECT_CLEAN=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
            S3_DATA_BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name, '${PROJECT_CLEAN}') && contains(Name, 'iot-data')].Name" --output text | head -1)
            
            if [ -z "$S3_DATA_BUCKET" ] || [ "$S3_DATA_BUCKET" = "None" ]; then
                print_log -r "[error] " "S3 data bucket not found. Please ensure S3 setup completed successfully."
                print_log -y "[hint] " "Expected bucket pattern: ${PROJECT_CLEAN}-iot-data-*"
                return 1
            else
                print_log -g "[found] " "Discovered S3 data bucket: ${S3_DATA_BUCKET}"
            fi
        fi
    fi

    if [ -z "$SNS_TOPIC_ARN" ]; then
        SNS_TOPIC_NAME="${PROJECT_NAME}-high-temp-alerts"
        if ! SNS_TOPIC_ARN=$(aws sns list-topics --query "Topics[?ends_with(TopicArn, ':${SNS_TOPIC_NAME}')].TopicArn" --output text); then
            print_log -r "[error] " "Failed to get SNS topic ARN"
            return 1
        fi
        if [ -z "$SNS_TOPIC_ARN" ] || [ "$SNS_TOPIC_ARN" = "None" ]; then
            print_log -r "[error] " "SNS topic ${SNS_TOPIC_NAME} not found. Please ensure SNS setup completed successfully."
            return 1
        fi
    fi

    # Create IAM Role for Lambda
    LAMBDA_ROLE_NAME="role-lambda-${PROJECT_NAME}"
    if ! LAMBDA_ROLE_ARN=$(aws iam get-role --role-name $LAMBDA_ROLE_NAME --query Role.Arn --output text 2>/dev/null); then
        print_log -c "[iam] " "Creating IAM Role for Lambda: ${LAMBDA_ROLE_NAME}..."
        cat > lambda-trust-policy.json << EOL
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Principal": { "Service": "lambda.amazonaws.com" }, "Action": "sts:AssumeRole" }] }
EOL
        if ! LAMBDA_ROLE_ARN=$(aws iam create-role --role-name $LAMBDA_ROLE_NAME --assume-role-policy-document file://lambda-trust-policy.json --query Role.Arn --output text); then
            print_log -r "[error] " "Failed to create IAM role: ${LAMBDA_ROLE_NAME}"
            return 1
        fi
        
        if ! aws iam attach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole; then
            print_log -r "[error] " "Failed to attach basic execution policy to Lambda role"
            return 1
        fi

        cat > lambda-permissions-policy.json << EOL
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": ["dynamodb:PutItem", "s3:PutObject", "sns:Publish", "sqs:SendMessage"], "Resource": "*" }] }
EOL
        if ! aws iam put-role-policy --role-name $LAMBDA_ROLE_NAME --policy-name "LambdaCustomPermissions" --policy-document file://lambda-permissions-policy.json; then
            print_log -r "[error] " "Failed to attach custom permissions policy to Lambda role"
            return 1
        fi
        
        print_log -y "[wait] " "IAM Role policies attached. Waiting for propagation..."
        sleep 15
        
        # Verify role is ready
        local retry_count=0
        while [ $retry_count -lt 5 ]; do
            if aws iam get-role --role-name $LAMBDA_ROLE_NAME > /dev/null 2>&1; then
                print_log -g "[ready] " "IAM role is ready for use."
                break
            fi
            retry_count=$((retry_count + 1))
            print_log -y "[waiting] " "Still waiting for IAM role propagation... (attempt $retry_count/5)"
            sleep 10
        done
    else
        print_log -y "[skip] " "IAM Role '${LAMBDA_ROLE_NAME}' already exists."
    fi

    # IAM Role for Query Lambda
    QUERY_ROLE_NAME="role-lambda-query-${PROJECT_NAME}"
    if ! QUERY_ROLE_ARN=$(aws iam get-role --role-name $QUERY_ROLE_NAME --query Role.Arn --output text 2>/dev/null); then
        print_log -c "[iam] " "Creating IAM Role for Query Lambda..."
        if ! QUERY_ROLE_ARN=$(aws iam create-role --role-name $QUERY_ROLE_NAME --assume-role-policy-document file://lambda-trust-policy.json --query Role.Arn --output text); then
            print_log -r "[error] " "Failed to create Query Lambda IAM role"
            return 1
        fi
        
        if ! aws iam attach-role-policy --role-name $QUERY_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole; then
            print_log -r "[error] " "Failed to attach basic execution policy to Query Lambda role"
            return 1
        fi
        
        cat > query-permissions.json << EOL
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": ["dynamodb:Query", "dynamodb:Scan"], "Resource": "*" }] }
EOL
        if ! aws iam put-role-policy --role-name $QUERY_ROLE_NAME --policy-name "QueryLambdaPermissions" --policy-document file://query-permissions.json; then
            print_log -r "[error] " "Failed to attach custom permissions policy to Query Lambda role"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for Query IAM role to propagate..."
        sleep 15
        
        # Verify role is ready
        local retry_count=0
        while [ $retry_count -lt 5 ]; do
            if aws iam get-role --role-name $QUERY_ROLE_NAME > /dev/null 2>&1; then
                print_log -g "[ready] " "Query IAM role is ready for use."
                break
            fi
            retry_count=$((retry_count + 1))
            print_log -y "[waiting] " "Still waiting for Query IAM role propagation... (attempt $retry_count/5)"
            sleep 10
        done
    else
        print_log -y "[skip] " "IAM Role '${QUERY_ROLE_NAME}' already exists."
    fi

    # IAM Role for Deploy Lambda
    DEPLOY_ROLE_NAME="role-lambda-deploy-${PROJECT_NAME}"
    if ! DEPLOY_ROLE_ARN=$(aws iam get-role --role-name $DEPLOY_ROLE_NAME --query Role.Arn --output text 2>/dev/null); then
        print_log -c "[iam] " "Creating IAM Role for Deploy Lambda..."
        if ! DEPLOY_ROLE_ARN=$(aws iam create-role --role-name $DEPLOY_ROLE_NAME --assume-role-policy-document file://lambda-trust-policy.json --query Role.Arn --output text); then
            print_log -r "[error] " "Failed to create Deploy Lambda IAM role"
            return 1
        fi
        
        if ! aws iam attach-role-policy --role-name $DEPLOY_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole; then
            print_log -r "[error] " "Failed to attach basic execution policy to Deploy Lambda role"
            return 1
        fi
        
        cat > deploy-permissions.json << EOL
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": ["sagemaker:DescribeTrainingJob", "greengrassv2:CreateComponentVersion", "greengrassv2:CreateDeployment", "greengrassv2:GetCoreDevice", "iot:DescribeThing", "s3:GetObject", "s3:PutObject", "ec2:RunInstances", "ec2:DescribeInstances", "ec2:DescribeImages", "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeInternetGateways", "ec2:DescribeRouteTables", "ec2:CreateVpc", "ec2:CreateSubnet", "ec2:CreateInternetGateway", "ec2:CreateRouteTable", "ec2:CreateRoute", "ec2:CreateSecurityGroup", "ec2:CreateTags", "ec2:AttachInternetGateway", "ec2:DetachInternetGateway", "ec2:AssociateRouteTable", "ec2:ModifyVpcAttribute", "ec2:ModifySubnetAttribute", "ec2:AuthorizeSecurityGroupEgress", "ec2:DeleteVpc", "ec2:DeleteSubnet", "ec2:DeleteInternetGateway", "ec2:DeleteRouteTable", "ec2:DeleteSecurityGroup", "ec2:TerminateInstances", "iam:PassRole"], "Resource": "*" }] }
EOL
        if ! aws iam put-role-policy --role-name $DEPLOY_ROLE_NAME --policy-name "DeployLambdaPermissions" --policy-document file://deploy-permissions.json; then
            print_log -r "[error] " "Failed to attach custom permissions policy to Deploy Lambda role"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for Deploy IAM role to propagate..."
        sleep 15
    else
        print_log -y "[skip] " "IAM Role '${DEPLOY_ROLE_NAME}' already exists."
    fi

    # Create Lambda Function
    LAMBDA_FUNCTION_NAME="func-ingestion-${PROJECT_NAME}"
    if ! aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME > /dev/null 2>&1; then
        print_log -c "[lambda] " "Creating Lambda function: ${LAMBDA_FUNCTION_NAME}..."
        
        # Copy the updated ingestion Lambda code
        if [ -f "components/Lambda/ingestion.js" ]; then
            if ! cp components/Lambda/ingestion.js index.mjs; then
                print_log -r "[error] " "Failed to copy ingestion.js"
                return 1
            fi
            print_log -c "[lambda] " "Using updated ingestion code with full sensor data support"
        else
            print_log -r "[error] " "ingestion.js not found in components/Lambda/"
            return 1
        fi
        
        if ! zip deployment.zip index.mjs; then
            print_log -r "[error] " "Failed to create deployment package"
            return 1
        fi

        if ! LAMBDA_FUNCTION_ARN=$(aws lambda create-function \
            --function-name $LAMBDA_FUNCTION_NAME \
            --runtime nodejs20.x \
            --role $LAMBDA_ROLE_ARN \
            --handler index.handler \
            --zip-file fileb://deployment.zip \
            --dead-letter-config TargetArn=$SQS_QUEUE_ARN \
            --environment "Variables={DYNAMODB_TABLE_NAME=$DDB_TABLE_NAME,S3_BUCKET_NAME=$S3_DATA_BUCKET,SNS_TOPIC_ARN=$SNS_TOPIC_ARN}" \
            --query FunctionArn --output text); then
            print_log -r "[error] " "Failed to create Lambda function: ${LAMBDA_FUNCTION_NAME}"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for Lambda function to be ready..."
        if ! aws lambda wait function-active --function-name $LAMBDA_FUNCTION_NAME; then
            print_log -r "[error] " "Timeout waiting for Lambda function to become active"
            return 1
        fi
        print_log -g "[ready] " "Lambda function is active."
        
        # Set CloudWatch log retention to 7 days for cost optimization
        print_log -c "[logs] " "Setting CloudWatch log retention to 7 days..."
        aws logs put-retention-policy --log-group-name "/aws/lambda/${LAMBDA_FUNCTION_NAME}" --retention-in-days 7 2>/dev/null || true
    else
        print_log -y "[skip] " "Lambda function '${LAMBDA_FUNCTION_NAME}' already exists."
        if ! LAMBDA_FUNCTION_ARN=$(aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --query Configuration.FunctionArn --output text); then
            print_log -r "[error] " "Failed to get existing Lambda function ARN"
            return 1
        fi
    fi

    # Add permission for IoT to invoke Lambda
    print_log -c "[iot] " "Adding IoT permission to invoke Lambda..."
    aws lambda add-permission \
        --function-name $LAMBDA_FUNCTION_NAME \
        --statement-id iot-invoke-lambda \
        --action lambda:InvokeFunction \
        --principal iot.amazonaws.com 2>/dev/null || print_log -y "[skip] " "IoT permission already exists"
    
    # Create IoT rule for ml/predictions topic
    print_log -c "[iot] " "Creating IoT rule for ML predictions..."
    ML_RULE_NAME="${PROJECT_NAME}_ml_predictions_rule"
    aws iot create-topic-rule --rule-name "$ML_RULE_NAME" --topic-rule-payload "{\"sql\":\"SELECT * FROM 'ml/predictions'\",\"actions\":[{\"lambda\":{\"functionArn\":\"$LAMBDA_FUNCTION_ARN\"}}],\"ruleDisabled\":false}" 2>/dev/null || print_log -y "[skip] " "ML predictions rule already exists"
    
    aws lambda add-permission \
        --function-name $LAMBDA_FUNCTION_NAME \
        --statement-id iot-ml-predictions \
        --action lambda:InvokeFunction \
        --principal iot.amazonaws.com \
        --source-arn "arn:aws:iot:$AWS_REGION:$ACCOUNT_ID:rule/$ML_RULE_NAME" 2>/dev/null || print_log -y "[skip] " "ML predictions permission already exists"

    # Query Handler Lambda Function
    QUERY_LAMBDA_NAME="${PROJECT_NAME}-query-lambda"
    if ! aws lambda get-function --function-name $QUERY_LAMBDA_NAME > /dev/null 2>&1; then
        print_log -c "[lambda] " "Creating Query Handler Lambda function..."
        
        if [ -f "components/Lambda/query.mjs" ]; then
            cp components/Lambda/query.mjs query.mjs
        else
            print_log -r "[error] " "query.mjs not found in components/Lambda/"
            return 1
        fi
        
        if ! zip query_deployment.zip query.mjs; then
            print_log -r "[error] " "Failed to create query deployment package"
            return 1
        fi

        if ! QUERY_LAMBDA_ARN=$(aws lambda create-function \
            --function-name $QUERY_LAMBDA_NAME \
            --runtime nodejs20.x \
            --role $QUERY_ROLE_ARN \
            --handler query.handler \
            --zip-file fileb://query_deployment.zip \
            --environment "Variables={DYNAMODB_TABLE_NAME=$DDB_TABLE_NAME}" \
            --query FunctionArn --output text); then
            print_log -r "[error] " "Failed to create Query Lambda function: ${QUERY_LAMBDA_NAME}"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for Query Lambda function to be ready..."
        if ! aws lambda wait function-active --function-name $QUERY_LAMBDA_NAME; then
            print_log -r "[error] " "Timeout waiting for Query Lambda function to become active"
            return 1
        fi
        print_log -g "[ready] " "Query Lambda function is active."
        
        # Set CloudWatch log retention to 7 days
        aws logs put-retention-policy --log-group-name "/aws/lambda/${QUERY_LAMBDA_NAME}" --retention-in-days 7 2>/dev/null || true
    else
        print_log -y "[skip] " "Query Lambda function '${QUERY_LAMBDA_NAME}' already exists."
        if ! QUERY_LAMBDA_ARN=$(aws lambda get-function --function-name $QUERY_LAMBDA_NAME --query Configuration.FunctionArn --output text); then
            print_log -r "[error] " "Failed to get existing Query Lambda function ARN"
            return 1
        fi
    fi

    # Deploy Lambda Function
    DEPLOY_LAMBDA_NAME="func-deploy-${PROJECT_NAME}"
    if ! aws lambda get-function --function-name $DEPLOY_LAMBDA_NAME > /dev/null 2>&1; then
        print_log -c "[lambda] " "Creating Deploy Lambda function..."
        
        if [ -f "components/Lambda/deploy.mjs" ]; then
            cp components/Lambda/deploy.mjs deploy.mjs
        else
            print_log -r "[error] " "deploy.mjs not found in components/Lambda/"
            return 1
        fi
        
        if ! zip deploy_deployment.zip deploy.mjs; then
            print_log -r "[error] " "Failed to create deploy deployment package"
            return 1
        fi

        if ! DEPLOY_LAMBDA_ARN=$(aws lambda create-function \
            --function-name $DEPLOY_LAMBDA_NAME \
            --runtime nodejs20.x \
            --role $DEPLOY_ROLE_ARN \
            --handler deploy.handler \
            --zip-file fileb://deploy_deployment.zip \
            --environment "Variables={PROJECT_NAME=$PROJECT_NAME,S3_DATA_BUCKET=$S3_DATA_BUCKET,ACCOUNT_ID=$ACCOUNT_ID}" \
            --timeout 300 \
            --query FunctionArn --output text); then
            print_log -r "[error] " "Failed to create Deploy Lambda function: ${DEPLOY_LAMBDA_NAME}"
            return 1
        fi
        
        print_log -y "[wait] " "Waiting for Deploy Lambda function to be ready..."
        if ! aws lambda wait function-active --function-name $DEPLOY_LAMBDA_NAME; then
            print_log -r "[error] " "Timeout waiting for Deploy Lambda function to become active"
            return 1
        fi
        print_log -g "[ready] " "Deploy Lambda function is active."
        
        # Set CloudWatch log retention to 7 days
        aws logs put-retention-policy --log-group-name "/aws/lambda/${DEPLOY_LAMBDA_NAME}" --retention-in-days 7 2>/dev/null || true
    else
        print_log -y "[skip] " "Deploy Lambda function '${DEPLOY_LAMBDA_NAME}' already exists."
        if ! DEPLOY_LAMBDA_ARN=$(aws lambda get-function --function-name $DEPLOY_LAMBDA_NAME --query Configuration.FunctionArn --output text); then
            print_log -r "[error] " "Failed to get existing Deploy Lambda function ARN"
            return 1
        fi
    fi





    print_log -g "[ok] " "Lambda setup complete!"
    print_log -m "[Lambda Function ARN] " "${LAMBDA_FUNCTION_ARN}"
    print_log -m "[Query Lambda ARN] " "${QUERY_LAMBDA_ARN}"
    print_log -m "[Deploy Lambda ARN] " "${DEPLOY_LAMBDA_ARN}"
    
    # Export variables for other components
    export LAMBDA_FUNCTION_ARN
    export LAMBDA_FUNCTION_NAME
    export LAMBDA_ROLE_NAME
    export QUERY_LAMBDA_ARN
    export QUERY_LAMBDA_NAME
    export QUERY_ROLE_NAME
    export DEPLOY_LAMBDA_ARN
    export DEPLOY_LAMBDA_NAME
    export DEPLOY_ROLE_NAME

    
    # Cleanup temporary files
    rm -f lambda-trust-policy.json lambda-permissions-policy.json query-permissions.json deploy-permissions.json index.mjs deployment.zip query.mjs query_deployment.zip deploy.mjs deploy_deployment.zip 2>/dev/null || true
}



cleanup_lambda() {
    print_log -b "[delete] " "Cleaning up Lambda Functions..."
    validate_inputs
    setup_aws_environment

    LAMBDA_FUNCTION_NAME="func-ingestion-${PROJECT_NAME}"
    LAMBDA_ROLE_NAME="role-lambda-${PROJECT_NAME}"
    QUERY_LAMBDA_NAME="${PROJECT_NAME}-query-lambda"
    QUERY_ROLE_NAME="role-lambda-query-${PROJECT_NAME}"
    DEPLOY_LAMBDA_NAME="func-deploy-${PROJECT_NAME}"
    DEPLOY_ROLE_NAME="role-lambda-deploy-${PROJECT_NAME}"

    
    # Delete Query Lambda Function
    print_log -b "[delete] " "Deleting Query Lambda Function..."
    aws lambda delete-function --function-name $QUERY_LAMBDA_NAME 2>/dev/null || true
    aws iam delete-role-policy --role-name $QUERY_ROLE_NAME --policy-name "QueryLambdaPermissions" 2>/dev/null || true
    aws iam detach-role-policy --role-name $QUERY_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
    aws iam delete-role --role-name $QUERY_ROLE_NAME 2>/dev/null || true
    print_log -g "[ok] " "Query Lambda function and IAM Role deleted."
    
    # Delete Deploy Lambda Function
    print_log -b "[delete] " "Deleting Deploy Lambda Function..."
    aws lambda delete-function --function-name $DEPLOY_LAMBDA_NAME 2>/dev/null || true
    aws iam delete-role-policy --role-name $DEPLOY_ROLE_NAME --policy-name "DeployLambdaPermissions" 2>/dev/null || true
    aws iam detach-role-policy --role-name $DEPLOY_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
    aws iam delete-role --role-name $DEPLOY_ROLE_NAME 2>/dev/null || true
    print_log -g "[ok] " "Deploy Lambda function and IAM Role deleted."
    
    # Delete Ingestion Lambda Function
    print_log -b "[delete] " "Deleting Ingestion Lambda Function..."
    aws lambda delete-function --function-name $LAMBDA_FUNCTION_NAME 2>/dev/null || true
    aws iam delete-role-policy --role-name $LAMBDA_ROLE_NAME --policy-name "LambdaCustomPermissions" 2>/dev/null || true
    aws iam detach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
    aws iam delete-role --role-name $LAMBDA_ROLE_NAME 2>/dev/null || true
    print_log -g "[ok] " "Ingestion Lambda function and IAM Role deleted."
    
    print_log -y "[info] " "EventBridge component handles retraining automation"
}

# Main execution
case "${1:-}" in
    setup)
        if ! setup_lambda; then
            print_log -r "[error] " "Lambda setup failed"
            exit 1
        fi
        ;;
    cleanup)
        if ! cleanup_lambda; then
            print_log -r "[error] " "Lambda cleanup failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac