#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| EventBridge Component              |--/ /-|#
#|-/ /--| Automated ML pipeline & deployment |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

source "$(dirname "$0")/common.sh"

setup_eventbridge() {
    print_log -b "[automation] " "Setting up EventBridge automation..."
    validate_inputs
    setup_aws_environment

    # Get SageMaker role ARN
    SAGEMAKER_ROLE_NAME="SageMakerExecutionRole-${PROJECT_NAME}"
    if ! SAGEMAKER_ROLE_ARN=$(aws iam get-role --role-name $SAGEMAKER_ROLE_NAME --query Role.Arn --output text 2>/dev/null); then
        print_log -r "[error] " "SageMaker role not found. Run SageMaker setup first."
        return 1
    fi

    # 1. Weekly retraining rule - triggers Lambda to start training job
    RETRAIN_RULE_NAME="${PROJECT_NAME}-weekly-retrain"
    RETRAIN_LAMBDA_NAME="func-retrain-${PROJECT_NAME}"
    
    if ! aws events describe-rule --name $RETRAIN_RULE_NAME > /dev/null 2>&1; then
        print_log -c "[create] " "Creating weekly retraining schedule..."
        aws events put-rule \
            --name $RETRAIN_RULE_NAME \
            --schedule-expression "rate(14 days)" \
            --description "Bi-weekly SageMaker retraining trigger (cost optimized)"
        
        # Create retraining Lambda if not exists
        if ! aws lambda get-function --function-name $RETRAIN_LAMBDA_NAME > /dev/null 2>&1; then
            print_log -c "[lambda] " "Creating retraining Lambda function..."
            create_retrain_lambda
        fi
        
        RETRAIN_LAMBDA_ARN=$(aws lambda get-function --function-name $RETRAIN_LAMBDA_NAME --query Configuration.FunctionArn --output text)
        aws events put-targets \
            --rule $RETRAIN_RULE_NAME \
            --targets "Id=1,Arn=$RETRAIN_LAMBDA_ARN"
        
        aws lambda add-permission \
            --function-name $RETRAIN_LAMBDA_NAME \
            --statement-id "EventBridgeRetrainPermission" \
            --action lambda:InvokeFunction \
            --principal events.amazonaws.com \
            --source-arn "arn:aws:events:$AWS_REGION:$(aws sts get-caller-identity --query Account --output text):rule/$RETRAIN_RULE_NAME" 2>/dev/null || true
    fi

    # 2. S3 model deployment trigger (optional - only if deploy Lambda exists)
    DEPLOY_RULE_NAME="${PROJECT_NAME}-model-deploy"
    DEPLOY_LAMBDA_NAME="func-deploy-${PROJECT_NAME}"
    
    if ! aws events describe-rule --name $DEPLOY_RULE_NAME > /dev/null 2>&1; then
        # Check if deploy Lambda exists (created by Lambda component)
        if DEPLOY_LAMBDA_ARN=$(aws lambda get-function --function-name $DEPLOY_LAMBDA_NAME --query Configuration.FunctionArn --output text 2>/dev/null); then
            print_log -c "[create] " "Creating model deployment trigger..."
            aws events put-rule \
                --name $DEPLOY_RULE_NAME \
                --event-pattern "{\"source\":[\"aws.sagemaker\"],\"detail-type\":[\"SageMaker Training Job State Change\"],\"detail\":{\"TrainingJobStatus\":[\"Completed\"]}}" \
                --description "Trigger edge deployment on model completion"
            
            # Add EventBridge target
            aws events put-targets \
                --rule $DEPLOY_RULE_NAME \
                --targets "Id=1,Arn=$DEPLOY_LAMBDA_ARN"
            
            # Add Lambda permission for EventBridge
            aws lambda add-permission \
                --function-name $DEPLOY_LAMBDA_NAME \
                --statement-id "EventBridgeInvokePermission" \
                --action lambda:InvokeFunction \
                --principal events.amazonaws.com \
                --source-arn "arn:aws:events:$AWS_REGION:$(aws sts get-caller-identity --query Account --output text):rule/$DEPLOY_RULE_NAME" 2>/dev/null || true
            
            print_log -g "[ok] " "Model deployment trigger created"
        else
            print_log -y "[skip] " "Deploy Lambda not found - skipping auto-deployment trigger"
            print_log -y "[info] " "Run Lambda component setup to enable automatic edge deployment"
        fi
    fi

    # 3. Monthly API key rotation rule
    ROTATE_RULE_NAME="${PROJECT_NAME}-monthly-api-rotation"
    ROTATE_LAMBDA_NAME="func-rotate-api-${PROJECT_NAME}"
    
    if ! aws events describe-rule --name $ROTATE_RULE_NAME > /dev/null 2>&1; then
        print_log -c "[create] " "Creating monthly API key rotation schedule..."
        aws events put-rule \
            --name $ROTATE_RULE_NAME \
            --schedule-expression "rate(30 days)" \
            --description "Monthly API Gateway key rotation for security"
        
        # Create rotation Lambda if not exists
        if ! aws lambda get-function --function-name $ROTATE_LAMBDA_NAME > /dev/null 2>&1; then
            print_log -c "[lambda] " "Creating API rotation Lambda function..."
            create_rotate_lambda
        fi
        
        ROTATE_LAMBDA_ARN=$(aws lambda get-function --function-name $ROTATE_LAMBDA_NAME --query Configuration.FunctionArn --output text)
        aws events put-targets \
            --rule $ROTATE_RULE_NAME \
            --targets "Id=1,Arn=$ROTATE_LAMBDA_ARN"
        
        aws lambda add-permission \
            --function-name $ROTATE_LAMBDA_NAME \
            --statement-id "EventBridgeRotatePermission" \
            --action lambda:InvokeFunction \
            --principal events.amazonaws.com \
            --source-arn "arn:aws:events:$AWS_REGION:$(aws sts get-caller-identity --query Account --output text):rule/$ROTATE_RULE_NAME" 2>/dev/null || true
    fi

    print_log -g "[ok] " "EventBridge automation setup complete!"
    print_log -m "[Weekly Retraining] " "$RETRAIN_RULE_NAME"
    if [ -n "$DEPLOY_LAMBDA_ARN" ]; then
        print_log -m "[Auto Deployment] " "$DEPLOY_RULE_NAME"
    fi
    print_log -m "[Monthly API Rotation] " "$ROTATE_RULE_NAME"
    print_log -y "[manual] " "Trigger retraining: aws lambda invoke --function-name $RETRAIN_LAMBDA_NAME /tmp/retrain-output.json"
    print_log -y "[manual] " "Trigger rotation: aws lambda invoke --function-name $ROTATE_LAMBDA_NAME /tmp/rotate-output.json"
}

