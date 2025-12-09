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
    
    # Check for default VPC, create temporary one if needed
    DEFAULT_VPC=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query "Vpcs[0].VpcId" --output text)
    TEMP_VPC_CREATED=false
    
    if [ -z "$DEFAULT_VPC" ] || [ "$DEFAULT_VPC" = "None" ]; then
        print_log -y "[vpc] " "No default VPC found, creating temporary VPC..."
        TEMP_VPC_ID=$(aws ec2 create-vpc --cidr-block 10.99.0.0/16 --query Vpc.VpcId --output text)
        aws ec2 create-tags --resources $TEMP_VPC_ID --tags Key=Name,Value="temp-compiler-${PROJECT_NAME}" Key=Project,Value="${PROJECT_NAME}"
        aws ec2 modify-vpc-attribute --vpc-id $TEMP_VPC_ID --enable-dns-hostnames
        
        TEMP_SUBNET_ID=$(aws ec2 create-subnet --vpc-id $TEMP_VPC_ID --cidr-block 10.99.0.0/24 --query Subnet.SubnetId --output text)
        aws ec2 modify-subnet-attribute --subnet-id $TEMP_SUBNET_ID --map-public-ip-on-launch
        
        TEMP_IGW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --output text)
        aws ec2 attach-internet-gateway --vpc-id $TEMP_VPC_ID --internet-gateway-id $TEMP_IGW_ID
        
        TEMP_RT_ID=$(aws ec2 create-route-table --vpc-id $TEMP_VPC_ID --query RouteTable.RouteTableId --output text)
        aws ec2 create-route --route-table-id $TEMP_RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $TEMP_IGW_ID
        aws ec2 associate-route-table --subnet-id $TEMP_SUBNET_ID --route-table-id $TEMP_RT_ID
        
        TEMP_SG_ID=$(aws ec2 create-security-group --group-name "temp-compiler-sg" --description "Temp SG for compiler" --vpc-id $TEMP_VPC_ID --query GroupId --output text)
        aws ec2 authorize-security-group-egress --group-id $TEMP_SG_ID --protocol -1 --cidr 0.0.0.0/0 2>/dev/null || true
        
        print_log -y "[wait] " "Waiting for VPC to be fully available..."
        while true; do
            VPC_STATE=$(aws ec2 describe-vpcs --vpc-ids $TEMP_VPC_ID --query "Vpcs[0].State" --output text 2>/dev/null)
            if [ "$VPC_STATE" = "available" ]; then
                print_log -g "[ready] " "VPC is available"
                break
            fi
            sleep 2
        done
        
        TEMP_VPC_CREATED=true
        USE_SUBNET=$TEMP_SUBNET_ID
        USE_SG=$TEMP_SG_ID
    else
        USE_SUBNET=""
        USE_SG=""
    fi
    
    # Get Ubuntu AMI
    AMI_ID=$(aws ec2 describe-images --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" --output text)
    
    # Create user-data script
    cat > /tmp/user-data.sh << 'USERDATA_EOF'
#!/bin/bash
exec > >(tee /var/log/user-data.log)
exec 2>&1
set -e

MODEL_S3_URI="{{MODEL_S3_URI}}"
S3_BUCKET="{{S3_BUCKET}}"
TRAINING_JOB_NAME="{{TRAINING_JOB_NAME}}"
AWS_REGION="{{AWS_REGION}}"
INSTANCE_ID=$(ec2-metadata --instance-id 2>/dev/null | cut -d' ' -f2)
[ -z "$INSTANCE_ID" ] && INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

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

if [ ! -f "thresholds.json" ]; then
    echo "[ERROR] thresholds.json not found in archive"
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
tar -czf model_compiled.tar.gz model.tflite scaler.pkl thresholds.json features.txt
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
    if [ -n "$USE_SUBNET" ]; then
        INSTANCE_ID=$(aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --instance-type t3.micro \
            --iam-instance-profile Name="$ROLE_NAME" \
            --subnet-id "$USE_SUBNET" \
            --security-group-ids "$USE_SG" \
            --user-data file:///tmp/user-data.sh \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=EdgeTPU-Compiler},{Key=Project,Value=${PROJECT_NAME}},{Key=TempVPC,Value=true}]" \
            --query "Instances[0].InstanceId" \
            --output text)
    else
        INSTANCE_ID=$(aws ec2 run-instances \
            --image-id "$AMI_ID" \
            --instance-type t3.micro \
            --iam-instance-profile Name="$ROLE_NAME" \
            --associate-public-ip-address \
            --user-data file:///tmp/user-data.sh \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=EdgeTPU-Compiler},{Key=Project,Value=${PROJECT_NAME}}]" \
            --query "Instances[0].InstanceId" \
            --output text)
    fi
    
    rm -f /tmp/user-data.sh
    
    print_log -g "[ok] " "Instance launched: ${INSTANCE_ID}"
    print_log -y "[info] " "Instance will self-terminate after compilation (~3-5 minutes)"
    print_log -m "[Compiled Model] " "s3://${S3_DATA_BUCKET}/models/model_edgetpu_latest.tar.gz"
    
    # Validate compiled model
    print_log -c "[validate] " "Validating compiled model..."
    COMPILED_MODEL_S3="s3://${S3_DATA_BUCKET}/models/model_edgetpu_latest.tar.gz"
    
    # Wait a moment for S3 eventual consistency
    sleep 5
    
    if aws s3 ls "${COMPILED_MODEL_S3}" > /dev/null 2>&1; then
        # Download and verify contents
        aws s3 cp "${COMPILED_MODEL_S3}" /tmp/verify_model.tar.gz 2>/dev/null
        if tar -tzf /tmp/verify_model.tar.gz 2>/dev/null | grep -q "model.tflite"; then
            print_log -g "[ok] " "Compiled model validated successfully"
        else
            print_log -r "[error] " "Compiled model validation failed - model.tflite not found in archive"
            rm -f /tmp/verify_model.tar.gz
            return 1
        fi
        rm -f /tmp/verify_model.tar.gz
    else
        print_log -r "[error] " "Compiled model not found in S3"
        return 1
    fi
    
    # Save info
    echo "COMPILER_INSTANCE_ID=${INSTANCE_ID}" > /tmp/compiler_info.txt
    echo "COMPILED_MODEL_S3=${COMPILED_MODEL_S3}" >> /tmp/compiler_info.txt
    
    # Monitor instance with system console output
    print_log -y "[monitor] " "Monitoring compilation progress via EC2 system log..."
    LAST_OUTPUT_HASH=""
    
    while true; do
        STATE=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].State.Name" --output text 2>/dev/null)
        if [ "$STATE" = "terminated" ] || [ -z "$STATE" ] || [ "$STATE" = "None" ]; then
            print_log -g "[complete] " "Instance terminated - compilation finished"
            break
        fi
        
        # Get system console output (more reliable than get-console-output)
        CONSOLE_OUTPUT=$(aws ec2 get-console-output --instance-id $INSTANCE_ID --latest --output text 2>/dev/null || echo "")
        
        if [ ! -z "$CONSOLE_OUTPUT" ]; then
            # Use hash to detect new content efficiently
            OUTPUT_HASH=$(echo "$CONSOLE_OUTPUT" | md5sum | cut -d' ' -f1)
            if [ "$OUTPUT_HASH" != "$LAST_OUTPUT_HASH" ]; then
                # Extract and display user-data log entries (lines with timestamps or brackets)
                echo "$CONSOLE_OUTPUT" | grep -E '^\[|user-data' | tail -20
                LAST_OUTPUT_HASH="$OUTPUT_HASH"
            fi
        fi
        
        sleep 5
    done
    
    # Clean up temp VPC after instance terminates
    if [ "$TEMP_VPC_CREATED" = true ]; then
        print_log -y "[cleanup] " "Cleaning temp VPC..."
        
        print_log -c "[vpc] " "Deleting temporary VPC..."
        
        aws ec2 delete-security-group --group-id $TEMP_SG_ID 2>/dev/null || true
        while aws ec2 describe-security-groups --group-ids $TEMP_SG_ID 2>/dev/null | grep -q $TEMP_SG_ID; do sleep 2; done
        
        aws ec2 detach-internet-gateway --internet-gateway-id $TEMP_IGW_ID --vpc-id $TEMP_VPC_ID 2>/dev/null || true
        while aws ec2 describe-internet-gateways --internet-gateway-ids $TEMP_IGW_ID --query "InternetGateways[0].Attachments[0].State" --output text 2>/dev/null | grep -q attached; do sleep 2; done
        aws ec2 delete-internet-gateway --internet-gateway-id $TEMP_IGW_ID 2>/dev/null || true
        
        aws ec2 delete-subnet --subnet-id $TEMP_SUBNET_ID 2>/dev/null || true
        while aws ec2 describe-subnets --subnet-ids $TEMP_SUBNET_ID 2>/dev/null | grep -q $TEMP_SUBNET_ID; do sleep 2; done
        
        aws ec2 delete-route-table --route-table-id $TEMP_RT_ID 2>/dev/null || true
        while aws ec2 describe-route-tables --route-table-ids $TEMP_RT_ID 2>/dev/null | grep -q $TEMP_RT_ID; do sleep 2; done
        
        aws ec2 delete-vpc --vpc-id $TEMP_VPC_ID 2>/dev/null || true
        while aws ec2 describe-vpcs --vpc-ids $TEMP_VPC_ID 2>/dev/null | grep -q $TEMP_VPC_ID; do sleep 2; done
        
        print_log -g "[ok] " "Temporary VPC cleaned up"
    fi
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
    
    # Clean up any temp VPCs
    print_log -c "[vpc] " "Checking for temporary VPCs..."
    TEMP_VPCS=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=temp-compiler-${PROJECT_NAME}" --query "Vpcs[].VpcId" --output text)
    for VPC in $TEMP_VPCS; do
        if [ ! -z "$VPC" ] && [ "$VPC" != "None" ]; then
            print_log -c "[delete] " "Deleting temp VPC: $VPC"
            IGW=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" --query "InternetGateways[0].InternetGatewayId" --output text)
            SG=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=temp-compiler-sg" --query "SecurityGroups[0].GroupId" --output text)
            SUBNET=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query "Subnets[0].SubnetId" --output text)
            RT=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=association.main,Values=false" --query "RouteTables[0].RouteTableId" --output text)
            
            if [ ! -z "$SG" ] && [ "$SG" != "None" ]; then
                aws ec2 delete-security-group --group-id $SG 2>/dev/null || true
                while aws ec2 describe-security-groups --group-ids $SG 2>/dev/null | grep -q $SG; do sleep 2; done
            fi
            
            if [ ! -z "$IGW" ] && [ "$IGW" != "None" ]; then
                aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC 2>/dev/null || true
                while aws ec2 describe-internet-gateways --internet-gateway-ids $IGW --query "InternetGateways[0].Attachments[0].State" --output text 2>/dev/null | grep -q attached; do sleep 2; done
                aws ec2 delete-internet-gateway --internet-gateway-id $IGW 2>/dev/null || true
            fi
            
            if [ ! -z "$SUBNET" ] && [ "$SUBNET" != "None" ]; then
                aws ec2 delete-subnet --subnet-id $SUBNET 2>/dev/null || true
                while aws ec2 describe-subnets --subnet-ids $SUBNET 2>/dev/null | grep -q $SUBNET; do sleep 2; done
            fi
            
            if [ ! -z "$RT" ] && [ "$RT" != "None" ]; then
                aws ec2 delete-route-table --route-table-id $RT 2>/dev/null || true
                while aws ec2 describe-route-tables --route-table-ids $RT 2>/dev/null | grep -q $RT; do sleep 2; done
            fi
            
            aws ec2 delete-vpc --vpc-id $VPC 2>/dev/null || true
            while aws ec2 describe-vpcs --vpc-ids $VPC 2>/dev/null | grep -q $VPC; do sleep 2; done
        fi
    done
    
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
