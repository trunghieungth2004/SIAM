---
title: "Build and Deploy Machine Learning Models with Amazon SageMaker CLI"
date: 2025-12-09
draft: false
---

## Overview

Amazon SageMaker is a fully managed machine learning service that enables developers and data scientists to build, train, and deploy machine learning models at scale.

In this workshop, you will learn how to use the AWS CLI to manage the complete machine learning lifecycle on Amazon SageMaker without using the AWS Management Console. You will prepare data, train models, deploy endpoints, and make predictions entirely through command-line automation.

By the end of this workshop, you will understand how to:
- Create and configure SageMaker execution roles via CLI
- Prepare and upload training data to S3
- Launch SageMaker training jobs with built-in algorithms
- Deploy trained models to real-time endpoints
- Invoke endpoints for predictions
- Monitor and manage model performance
- Clean up resources to avoid unnecessary costs

## Content

- Workshop overview
- Prerequisites
- Create IAM Role for SageMaker
- Prepare Training Data
- Upload Data to S3
- Create SageMaker Training Job
- Monitor Training Progress
- Deploy Model to Endpoint
- Test Endpoint with Predictions
- Clean up

---

## Prerequisites

Before starting this workshop, ensure you have:

1. **AWS Account** with appropriate permissions for SageMaker, S3, and IAM
2. **AWS CLI installed and configured** with credentials:
   ```bash
   aws configure
   ```
3. **Python 3.8+** installed with pip
4. **Basic understanding of machine learning concepts**
5. **jq** (JSON processor) for parsing AWS CLI outputs:
   ```bash
   sudo apt-get install jq  # Ubuntu/Debian
   brew install jq          # macOS
   ```
6. **scikit-learn** for data preparation:
   ```bash
   pip install scikit-learn pandas numpy
   ```

Verify your AWS CLI is configured:
```bash
aws sts get-caller-identity
```

---

## Step 1: Create IAM Role for SageMaker

### 1.1 Set Environment Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_NAME="sagemaker-workshop"
export ROLE_NAME="${PROJECT_NAME}-execution-role"
export BUCKET_NAME="${PROJECT_NAME}-data-$(date +%s)"
```

### 1.2 Create Trust Policy Document

```bash
cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "sagemaker.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
```

### 1.3 Create IAM Role

```bash
ROLE_ARN=$(aws iam create-role \
    --role-name $ROLE_NAME \
    --assume-role-policy-document file://trust-policy.json \
    --query 'Role.Arn' \
    --output text)

echo "Role ARN: $ROLE_ARN"
```

### 1.4 Attach Managed Policies

```bash
# Attach SageMaker full access
aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess

# Attach S3 full access
aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
```

### 1.5 Wait for Role Propagation

```bash
echo "Waiting for IAM role to propagate..."
sleep 10
```

---

## Step 2: Prepare Training Data

### 2.1 Create Sample Dataset (Iris Classification)

Create a Python script to generate training data:

```bash
cat > prepare_data.py << 'EOF'
import pandas as pd
from sklearn.datasets import load_iris
from sklearn.model_selection import train_test_split
import numpy as np

# Load iris dataset
iris = load_iris()
X = iris.data
y = iris.target

# Split data
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

# Combine features and labels (SageMaker format: label first, then features)
train_data = np.column_stack((y_train, X_train))
test_data = np.column_stack((y_test, X_test))

# Save as CSV (no headers for SageMaker built-in algorithms)
np.savetxt('train.csv', train_data, delimiter=',', fmt='%.4f')
np.savetxt('test.csv', test_data, delimiter=',', fmt='%.4f')

print("Training data shape:", train_data.shape)
print("Test data shape:", test_data.shape)
print("Files created: train.csv, test.csv")
EOF
```

### 2.2 Run Data Preparation Script

```bash
python3 prepare_data.py
```

### 2.3 Verify Generated Files

```bash
head -n 5 train.csv
wc -l train.csv test.csv
```

---

## Step 3: Upload Data to S3

### 3.1 Create S3 Bucket

```bash
aws s3 mb s3://$BUCKET_NAME --region $AWS_REGION

echo "Bucket created: $BUCKET_NAME"
```

### 3.2 Upload Training Data

```bash
aws s3 cp train.csv s3://$BUCKET_NAME/data/train/train.csv
aws s3 cp test.csv s3://$BUCKET_NAME/data/test/test.csv
```

### 3.3 Verify Upload

```bash
aws s3 ls s3://$BUCKET_NAME/data/ --recursive
```

### 3.4 Set S3 Paths

```bash
export TRAIN_DATA_PATH="s3://$BUCKET_NAME/data/train/"
export TEST_DATA_PATH="s3://$BUCKET_NAME/data/test/"
export OUTPUT_PATH="s3://$BUCKET_NAME/output/"
```

---

## Step 4: Create SageMaker Training Job

### 4.1 Get Built-in Algorithm Image URI

For XGBoost (multi-class classification):

```bash
# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# XGBoost container image (region-specific)
# Format: 683313688378.dkr.ecr.us-east-1.amazonaws.com/sagemaker-xgboost:1.5-1
TRAINING_IMAGE="683313688378.dkr.ecr.${AWS_REGION}.amazonaws.com/sagemaker-xgboost:1.5-1"