cleanup_temp_files() {
    rm -f /tmp/lambda-trust.json /tmp/retrain-policy.json /tmp/retrain.mjs /tmp/retrain.zip 2>/dev/null || true
}

create_retrain_lambda() {
    RETRAIN_LAMBDA_NAME="func-retrain-${PROJECT_NAME}"
    RETRAIN_ROLE_NAME="role-lambda-retrain-${PROJECT_NAME}"
    
    # Create IAM role
    if ! aws iam get-role --role-name $RETRAIN_ROLE_NAME > /dev/null 2>&1; then
        cat > /tmp/lambda-trust.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
        aws iam create-role --role-name $RETRAIN_ROLE_NAME --assume-role-policy-document file:///tmp/lambda-trust.json > /dev/null
        aws iam attach-role-policy --role-name $RETRAIN_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
        
        cat > /tmp/retrain-policy.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["sagemaker:CreateTrainingJob","sagemaker:DescribeTrainingJob","s3:GetObject","s3:PutObject","s3:ListBucket","s3:ListAllMyBuckets","iam:GetRole","iam:PassRole"],"Resource":"*"}]}
EOF
        aws iam put-role-policy --role-name $RETRAIN_ROLE_NAME --policy-name RetrainPolicy --policy-document file:///tmp/retrain-policy.json
        sleep 10
    fi
    
    ROLE_ARN=$(aws iam get-role --role-name $RETRAIN_ROLE_NAME --query Role.Arn --output text)
    
    # Use Lambda source file from components/Lambda directory
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    LAMBDA_DIR="${SCRIPT_DIR}/Lambda"
    if [ ! -f "${LAMBDA_DIR}/retrain.mjs" ]; then
        print_log -r "[error] " "Lambda source file not found: ${LAMBDA_DIR}/retrain.mjs"
        return 1
    fi
    
    print_log -g "[found] " "Using Lambda source: ${LAMBDA_DIR}/retrain.mjs"
    
    # Package Lambda
    cp "${LAMBDA_DIR}/retrain.mjs" /tmp/retrain.mjs
    (cd /tmp && zip -q retrain.zip retrain.mjs)
    
    aws lambda create-function --function-name $RETRAIN_LAMBDA_NAME --runtime nodejs20.x --role $ROLE_ARN \
        --handler retrain.handler --zip-file fileb:///tmp/retrain.zip --timeout 60 \
        --environment "Variables={PROJECT_NAME=${PROJECT_NAME}}" > /dev/null
    
    # Set CloudWatch log retention to 7 days
    aws logs put-retention-policy --log-group-name "/aws/lambda/${RETRAIN_LAMBDA_NAME}" --retention-in-days 7 2>/dev/null || true
    
    rm -f /tmp/lambda-trust.json /tmp/retrain-policy.json /tmp/retrain.mjs /tmp/retrain.zip
}

create_rotate_lambda() {
    ROTATE_LAMBDA_NAME="func-rotate-api-${PROJECT_NAME}"
    ROTATE_ROLE_NAME="role-lambda-rotate-${PROJECT_NAME}"
    
    # Create IAM role
    if ! aws iam get-role --role-name $ROTATE_ROLE_NAME > /dev/null 2>&1; then
        cat > /tmp/lambda-trust.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
        aws iam create-role --role-name $ROTATE_ROLE_NAME --assume-role-policy-document file:///tmp/lambda-trust.json > /dev/null
        aws iam attach-role-policy --role-name $ROTATE_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
        
        cat > /tmp/rotate-policy.json << EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["apigateway:*","s3:GetObject","s3:PutObject","s3:ListAllMyBuckets"],"Resource":"*"}]}
