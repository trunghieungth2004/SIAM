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
    print_log -y "[manual] " "Trigger retraining: aws lambda invoke --function-name $RETRAIN_LAMBDA_NAME /tmp/retrain-output.json"
    
    cleanup_temp_files
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
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["sagemaker:CreateTrainingJob","sagemaker:DescribeTrainingJob","s3:GetObject","s3:PutObject","s3:ListBucket","iam:PassRole"],"Resource":"*"}]}
EOF
        aws iam put-role-policy --role-name $RETRAIN_ROLE_NAME --policy-name RetrainPolicy --policy-document file:///tmp/retrain-policy.json
        sleep 10
    fi
    
    ROLE_ARN=$(aws iam get-role --role-name $RETRAIN_ROLE_NAME --query Role.Arn --output text)
    
    # Get S3 bucket from resource file or discover
    SETUP_DIR="$(dirname "$(dirname "$0")")"
    RESOURCE_FILE="${SETUP_DIR}/${PROJECT_NAME}_resources.txt"
    if [ -f "$RESOURCE_FILE" ]; then
        S3_BUCKET=$(grep "S3_DATA_BUCKET" "$RESOURCE_FILE" | cut -d'=' -f2)
    fi
    if [ -z "$S3_BUCKET" ]; then
        PROJECT_CLEAN=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        S3_BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name, '${PROJECT_CLEAN}') && contains(Name, 'iot-data')].Name" --output text | head -1)
    fi
    
    SAGEMAKER_ROLE_ARN=$(aws iam get-role --role-name "SageMakerExecutionRole-${PROJECT_NAME}" --query Role.Arn --output text)
    
    cat > /tmp/retrain.mjs << 'EOF'
import { SageMakerClient, CreateTrainingJobCommand } from "@aws-sdk/client-sagemaker";
import { S3Client, ListObjectsV2Command, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
const sagemaker = new SageMakerClient({});
const s3 = new S3Client({});
export const handler = async (event) => {
    const projectName = process.env.PROJECT_NAME;
    const bucket = process.env.S3_BUCKET;
    const roleArn = process.env.SAGEMAKER_ROLE_ARN;
    const region = process.env.AWS_REGION;
    const jobName = `${projectName}-maintenance-${Date.now()}`;
    
    // Aggregate new sensor data into training CSV
    console.log('Aggregating sensor data from S3...');
    const listCmd = new ListObjectsV2Command({Bucket: bucket, Prefix: 'sensor-data/', MaxKeys: 1000});
    const objects = await s3.send(listCmd);
    
    let csvData = 'timestamp,temp_c,ax,ay,az,gx,gy,gz,current_a\n';
    let count = 0;
    
    for (const obj of (objects.Contents || [])) {
        if (!obj.Key.endsWith('.json')) continue;
        try {
            const getCmd = new GetObjectCommand({Bucket: bucket, Key: obj.Key});
            const response = await s3.send(getCmd);
            const data = JSON.parse(await response.Body.transformToString());
            csvData += `${data.timestamp},${data.temp_c},${data.ax},${data.ay},${data.az},${data.gx},${data.gy},${data.gz},${data.current_a}\n`;
            count++;
            if (count >= 500) break; // Limit to 500 samples
        } catch (e) { console.log(`Skip ${obj.Key}: ${e.message}`); }
    }
    
    if (count < 10) {
        console.log('Not enough data for retraining');
        return {statusCode: 400, body: JSON.stringify({error: 'Insufficient data', count})};
    }
    
    // Upload aggregated training data
    const putCmd = new PutObjectCommand({Bucket: bucket, Key: 'sagemaker/training-data/training.csv', Body: csvData});
    await s3.send(putCmd);
    console.log(`Aggregated ${count} samples for training`);
    
    const cmd = new CreateTrainingJobCommand({
        TrainingJobName: jobName,
        RoleArn: roleArn,
        AlgorithmSpecification: {
            TrainingImage: `763104351884.dkr.ecr.${region}.amazonaws.com/tensorflow-training:2.13-cpu-py310`,
            TrainingInputMode: "File"
        },
        InputDataConfig: [{ChannelName: "training", DataSource: {S3DataSource: {S3DataType: "S3Prefix", S3Uri: `s3://${bucket}/sagemaker/training-data/`, S3DataDistributionType: "FullyReplicated"}}}],
        OutputDataConfig: {S3OutputPath: `s3://${bucket}/sagemaker/output/`},
        ResourceConfig: {InstanceType: "ml.t3.medium", InstanceCount: 1, VolumeSizeInGB: 10},
        StoppingCondition: {MaxRuntimeInSeconds: 3600},
        HyperParameters: {sagemaker_program: "train.py", sagemaker_submit_directory: `s3://${bucket}/sagemaker/code/sourcedir.tar.gz`}
    });
    await sagemaker.send(cmd);
    return {statusCode: 200, body: JSON.stringify({message: 'Training started', jobName, samples: count})};
};
EOF
    
    zip -q /tmp/retrain.zip /tmp/retrain.mjs
    aws lambda create-function --function-name $RETRAIN_LAMBDA_NAME --runtime nodejs20.x --role $ROLE_ARN \
        --handler retrain.handler --zip-file fileb:///tmp/retrain.zip --timeout 60 \
        --environment "Variables={PROJECT_NAME=${PROJECT_NAME},S3_BUCKET=${S3_BUCKET},SAGEMAKER_ROLE_ARN=${SAGEMAKER_ROLE_ARN}}" > /dev/null
    
    # Set CloudWatch log retention to 7 days
    aws logs put-retention-policy --log-group-name "/aws/lambda/${RETRAIN_LAMBDA_NAME}" --retention-in-days 7 2>/dev/null || true
    
    rm -f /tmp/lambda-trust.json /tmp/retrain-policy.json /tmp/retrain.mjs /tmp/retrain.zip
}

cleanup_eventbridge() {
    print_log -b "[delete] " "Cleaning up EventBridge automation..."
    validate_inputs
    setup_aws_environment

    RETRAIN_RULE_NAME="${PROJECT_NAME}-weekly-retrain"
    DEPLOY_RULE_NAME="${PROJECT_NAME}-model-deploy"
    RETRAIN_LAMBDA_NAME="func-retrain-${PROJECT_NAME}"
    DEPLOY_LAMBDA_NAME="func-deploy-${PROJECT_NAME}"
    RETRAIN_ROLE_NAME="role-lambda-retrain-${PROJECT_NAME}"
    DEPLOY_ROLE_NAME="role-lambda-deploy-${PROJECT_NAME}"
    
    # Remove targets and delete rules
    aws events remove-targets --rule $RETRAIN_RULE_NAME --ids "1" 2>/dev/null || true
    aws events remove-targets --rule $DEPLOY_RULE_NAME --ids "1" 2>/dev/null || true
    aws events delete-rule --name $RETRAIN_RULE_NAME 2>/dev/null || true
    aws events delete-rule --name $DEPLOY_RULE_NAME 2>/dev/null || true
    
    # Delete Lambdas
    aws lambda delete-function --function-name $RETRAIN_LAMBDA_NAME 2>/dev/null || true
    aws lambda delete-function --function-name $DEPLOY_LAMBDA_NAME 2>/dev/null || true
    
    # Delete IAM roles
    aws iam delete-role-policy --role-name $RETRAIN_ROLE_NAME --policy-name "RetrainPolicy" 2>/dev/null || true
    aws iam detach-role-policy --role-name $RETRAIN_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
    aws iam delete-role --role-name $RETRAIN_ROLE_NAME 2>/dev/null || true
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