echo "Training Image: $TRAINING_IMAGE"
```

**Note:** For other regions, check the [SageMaker Docker Registry Paths](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-algo-docker-registry-paths.html).

### 4.2 Create Training Job Configuration

```bash
TRAINING_JOB_NAME="${PROJECT_NAME}-training-$(date +%Y%m%d-%H%M%S)"

cat > training-config.json << EOF
{
  "TrainingJobName": "$TRAINING_JOB_NAME",
  "RoleArn": "$ROLE_ARN",
  "AlgorithmSpecification": {
    "TrainingImage": "$TRAINING_IMAGE",
    "TrainingInputMode": "File"
  },
  "InputDataConfig": [
    {
      "ChannelName": "train",
      "DataSource": {
        "S3DataSource": {
          "S3DataType": "S3Prefix",
          "S3Uri": "$TRAIN_DATA_PATH",
          "S3DataDistributionType": "FullyReplicated"
        }
      },
      "ContentType": "text/csv"
    },
    {
      "ChannelName": "validation",
      "DataSource": {
        "S3DataSource": {
          "S3DataType": "S3Prefix",
          "S3Uri": "$TEST_DATA_PATH",
          "S3DataDistributionType": "FullyReplicated"
        }
      },
      "ContentType": "text/csv"
    }
  ],
  "OutputDataConfig": {
    "S3OutputPath": "$OUTPUT_PATH"
  },
  "ResourceConfig": {
    "InstanceType": "ml.m5.xlarge",
    "InstanceCount": 1,
    "VolumeSizeInGB": 10
  },
  "StoppingCondition": {
    "MaxRuntimeInSeconds": 3600
  },
  "HyperParameters": {
    "objective": "multi:softmax",
    "num_class": "3",
    "num_round": "100",
    "max_depth": "5",
    "eta": "0.2",
    "subsample": "0.8"
  }
}
EOF
```

### 4.3 Launch Training Job

```bash
aws sagemaker create-training-job \
    --cli-input-json file://training-config.json \
    --region $AWS_REGION

echo "Training job started: $TRAINING_JOB_NAME"
```

---

## Step 5: Monitor Training Progress

### 5.1 Check Training Job Status

```bash
aws sagemaker describe-training-job \
    --training-job-name $TRAINING_JOB_NAME \
    --region $AWS_REGION \
    --query 'TrainingJobStatus' \
    --output text
```

### 5.2 Wait for Training Completion

```bash
echo "Waiting for training job to complete..."

while true; do
    STATUS=$(aws sagemaker describe-training-job \
        --training-job-name $TRAINING_JOB_NAME \
        --region $AWS_REGION \
        --query 'TrainingJobStatus' \
        --output text)
    
    echo "Current status: $STATUS"
    
    if [ "$STATUS" = "Completed" ]; then
        echo "Training completed successfully!"
        break
    elif [ "$STATUS" = "Failed" ] || [ "$STATUS" = "Stopped" ]; then
        echo "Training job failed or stopped"
        aws sagemaker describe-training-job \
            --training-job-name $TRAINING_JOB_NAME \
            --region $AWS_REGION \
            --query 'FailureReason'
        exit 1
    fi
    
    sleep 30
done
```

### 5.3 Get Training Metrics

```bash
aws sagemaker describe-training-job \
    --training-job-name $TRAINING_JOB_NAME \
    --region $AWS_REGION \
    --query '{JobName:TrainingJobName,Status:TrainingJobStatus,TrainingTime:TrainingTimeInSeconds,BillableTime:BillableTimeInSeconds}'
```

### 5.4 Get Model Artifacts Location

```bash
MODEL_DATA=$(aws sagemaker describe-training-job \
    --training-job-name $TRAINING_JOB_NAME \
    --region $AWS_REGION \
    --query 'ModelArtifacts.S3ModelArtifacts' \
    --output text)

echo "Model artifacts: $MODEL_DATA"
```

---

## Step 6: Create SageMaker Model

### 6.1 Create Model from Training Job

```bash
MODEL_NAME="${PROJECT_NAME}-model-$(date +%Y%m%d-%H%M%S)"

