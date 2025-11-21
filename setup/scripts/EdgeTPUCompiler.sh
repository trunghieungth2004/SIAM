#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| Edge TPU Compiler Component        |--/ /-|#
#|-/ /--| EC2-based model compilation        |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../components/common.sh"

setup_edgetpu_compiler() {
    print_log -b "[compiler] " "Setting up Edge TPU Compiler EC2..."
    validate_inputs
    setup_aws_environment

    # Get latest SageMaker model
    LATEST_TRAINING_JOB=$(aws sagemaker list-training-jobs --name-contains "${PROJECT_NAME}-maintenance" --sort-by CreationTime --sort-order Descending --max-results 1 --query "TrainingJobSummaries[0].TrainingJobName" --output text 2>/dev/null)
    
    if [ -z "$LATEST_TRAINING_JOB" ] || [ "$LATEST_TRAINING_JOB" = "None" ]; then
        print_log -r "[error] " "No training job found"
        return 1
    fi
    
    # Get S3 bucket - discover from AWS
    PROJECT_CLEAN=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
    S3_DATA_BUCKET=$(aws s3api list-buckets --query "Buckets[?contains(Name, '${PROJECT_CLEAN}') && contains(Name, 'iot-data')].Name" --output text | head -1)
    
    if [ -z "$S3_DATA_BUCKET" ] || [ "$S3_DATA_BUCKET" = "None" ]; then
        echo "[error] S3 data bucket not found"
        return 1
    fi
    
    MODEL_S3_URI="s3://${S3_DATA_BUCKET}/sagemaker/output/${LATEST_TRAINING_JOB}/output/model.tar.gz"
    
    print_log -c "[model] " "Model: ${MODEL_S3_URI}"
    
    # Create IAM role for EC2
    ROLE_NAME="EdgeTPUCompilerRole-${PROJECT_NAME}"
    if ! aws iam get-role --role-name "$ROLE_NAME" > /dev/null 2>&1; then
        print_log -c "[iam] " "Creating IAM role..."
        cat > /tmp/ec2-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
        aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file:///tmp/ec2-trust-policy.json > /dev/null
        
        cat > /tmp/ec2-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::${S3_DATA_BUCKET}/*"
    },
    {
      "Effect": "Allow",
      "Action": "ec2:TerminateInstances",
      "Resource": "*",
      "Condition": {
        "StringEquals": {"ec2:ResourceTag/Project": "${PROJECT_NAME}"}
      }
    }
  ]
}
EOF
        aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name "CompilerPolicy" --policy-document file:///tmp/ec2-policy.json
        
        aws iam create-instance-profile --instance-profile-name "$ROLE_NAME" > /dev/null 2>&1 || true
        aws iam add-role-to-instance-profile --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME" 2>/dev/null || true
        
        print_log -y "[wait] " "Waiting for IAM role to propagate..."
        sleep 10
        rm -f /tmp/ec2-trust-policy.json /tmp/ec2-policy.json
    fi
    
    # Get Ubuntu AMI
    AMI_ID=$(aws ec2 describe-images --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" --output text)
    
    # Create user-data script
    cat > /tmp/user-data.sh << 'USERDATA_EOF'
#!/bin/bash
set -e

MODEL_S3_URI="{{MODEL_S3_URI}}"
S3_BUCKET="{{S3_BUCKET}}"
TRAINING_JOB_NAME="{{TRAINING_JOB_NAME}}"
AWS_REGION="{{AWS_REGION}}"
INSTANCE_ID=$(ec2-metadata --instance-id | cut -d' ' -f2)

echo "[1/7] Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl gnupg awscli

echo "[2/7] Adding Coral repository..."
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | tee /usr/share/keyrings/coral-edgetpu.asc
echo "deb [signed-by=/usr/share/keyrings/coral-edgetpu.asc] https://packages.cloud.google.com/apt coral-edgetpu-stable main" > /etc/apt/sources.list.d/coral-edgetpu.list

echo "[3/7] Installing edgetpu-compiler..."
apt-get update -qq
apt-get install -y edgetpu-compiler

echo "[4/7] Downloading model from S3..."
mkdir -p /tmp/compile
cd /tmp/compile
if ! aws s3 cp "${MODEL_S3_URI}" model.tar.gz --region "${AWS_REGION}"; then
    echo "[ERROR] Failed to download model from S3"
    aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
    exit 1
fi
tar -xzf model.tar.gz

if [ ! -f "model.tflite" ]; then
    echo "[ERROR] model.tflite not found in archive"
    ls -la
    aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
    exit 1
fi

if [ ! -f "days_scaler.pkl" ]; then
    echo "[ERROR] days_scaler.pkl not found in archive"
    ls -la
    aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
    exit 1
fi

echo "[5/7] Compiling model for Edge TPU..."
if ! edgetpu_compiler model.tflite; then
    echo "[ERROR] edgetpu_compiler failed"
    aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
    exit 1
fi

if [ ! -f "model_edgetpu.tflite" ]; then
    echo "[ERROR] Compilation failed - model_edgetpu.tflite not created"
    aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
    exit 1
fi

echo "[6/7] Uploading compiled model..."
cp model_edgetpu.tflite model.tflite
tar -czf model_compiled.tar.gz model.tflite scaler.pkl days_scaler.pkl features.txt
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
COMPILED_S3="s3://${S3_BUCKET}/models/model_edgetpu_${TIMESTAMP}.tar.gz"
LATEST_S3="s3://${S3_BUCKET}/models/model_edgetpu_latest.tar.gz"
aws s3 cp model_compiled.tar.gz "${COMPILED_S3}" --region "${AWS_REGION}"
aws s3 cp model_compiled.tar.gz "${LATEST_S3}" --region "${AWS_REGION}"

echo "[7/7] Terminating instance..."
aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
USERDATA_EOF
    
    sed -i "s|{{MODEL_S3_URI}}|${MODEL_S3_URI}|g" /tmp/user-data.sh
    sed -i "s|{{S3_BUCKET}}|${S3_DATA_BUCKET}|g" /tmp/user-data.sh
    sed -i "s|{{TRAINING_JOB_NAME}}|${LATEST_TRAINING_JOB}|g" /tmp/user-data.sh
    sed -i "s|{{AWS_REGION}}|${AWS_REGION}|g" /tmp/user-data.sh
    
    # Launch EC2 instance
    print_log -c "[ec2] " "Launching t3.micro instance for compilation..."
    INSTANCE_ID=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type t3.micro \
        --iam-instance-profile Name="$ROLE_NAME" \
        --associate-public-ip-address \
        --user-data file:///tmp/user-data.sh \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=EdgeTPU-Compiler},{Key=Project,Value=${PROJECT_NAME}}]" \
        --query "Instances[0].InstanceId" \
        --output text)
    
    rm -f /tmp/user-data.sh
    
    print_log -g "[ok] " "Instance launched: ${INSTANCE_ID}"
    print_log -y "[info] " "Instance will self-terminate after compilation (~3-5 minutes)"
    print_log -m "[Compiled Model] " "s3://${S3_DATA_BUCKET}/models/model_edgetpu_latest.tar.gz"
    
    # Save info
    echo "COMPILER_INSTANCE_ID=${INSTANCE_ID}" > /tmp/compiler_info.txt
    echo "COMPILED_MODEL_S3=s3://${S3_DATA_BUCKET}/models/model_edgetpu_latest.tar.gz" >> /tmp/compiler_info.txt
}

cleanup_edgetpu_compiler() {
    print_log -b "[cleanup] " "Cleaning up Edge TPU Compiler resources..."
    validate_inputs
    setup_aws_environment
    
    ROLE_NAME="EdgeTPUCompilerRole-${PROJECT_NAME}"
    
    # Terminate any running compiler instances
    print_log -c "[ec2] " "Checking for running compiler instances..."
    INSTANCE_IDS=$(aws ec2 describe-instances --filters "Name=tag:Project,Values=${PROJECT_NAME}" "Name=tag:Name,Values=EdgeTPU-Compiler" "Name=instance-state-name,Values=running,pending" --query "Reservations[].Instances[].InstanceId" --output text)
    
    if [ ! -z "$INSTANCE_IDS" ] && [ "$INSTANCE_IDS" != "None" ]; then
        print_log -c "[terminate] " "Terminating instances: ${INSTANCE_IDS}"
        aws ec2 terminate-instances --instance-ids $INSTANCE_IDS
        print_log -y "[wait] " "Waiting for instances to terminate..."
        aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS
    fi
    
    # Delete IAM role
    print_log -c "[iam] " "Deleting IAM role..."
    aws iam remove-role-from-instance-profile --instance-profile-name "$ROLE_NAME" --role-name "$ROLE_NAME" 2>/dev/null || true
    aws iam delete-instance-profile --instance-profile-name "$ROLE_NAME" 2>/dev/null || true
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "CompilerPolicy" 2>/dev/null || true
    aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true
    
    print_log -g "[ok] " "Edge TPU Compiler cleanup completed"
}

# Main execution
case "${1:-}" in
    setup)
        setup_edgetpu_compiler
        ;;
    cleanup)
        cleanup_edgetpu_compiler
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME"
        exit 1
        ;;
esac
