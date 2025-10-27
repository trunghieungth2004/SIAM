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

    # Get dependencies from other components
    if [ -z "$VPC_ID" ]; then
        if ! VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Project,Values=${PROJECT_NAME}" --query "Vpcs[0].VpcId" --output text); then
            print_log -r "[error] " "Failed to get VPC ID"
            return 1
        fi
        
        if ! PRIVATE_SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=private-subnet-${PROJECT_NAME}" --query "Subnets[0].SubnetId" --output text); then
            print_log -r "[error] " "Failed to get private subnet ID"
            return 1
        fi
        
        SG_NAME="${PROJECT_NAME}-endpoints"
        if ! SG_ID=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=${SG_NAME}" --query "SecurityGroups[0].GroupId" --output text); then
            print_log -r "[error] " "Failed to get security group ID"
            return 1
        fi
        
        # Validate that we got valid AWS resource IDs
        if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
            print_log -r "[error] " "Failed to find security group '${SG_NAME}'. Please ensure VPC setup completed successfully."
            return 1
        fi
        if [ "$PRIVATE_SUBNET_ID" = "None" ] || [ -z "$PRIVATE_SUBNET_ID" ]; then
            print_log -r "[error] " "Failed to find private subnet. Please ensure VPC setup completed successfully."
            return 1
        fi
        if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
            print_log -r "[error] " "Failed to find VPC. Please ensure VPC setup completed successfully."
            return 1
        fi
    fi

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
        
        if ! aws iam attach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole; then
            print_log -r "[error] " "Failed to attach VPC execution policy to Lambda role"
            return 1
        fi

        cat > lambda-permissions-policy.json << EOL
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": ["dynamodb:PutItem", "s3:PutObject", "sns:Publish", "sqs:SendMessage", "secretsmanager:GetSecretValue"], "Resource": "*" }] }
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
        
        if ! aws iam attach-role-policy --role-name $QUERY_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole; then
            print_log -r "[error] " "Failed to attach VPC execution policy to Query Lambda role"
            return 1
        fi
        
        cat > query-permissions.json << EOL
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": ["dynamodb:Query", "secretsmanager:GetSecretValue"], "Resource": "*" }] }
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
            --vpc-config SubnetIds=$PRIVATE_SUBNET_ID,SecurityGroupIds=$SG_ID \
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
    else
        print_log -y "[skip] " "Lambda function '${LAMBDA_FUNCTION_NAME}' already exists."
        if ! LAMBDA_FUNCTION_ARN=$(aws lambda get-function --function-name $LAMBDA_FUNCTION_NAME --query Configuration.FunctionArn --output text); then
            print_log -r "[error] " "Failed to get existing Lambda function ARN"
            return 1
        fi
    fi

    # Query Handler Lambda Function
    QUERY_LAMBDA_NAME="func-query-${PROJECT_NAME}"
    if ! aws lambda get-function --function-name $QUERY_LAMBDA_NAME > /dev/null 2>&1; then
        print_log -c "[lambda] " "Creating Query Handler Lambda function..."
        echo 'export const handler = async (event) => { console.log(`Received event: ${JSON.stringify(event)}`); return { statusCode: 200, body: "Hello from Query Lambda!" }; };' > query.mjs
        
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
            --vpc-config SubnetIds=$PRIVATE_SUBNET_ID,SecurityGroupIds=$SG_ID \
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
    else
        print_log -y "[skip] " "Query Lambda function '${QUERY_LAMBDA_NAME}' already exists."
        if ! QUERY_LAMBDA_ARN=$(aws lambda get-function --function-name $QUERY_LAMBDA_NAME --query Configuration.FunctionArn --output text); then
            print_log -r "[error] " "Failed to get existing Query Lambda function ARN"
            return 1
        fi
    fi

    # API Gateway
    API_GW_NAME="api-iot-${PROJECT_NAME}"
    if ! API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='${API_GW_NAME}'].ApiId" --output text); then
        print_log -r "[error] " "Failed to check for existing API Gateway"
        return 1
    fi
    
    if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
        print_log -c "[api] " "Creating API Gateway..."
        if ! API_ID=$(aws apigatewayv2 create-api --name $API_GW_NAME --protocol-type HTTP --query ApiId --output text); then
            print_log -r "[error] " "Failed to create API Gateway"
            return 1
        fi
        
        if ! INTEGRATION_ID=$(aws apigatewayv2 create-integration --api-id $API_ID --integration-type AWS_PROXY --integration-uri $QUERY_LAMBDA_ARN --payload-format-version 2.0 --query IntegrationId --output text); then
            print_log -r "[error] " "Failed to create API Gateway integration"
            return 1
        fi
        
        if ! aws apigatewayv2 create-route --api-id $API_ID --route-key 'GET /data' --target "integrations/${INTEGRATION_ID}"; then
            print_log -r "[error] " "Failed to create API Gateway route"
            return 1
        fi
        
        # Get account ID for permission
        if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text); then
            print_log -r "[error] " "Failed to get AWS account ID"
            return 1
        fi
        
        if ! aws lambda add-permission --function-name $QUERY_LAMBDA_NAME --statement-id "ApiGatewayInvokePermission" --action lambda:InvokeFunction --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:$AWS_REGION:$ACCOUNT_ID:$API_ID/*/*/*"; then
            print_log -r "[error] " "Failed to add API Gateway permission to Lambda"
            return 1
        fi
        
        print_log -g "[ok] " "API Gateway created successfully."
    else
        print_log -y "[skip] " "API Gateway '${API_GW_NAME}' already exists."
    fi
    
    if ! API_ENDPOINT=$(aws apigatewayv2 get-api --api-id $API_ID --query ApiEndpoint --output text); then
        print_log -r "[error] " "Failed to get API Gateway endpoint"
        return 1
    fi

    # Create retraining Lambda function if SageMaker is enabled


    print_log -g "[ok] " "Lambda setup complete!"
    print_log -m "[Lambda Function ARN] " "${LAMBDA_FUNCTION_ARN}"
    print_log -m "[Query Lambda ARN] " "${QUERY_LAMBDA_ARN}"
    print_log -m "[API Gateway Endpoint] " "${API_ENDPOINT}"
    
    # Export variables for other components
    export LAMBDA_FUNCTION_ARN
    export LAMBDA_FUNCTION_NAME
    export LAMBDA_ROLE_NAME
    export QUERY_LAMBDA_ARN
    export QUERY_LAMBDA_NAME
    export QUERY_ROLE_NAME
    export API_ID
    export API_ENDPOINT
    
    cleanup_temp_files
}