aws sagemaker create-model \
    --model-name $MODEL_NAME \
    --primary-container "Image=$TRAINING_IMAGE,ModelDataUrl=$MODEL_DATA" \
    --execution-role-arn $ROLE_ARN \
    --region $AWS_REGION

echo "Model created: $MODEL_NAME"
```

### 6.2 Verify Model Creation

```bash
aws sagemaker describe-model \
    --model-name $MODEL_NAME \
    --region $AWS_REGION
```

---

## Step 7: Deploy Model to Endpoint

### 7.1 Create Endpoint Configuration

```bash
ENDPOINT_CONFIG_NAME="${PROJECT_NAME}-endpoint-config-$(date +%Y%m%d-%H%M%S)"

aws sagemaker create-endpoint-config \
    --endpoint-config-name $ENDPOINT_CONFIG_NAME \
    --production-variants \
        "VariantName=AllTraffic,ModelName=$MODEL_NAME,InstanceType=ml.m5.xlarge,InitialInstanceCount=1" \
    --region $AWS_REGION

echo "Endpoint configuration created: $ENDPOINT_CONFIG_NAME"
```

### 7.2 Create Endpoint

```bash
ENDPOINT_NAME="${PROJECT_NAME}-endpoint"

aws sagemaker create-endpoint \
    --endpoint-name $ENDPOINT_NAME \
    --endpoint-config-name $ENDPOINT_CONFIG_NAME \
    --region $AWS_REGION

echo "Endpoint creation initiated: $ENDPOINT_NAME"
```

### 7.3 Wait for Endpoint to be InService

```bash
echo "Waiting for endpoint to be in service (this may take 5-10 minutes)..."

while true; do
    STATUS=$(aws sagemaker describe-endpoint \
        --endpoint-name $ENDPOINT_NAME \
        --region $AWS_REGION \
        --query 'EndpointStatus' \
        --output text)
    
    echo "Current status: $STATUS"
    
    if [ "$STATUS" = "InService" ]; then
        echo "Endpoint is now in service!"
        break
    elif [ "$STATUS" = "Failed" ]; then
        echo "Endpoint creation failed"
        aws sagemaker describe-endpoint \
            --endpoint-name $ENDPOINT_NAME \
            --region $AWS_REGION \
            --query 'FailureReason'
        exit 1
    fi
    
    sleep 30
done
```

### 7.4 Get Endpoint Details

```bash
aws sagemaker describe-endpoint \
    --endpoint-name $ENDPOINT_NAME \
    --region $AWS_REGION
```

---

## Step 8: Test Endpoint with Predictions

### 8.1 Prepare Test Payload

```bash
# Create a test input (features from iris dataset)
# Example: sepal length, sepal width, petal length, petal width
cat > test_input.csv << 'EOF'
5.1,3.5,1.4,0.2
6.2,2.9,4.3,1.3
7.3,2.9,6.3,1.8
EOF
```

### 8.2 Invoke Endpoint for Predictions

```bash
aws sagemaker-runtime invoke-endpoint \
    --endpoint-name $ENDPOINT_NAME \
    --content-type text/csv \
    --body fileb://test_input.csv \
    --region $AWS_REGION \
    output.txt

echo "Predictions:"
cat output.txt
echo ""
```

**Expected output:** Class predictions (0, 1, or 2 representing Iris species)

### 8.3 Test Single Prediction

```bash
# Single prediction
echo "6.0,3.0,4.0,1.2" | aws sagemaker-runtime invoke-endpoint \
    --endpoint-name $ENDPOINT_NAME \
    --content-type text/csv \
    --body - \
    --region $AWS_REGION \
    single_prediction.txt

cat single_prediction.txt
echo ""
```

---

## Step 9: Monitor Endpoint Metrics

### 9.1 Get Endpoint Invocation Metrics

```bash
# Get invocation count from CloudWatch
aws cloudwatch get-metric-statistics \
    --namespace AWS/SageMaker \
    --metric-name Invocations \
    --dimensions Name=EndpointName,Value=$ENDPOINT_NAME Name=VariantName,Value=AllTraffic \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Sum \
    --region $AWS_REGION
```

### 9.2 Get Model Latency

```bash
aws cloudwatch get-metric-statistics \
    --namespace AWS/SageMaker \
    --metric-name ModelLatency \
    --dimensions Name=EndpointName,Value=$ENDPOINT_NAME Name=VariantName,Value=AllTraffic \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Average \
    --region $AWS_REGION
```

---

## Step 10: Update Endpoint (Bonus)

### 10.1 Create New Model Version

Train a new model with different hyperparameters and create a new model:

```bash
NEW_MODEL_NAME="${PROJECT_NAME}-model-v2-$(date +%Y%m%d-%H%M%S)"

