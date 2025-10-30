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

    # 1. Weekly retraining rule
    RETRAIN_RULE_NAME="${PROJECT_NAME}-weekly-retrain"
    if ! aws events describe-rule --name $RETRAIN_RULE_NAME > /dev/null 2>&1; then
        print_log -c "[create] " "Creating weekly retraining schedule..."
        aws events put-rule \
            --name $RETRAIN_RULE_NAME \
            --schedule-expression "rate(7 days)" \
            --description "Weekly SageMaker Pipeline execution"
        
        ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
        PIPELINE_NAME="${PROJECT_NAME}-retraining-pipeline"
        aws events put-targets \
            --rule $RETRAIN_RULE_NAME \
            --targets "Id=1,Arn=arn:aws:sagemaker:$AWS_REGION:$ACCOUNT_ID:pipeline/$PIPELINE_NAME,RoleArn=$SAGEMAKER_ROLE_ARN"
    fi

    # 2. S3 model deployment trigger
    DEPLOY_RULE_NAME="${PROJECT_NAME}-model-deploy"
    if ! aws events describe-rule --name $DEPLOY_RULE_NAME > /dev/null 2>&1; then
        print_log -c "[create] " "Creating model deployment trigger..."
        aws events put-rule \
            --name $DEPLOY_RULE_NAME \
            --event-pattern "{\"source\":[\"aws.sagemaker\"],\"detail-type\":[\"SageMaker Training Job State Change\"],\"detail\":{\"TrainingJobStatus\":[\"Completed\"]}}" \
            --description "Trigger edge deployment on model completion"
        
        # Get Deploy Lambda ARN from VPC component
        DEPLOY_LAMBDA_NAME="func-deploy-${PROJECT_NAME}"
        if ! DEPLOY_LAMBDA_ARN=$(aws lambda get-function --function-name $DEPLOY_LAMBDA_NAME --query Configuration.FunctionArn --output text 2>/dev/null); then
            print_log -r "[error] " "Deploy Lambda not found. Ensure VPC component created it."
            return 1
        fi
        
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
    fi

    print_log -g "[ok] " "EventBridge automation setup complete!"
    print_log -m "[Weekly Retraining] " "$RETRAIN_RULE_NAME"
    print_log -m "[Auto Deployment] " "$DEPLOY_RULE_NAME"
    
    cleanup_temp_files
}

cleanup_eventbridge() {
    print_log -b "[delete] " "Cleaning up EventBridge automation..."
    validate_inputs
    setup_aws_environment

    RETRAIN_RULE_NAME="${PROJECT_NAME}-weekly-retrain"
    DEPLOY_RULE_NAME="${PROJECT_NAME}-model-deploy"
    DEPLOY_LAMBDA_NAME="func-deploy-${PROJECT_NAME}"
    DEPLOY_ROLE_NAME="role-lambda-deploy-${PROJECT_NAME}"
    
    # Remove targets and delete rules
    aws events remove-targets --rule $RETRAIN_RULE_NAME --ids "1" 2>/dev/null || true
    aws events remove-targets --rule $DEPLOY_RULE_NAME --ids "1" 2>/dev/null || true
    aws events delete-rule --name $RETRAIN_RULE_NAME 2>/dev/null || true
    aws events delete-rule --name $DEPLOY_RULE_NAME 2>/dev/null || true
    
    # Delete deployment Lambda
    aws lambda delete-function --function-name $DEPLOY_LAMBDA_NAME 2>/dev/null || true
    aws iam delete-role-policy --role-name $DEPLOY_ROLE_NAME --policy-name "DeployLambdaPermissions" 2>/dev/null || true
    aws iam detach-role-policy --role-name $DEPLOY_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
    aws iam delete-role --role-name $DEPLOY_ROLE_NAME 2>/dev/null || true
    
    print_log -g "[ok] " "EventBridge cleanup completed."
}

case "${1:-}" in
    setup) setup_eventbridge ;;
    cleanup) cleanup_eventbridge ;;
    *) echo "Usage: $0 {setup|cleanup}"; exit 1 ;;
esac