setup_retraining_pipeline() {
    print_log -c "[pipeline] " "Setting up SageMaker Pipeline for retraining..."
    
    # Get SageMaker role ARN (created by SageMaker component)
    SAGEMAKER_ROLE_NAME="SageMakerExecutionRole-${PROJECT_NAME}"
    if ! SAGEMAKER_ROLE_ARN=$(aws iam get-role --role-name $SAGEMAKER_ROLE_NAME --query Role.Arn --output text 2>/dev/null); then
        print_log -r "[error] " "SageMaker role not found. Run SageMaker setup first."
        return 1
    fi
    
    # Create SageMaker Pipeline definition
    PIPELINE_NAME="${PROJECT_NAME}-retraining-pipeline"
    
    cat > pipeline_definition.json << 'PIPELINE_EOF'
{
  "Version": "2020-12-01",
  "Metadata": {},
  "Parameters": [
    {
      "Name": "TrainingInstanceType",
      "Type": "String",
      "DefaultValue": "ml.m5.large"
    },
    {
      "Name": "ModelApprovalStatus",
      "Type": "String",
      "DefaultValue": "PendingManualApproval"
    }
  ],
  "PipelineExperimentConfig": {
    "ExperimentName": "PIPELINE_NAME-experiment",
    "TrialName": "PIPELINE_NAME-trial"
  },
  "Steps": [
    {
      "Name": "TrainingStep",
      "Type": "Training",
      "Arguments": {
        "TrainingJobName": "PIPELINE_NAME-training",
        "RoleArn": "SAGEMAKER_ROLE_ARN",
        "AlgorithmSpecification": {
          "TrainingImage": "TRAINING_IMAGE_URI",
          "TrainingInputMode": "File"
        },
        "InputDataConfig": [
          {
            "ChannelName": "training",
            "DataSource": {
              "S3DataSource": {
                "S3DataType": "S3Prefix",
                "S3Uri": "S3_TRAINING_PATH",
                "S3DataDistributionType": "FullyReplicated"
              }
            }
          }
        ],
        "OutputDataConfig": {
          "S3OutputPath": "S3_OUTPUT_PATH"
        },
        "ResourceConfig": {
          "InstanceType": {"Get": "Parameters.TrainingInstanceType"},
          "InstanceCount": 1,
          "VolumeSizeInGB": 10
        },
        "StoppingCondition": {
          "MaxRuntimeInSeconds": 3600
        },
        "HyperParameters": {
          "sagemaker_program": "train.py",
          "sagemaker_submit_directory": "S3_CODE_PATH"
        }
      }
    },
    {
      "Name": "CreateModelStep",
      "Type": "Model",
      "Arguments": {
        "ModelName": "PIPELINE_NAME-model",
        "PrimaryContainer": {
          "Image": "TRAINING_IMAGE_URI",
          "ModelDataUrl": {"Get": "Steps.TrainingStep.ModelArtifacts.S3ModelArtifacts"},
          "Environment": {
            "SAGEMAKER_PROGRAM": "inference.py",
            "SAGEMAKER_SUBMIT_DIRECTORY": "S3_CODE_PATH"
          }
        },
        "ExecutionRoleArn": "SAGEMAKER_ROLE_ARN"
      }
    }
  ]
}
PIPELINE_EOF
    
    # Replace placeholders
    sed -i "s/PIPELINE_NAME/${PIPELINE_NAME}/g" pipeline_definition.json
    sed -i "s|SAGEMAKER_ROLE_ARN|${SAGEMAKER_ROLE_ARN}|g" pipeline_definition.json
    sed -i "s|TRAINING_IMAGE_URI|$(get_sagemaker_ecr_uri ${AWS_REGION})/sagemaker-scikit-learn:0.23-1-cpu-py3|g" pipeline_definition.json
    sed -i "s|S3_TRAINING_PATH|s3://${S3_DATA_BUCKET}/sagemaker/training-data/|g" pipeline_definition.json
    sed -i "s|S3_OUTPUT_PATH|s3://${S3_DATA_BUCKET}/sagemaker/retrained-models/|g" pipeline_definition.json
    sed -i "s|S3_CODE_PATH|s3://${S3_DATA_BUCKET}/sagemaker/code/sourcedir.tar.gz|g" pipeline_definition.json
    
    # Create or update pipeline
    if ! aws sagemaker describe-pipeline --pipeline-name $PIPELINE_NAME > /dev/null 2>&1; then
        print_log -c "[create] " "Creating SageMaker Pipeline..."
        aws sagemaker create-pipeline \
            --pipeline-name $PIPELINE_NAME \
            --pipeline-definition file://pipeline_definition.json \
            --role-arn $SAGEMAKER_ROLE_ARN > /dev/null
    else
        print_log -c "[update] " "Updating SageMaker Pipeline..."
        aws sagemaker update-pipeline \
            --pipeline-name $PIPELINE_NAME \
            --pipeline-definition file://pipeline_definition.json > /dev/null
    fi
    
    # Create EventBridge rule to trigger pipeline weekly
    RULE_NAME="${PROJECT_NAME}-weekly-retrain"
    if ! aws events describe-rule --name $RULE_NAME > /dev/null 2>&1; then
        print_log -c "[schedule] " "Creating weekly pipeline trigger..."
        aws events put-rule \
            --name $RULE_NAME \
            --schedule-expression "rate(7 days)" \
            --description "Weekly SageMaker Pipeline execution" > /dev/null
        
        # Add SageMaker Pipeline as target
        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        aws events put-targets \
            --rule $RULE_NAME \
            --targets "Id=1,Arn=arn:aws:sagemaker:$AWS_REGION:$ACCOUNT_ID:pipeline/$PIPELINE_NAME,RoleArn=$SAGEMAKER_ROLE_ARN,SageMakerPipelineParameters={PipelineParameterList=[{Name=TrainingInstanceType,Value=ml.m5.large}]}" > /dev/null
    fi
    
    print_log -g "[ok] " "SageMaker Pipeline configured for retraining"
    print_log -y "[info] " "Pipeline will execute weekly via EventBridge"
    print_log -m "[Pipeline] " "${PIPELINE_NAME}"
    
    rm -f pipeline_definition.json
}