EOF
        aws iam put-role-policy --role-name $ROTATE_ROLE_NAME --policy-name RotatePolicy --policy-document file:///tmp/rotate-policy.json
        sleep 10
    fi
    
    ROLE_ARN=$(aws iam get-role --role-name $ROTATE_ROLE_NAME --query Role.Arn --output text)
    
    # Use Lambda source file from components/Lambda directory
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    LAMBDA_DIR="${SCRIPT_DIR}/Lambda"
    if [ ! -f "${LAMBDA_DIR}/rotate.mjs" ]; then
        print_log -r "[error] " "Lambda source file not found: ${LAMBDA_DIR}/rotate.mjs"
        return 1
    fi
    
    print_log -g "[found] " "Using Lambda source: ${LAMBDA_DIR}/rotate.mjs"
    
    # Package Lambda
    cp "${LAMBDA_DIR}/rotate.mjs" /tmp/rotate.mjs
    (cd /tmp && zip -q rotate.zip rotate.mjs)
    
    aws lambda create-function --function-name $ROTATE_LAMBDA_NAME --runtime nodejs20.x --role $ROLE_ARN \
        --handler rotate.handler --zip-file fileb:///tmp/rotate.zip --timeout 60 \
        --environment "Variables={PROJECT_NAME=${PROJECT_NAME}}" > /dev/null
    
    # Set CloudWatch log retention to 7 days
    aws logs put-retention-policy --log-group-name "/aws/lambda/${ROTATE_LAMBDA_NAME}" --retention-in-days 7 2>/dev/null || true
    
    rm -f /tmp/lambda-trust.json /tmp/rotate-policy.json /tmp/rotate.mjs /tmp/rotate.zip
}

cleanup_eventbridge() {
    print_log -b "[delete] " "Cleaning up EventBridge automation..."
    validate_inputs
    setup_aws_environment

    RETRAIN_RULE_NAME="${PROJECT_NAME}-weekly-retrain"
    DEPLOY_RULE_NAME="${PROJECT_NAME}-model-deploy"
    ROTATE_RULE_NAME="${PROJECT_NAME}-monthly-api-rotation"
    RETRAIN_LAMBDA_NAME="func-retrain-${PROJECT_NAME}"
    DEPLOY_LAMBDA_NAME="func-deploy-${PROJECT_NAME}"
    ROTATE_LAMBDA_NAME="func-rotate-api-${PROJECT_NAME}"
    RETRAIN_ROLE_NAME="role-lambda-retrain-${PROJECT_NAME}"
    DEPLOY_ROLE_NAME="role-lambda-deploy-${PROJECT_NAME}"
    ROTATE_ROLE_NAME="role-lambda-rotate-${PROJECT_NAME}"
    
    # Remove targets and delete rules
    aws events remove-targets --rule $RETRAIN_RULE_NAME --ids "1" 2>/dev/null || true
    aws events remove-targets --rule $DEPLOY_RULE_NAME --ids "1" 2>/dev/null || true
    aws events remove-targets --rule $ROTATE_RULE_NAME --ids "1" 2>/dev/null || true
    aws events delete-rule --name $RETRAIN_RULE_NAME 2>/dev/null || true
    aws events delete-rule --name $DEPLOY_RULE_NAME 2>/dev/null || true
    aws events delete-rule --name $ROTATE_RULE_NAME 2>/dev/null || true
    
    # Delete Lambdas
    aws lambda delete-function --function-name $RETRAIN_LAMBDA_NAME 2>/dev/null || true
    aws lambda delete-function --function-name $DEPLOY_LAMBDA_NAME 2>/dev/null || true
    aws lambda delete-function --function-name $ROTATE_LAMBDA_NAME 2>/dev/null || true
    
    # Delete IAM roles
    aws iam delete-role-policy --role-name $RETRAIN_ROLE_NAME --policy-name "RetrainPolicy" 2>/dev/null || true
    aws iam detach-role-policy --role-name $RETRAIN_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
    aws iam delete-role --role-name $RETRAIN_ROLE_NAME 2>/dev/null || true
    aws iam delete-role-policy --role-name $DEPLOY_ROLE_NAME --policy-name "DeployLambdaPermissions" 2>/dev/null || true
    aws iam detach-role-policy --role-name $DEPLOY_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
    aws iam delete-role --role-name $DEPLOY_ROLE_NAME 2>/dev/null || true
    aws iam delete-role-policy --role-name $ROTATE_ROLE_NAME --policy-name "RotatePolicy" 2>/dev/null || true
    aws iam detach-role-policy --role-name $ROTATE_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
    aws iam delete-role --role-name $ROTATE_ROLE_NAME 2>/dev/null || true
    
    print_log -g "[ok] " "EventBridge cleanup completed."
}

case "${1:-}" in
    setup) setup_eventbridge ;;
    cleanup) cleanup_eventbridge ;;
    *) echo "Usage: $0 {setup|cleanup}"; exit 1 ;;
esac