# Assuming you have new model artifacts from another training job
aws sagemaker create-model \
    --model-name $NEW_MODEL_NAME \
    --primary-container "Image=$TRAINING_IMAGE,ModelDataUrl=$MODEL_DATA" \
    --execution-role-arn $ROLE_ARN \
    --region $AWS_REGION
```

### 10.2 Create New Endpoint Configuration

```bash
NEW_ENDPOINT_CONFIG="${PROJECT_NAME}-endpoint-config-v2-$(date +%Y%m%d-%H%M%S)"

aws sagemaker create-endpoint-config \
    --endpoint-config-name $NEW_ENDPOINT_CONFIG \
    --production-variants \
        "VariantName=AllTraffic,ModelName=$NEW_MODEL_NAME,InstanceType=ml.m5.xlarge,InitialInstanceCount=1" \
    --region $AWS_REGION
```

### 10.3 Update Endpoint (Zero-downtime)

```bash
aws sagemaker update-endpoint \
    --endpoint-name $ENDPOINT_NAME \
    --endpoint-config-name $NEW_ENDPOINT_CONFIG \
    --region $AWS_REGION

echo "Endpoint update initiated (zero-downtime deployment)"
```

---

## Step 11: Clean Up

### 11.1 Delete Endpoint

```bash
aws sagemaker delete-endpoint \
    --endpoint-name $ENDPOINT_NAME \
    --region $AWS_REGION

echo "Endpoint deleted"
```

### 11.2 Delete Endpoint Configurations

```bash
aws sagemaker delete-endpoint-config \
    --endpoint-config-name $ENDPOINT_CONFIG_NAME \
    --region $AWS_REGION

# If you created a second endpoint config
# aws sagemaker delete-endpoint-config \
#     --endpoint-config-name $NEW_ENDPOINT_CONFIG \
#     --region $AWS_REGION
```

### 11.3 Delete Models

```bash
aws sagemaker delete-model \
    --model-name $MODEL_NAME \
    --region $AWS_REGION

# If you created a second model
# aws sagemaker delete-model \
#     --model-name $NEW_MODEL_NAME \
#     --region $AWS_REGION
```

### 11.4 Delete S3 Bucket Contents

```bash
aws s3 rm s3://$BUCKET_NAME --recursive
aws s3 rb s3://$BUCKET_NAME
```

### 11.5 Delete IAM Role

```bash
# Detach policies
aws iam detach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess

aws iam detach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# Delete role
aws iam delete-role \
    --role-name $ROLE_NAME
```

### 11.6 Clean Up Local Files

```bash
rm -f trust-policy.json training-config.json prepare_data.py
rm -f train.csv test.csv test_input.csv output.txt single_prediction.txt
```

---

## Key Takeaways

### SageMaker CLI Proficiency
- Managed complete ML lifecycle using only AWS CLI commands
- Automated model training, deployment, and inference workflows
- Practiced using JSON configuration files for complex API calls

### Machine Learning Operations (MLOps)
- Demonstrated reproducible ML workflows through CLI automation
- Created training jobs with version-controlled hyperparameters
- Implemented zero-downtime model updates using endpoint configuration changes

### IAM and Security
- Created execution roles with least-privilege permissions
- Used trust policies to allow SageMaker service to assume roles
- Separated data access from compute permissions

### Data Management
- Prepared training data in SageMaker-compatible CSV format
- Organized S3 data structure for training, validation, and output
- Verified data uploads and training job inputs

### Built-in Algorithms
- Used SageMaker's XGBoost built-in algorithm without custom containers
- Configured hyperparameters for multi-class classification
- Understood regional container image URIs

### Model Deployment
- Created endpoint configurations for production deployment
- Deployed models to real-time inference endpoints
- Monitored endpoint status and waited for InService state

### Inference and Testing
- Invoked endpoints using sagemaker-runtime API
- Tested predictions with CSV payloads
- Understood content-type specifications for different data formats

### Monitoring and Observability
- Queried CloudWatch metrics for endpoint invocations and latency
- Monitored training job progress programmatically
- Practiced debugging with describe-* CLI commands

### Cost Optimization
- Used appropriate instance types (ml.m5.xlarge for training and inference)
- Set stopping conditions for training jobs to prevent runaway costs
- Implemented proper cleanup procedures to delete all billable resources

### Advanced Patterns
- Demonstrated endpoint updates without downtime
- Created multiple model versions for A/B testing capability
- Automated model artifacts retrieval from training jobs

This workshop provided comprehensive hands-on experience with SageMaker CLI, enabling full ML lifecycle automation from data preparation through model deployment and monitoring, all without using the AWS Console.