cleanup_lambda() {
    print_log -b "[delete] " "Cleaning up Lambda Functions..."
    validate_inputs
    setup_aws_environment

    LAMBDA_FUNCTION_NAME="func-ingestion-${PROJECT_NAME}"
    LAMBDA_ROLE_NAME="role-lambda-${PROJECT_NAME}"
    QUERY_LAMBDA_NAME="func-query-${PROJECT_NAME}"
    QUERY_ROLE_NAME="role-lambda-query-${PROJECT_NAME}"
    API_GW_NAME="api-iot-${PROJECT_NAME}"
    
    # Delete API Gateway
    print_log -b "[delete] " "Deleting API Gateway..."
    API_ID=$(aws apigatewayv2 get-apis --query "Items[?Name=='${API_GW_NAME}'].ApiId" --output text 2>/dev/null)
    if [ ! -z "$API_ID" ] && [ "$API_ID" != "None" ]; then
        aws apigatewayv2 delete-api --api-id $API_ID 2>/dev/null || true
        print_log -g "[ok] " "API Gateway deleted."
    fi
    
    # Delete Query Lambda Function
    print_log -b "[delete] " "Deleting Query Lambda Function..."
    aws lambda delete-function --function-name $QUERY_LAMBDA_NAME 2>/dev/null || true
    aws iam delete-role-policy --role-name $QUERY_ROLE_NAME --policy-name "QueryLambdaPermissions" 2>/dev/null || true
    aws iam detach-role-policy --role-name $QUERY_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole 2>/dev/null || true
    aws iam delete-role --role-name $QUERY_ROLE_NAME 2>/dev/null || true
    print_log -g "[ok] " "Query Lambda function and IAM Role deleted."
    
    # Delete Ingestion Lambda Function
    print_log -b "[delete] " "Deleting Ingestion Lambda Function..."
    aws lambda delete-function --function-name $LAMBDA_FUNCTION_NAME 2>/dev/null || true
    aws iam delete-role-policy --role-name $LAMBDA_ROLE_NAME --policy-name "LambdaCustomPermissions" 2>/dev/null || true
    aws iam detach-role-policy --role-name $LAMBDA_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole 2>/dev/null || true
    aws iam delete-role --role-name $LAMBDA_ROLE_NAME 2>/dev/null || true
    print_log -g "[ok] " "Ingestion Lambda function and IAM Role deleted."
    
    # Delete retraining Lambda if it exists
    RETRAIN_LAMBDA_NAME="func-retrain-${PROJECT_NAME}"
    RETRAIN_ROLE_NAME="role-lambda-retrain-${PROJECT_NAME}"
    RULE_NAME="${PROJECT_NAME}-weekly-retrain"
    
    print_log -b "[delete] " "Deleting retraining Lambda function..."
    aws events remove-targets --rule $RULE_NAME --ids "1" 2>/dev/null || true
    aws events delete-rule --name $RULE_NAME 2>/dev/null || true
    aws lambda delete-function --function-name $RETRAIN_LAMBDA_NAME 2>/dev/null || true
    aws iam detach-role-policy --role-name $RETRAIN_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
    aws iam detach-role-policy --role-name $RETRAIN_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess 2>/dev/null || true
    aws iam detach-role-policy --role-name $RETRAIN_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || true
    aws iam delete-role --role-name $RETRAIN_ROLE_NAME 2>/dev/null || true
    print_log -g "[ok] " "Retraining Lambda function deleted."
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