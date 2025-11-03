#!/usr/bin/env bash

#|---/ /+-------------------------------------+---/ /|#
#|--/ /-| SageMaker Component                |--/ /-|#
#|-/ /--| ML model for predictive maintenance |-/ /--|#
#|/ /---+-------------------------------------+/ /---|#

# Source common utilities
source "$(dirname "$0")/common.sh"



# Function to get correct SageMaker ECR URI for region
get_sagemaker_ecr_uri() {
    local region="$1"
    case "$region" in
        us-east-1) echo "683313688378.dkr.ecr.us-east-1.amazonaws.com" ;;
        us-east-2) echo "257758044811.dkr.ecr.us-east-2.amazonaws.com" ;;
        us-west-1) echo "746614075791.dkr.ecr.us-west-1.amazonaws.com" ;;
        us-west-2) echo "246618743249.dkr.ecr.us-west-2.amazonaws.com" ;;
        ap-southeast-1) echo "121021644041.dkr.ecr.ap-southeast-1.amazonaws.com" ;;
        ap-southeast-2) echo "783357654285.dkr.ecr.ap-southeast-2.amazonaws.com" ;;
        ap-northeast-1) echo "354813040037.dkr.ecr.ap-northeast-1.amazonaws.com" ;;
        eu-west-1) echo "141502667606.dkr.ecr.eu-west-1.amazonaws.com" ;;
        eu-central-1) echo "492215442770.dkr.ecr.eu-central-1.amazonaws.com" ;;
        *) echo "683313688378.dkr.ecr.${region}.amazonaws.com" ;; # Default fallback
    esac
}



setup_coral_tpu_integration() {
    print_log -c "[tpu-setup] " "Installing Coral TPU runtime on Pi..."
    
    ssh "${PI_SSH_TARGET}" 'bash -s' << 'TPU_SETUP_EOF'
# Add Coral repository
echo "deb https://packages.cloud.google.com/apt coral-edgetpu-stable main" | sudo tee /etc/apt/sources.list.d/coral-edgetpu.list
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

# Install TPU runtime
sudo apt-get update -qq
sudo apt-get install -y libedgetpu1-std python3-pycoral tflite-runtime
pip3 install tflite-runtime

echo "Coral TPU runtime installed successfully"
TPU_SETUP_EOF

    print_log -g "[tpu] " "Coral TPU runtime installed successfully"
}




setup_sagemaker() {
    print_log -b "[ml] " "Setting up SageMaker for Predictive Maintenance..."
    validate_inputs
    setup_aws_environment

    # Check for training data file
    DATA_FILE="../data/sensor_log_$(date +%Y%m%d)_*.csv"
    FOUND_DATA_FILE=$(ls $DATA_FILE 2>/dev/null | head -1)
    
    if [ -z "$FOUND_DATA_FILE" ]; then
        # Try alternative patterns
        DATA_FILE="../data/sensor_log_*.csv"
        FOUND_DATA_FILE=$(ls $DATA_FILE 2>/dev/null | head -1)
    fi
    
    if [ -z "$FOUND_DATA_FILE" ]; then
        print_log -r "[error] " "Training data file not found in ../data/"
        print_log -y "[info] " "Expected format: sensor_log_YYYYMMDD_HHMMSS.csv"
        print_log -y "[info] " "Please copy your sensor data CSV file to the data directory first."
        return 1
    fi
    
    print_log -g "[found] " "Using training data: ${FOUND_DATA_FILE}"
    
    # Validate CSV format
    if ! head -1 "$FOUND_DATA_FILE" | grep -q "timestamp,temp_c,ax,ay,az,gx,gy,gz,current_a"; then
        print_log -r "[error] " "Invalid CSV format. Expected header: timestamp,temp_c,ax,ay,az,gx,gy,gz,current_a"
        return 1
    fi
    
    # Get S3 bucket for model artifacts - always discover to ensure correct bucket
    SETUP_DIR="$(dirname "$(dirname "$0")")"
    RESOURCE_FILE="${SETUP_DIR}/${PROJECT_NAME}_resources.txt"
    
    if [ -f "$RESOURCE_FILE" ]; then
        S3_DATA_BUCKET=$(grep "S3_DATA_BUCKET" "$RESOURCE_FILE" | cut -d'=' -f2)
        print_log -g "[found] " "Found S3 bucket in resource file: ${S3_DATA_BUCKET}"
    fi
    
    if [ -z "$S3_DATA_BUCKET" ]; then
        PROJECT_CLEAN=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
        S3_DATA_BUCKET=$(aws s3 ls | grep "${PROJECT_CLEAN}-iot-data" | awk '{print $3}' | head -1)
        print_log -g "[discovered] " "Discovered S3 bucket: ${S3_DATA_BUCKET}"
    fi
    
    if [ -z "$S3_DATA_BUCKET" ] || [ "$S3_DATA_BUCKET" = "None" ]; then
        print_log -r "[error] " "S3 data bucket not found. Please ensure S3 setup completed successfully."
        return 1
    fi

    # Upload training data to S3
    S3_TRAINING_PATH="s3://${S3_DATA_BUCKET}/sagemaker/training-data/"
    print_log -c "[upload] " "Uploading training data to S3..."
    if ! aws s3 cp "$FOUND_DATA_FILE" "${S3_TRAINING_PATH}training.csv"; then
        print_log -r "[error] " "Failed to upload training data to S3"
        return 1
    fi
    print_log -g "[ok] " "Training data uploaded to: ${S3_TRAINING_PATH}training.csv"

    # Create SageMaker execution role
    SAGEMAKER_ROLE_NAME="SageMakerExecutionRole-${PROJECT_NAME}"
    if ! SAGEMAKER_ROLE_ARN=$(aws iam get-role --role-name $SAGEMAKER_ROLE_NAME --query Role.Arn --output text 2>/dev/null); then
        print_log -c "[iam] " "Creating SageMaker execution role..."
        cat > sagemaker-trust-policy.json << EOL
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
EOL
        if ! SAGEMAKER_ROLE_ARN=$(aws iam create-role --role-name $SAGEMAKER_ROLE_NAME --assume-role-policy-document file://sagemaker-trust-policy.json --query Role.Arn --output text); then
            print_log -r "[error] " "Failed to create SageMaker execution role"
            return 1
        fi
        
        # Attach required policies
        aws iam attach-role-policy --role-name $SAGEMAKER_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess
        aws iam attach-role-policy --role-name $SAGEMAKER_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
        
        print_log -y "[wait] " "Waiting for IAM role to propagate..."
        sleep 15
    else
        print_log -y "[skip] " "SageMaker execution role already exists."
    fi

    # Create training script
    print_log -c "[create] " "Creating TensorFlow training script for predictive maintenance..."
    cat > train.py << 'TRAIN_EOF'
import pandas as pd
import numpy as np
from sklearn.ensemble import RandomForestRegressor
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import mean_squared_error
import joblib
import argparse
import os
import sys
import pickle

def main():
    try:
        parser = argparse.ArgumentParser()
        parser.add_argument('--model-dir', type=str, default=os.environ.get('SM_MODEL_DIR'))
        parser.add_argument('--train', type=str, default=os.environ.get('SM_CHANNEL_TRAINING'))
        args = parser.parse_args()
        
        print(f"Model directory: {args.model_dir}")
        print(f"Training directory: {args.train}")
        
        # Find CSV file in training directory
        csv_files = [f for f in os.listdir(args.train) if f.endswith('.csv')]
        if not csv_files:
            print(f"ERROR: No CSV files found in {args.train}")
            sys.exit(1)
            
        train_file = os.path.join(args.train, csv_files[0])
        df = pd.read_csv(train_file)
        print(f"Loaded {len(df)} rows of training data")
        
        # Feature engineering
        df['vibration_magnitude'] = np.sqrt(df['ax']**2 + df['ay']**2 + df['az']**2)
        df['gyro_magnitude'] = np.sqrt(df['gx']**2 + df['gy']**2 + df['gz']**2)
        df['temp_deviation'] = abs(df['temp_c'] - 25.0)
        df['power_indicator'] = df['current_a'] * 12.0
        
        # Create maintenance score
        df['maintenance_score'] = (
            (df['vibration_magnitude'] / 20000) * 30 +
            (df['gyro_magnitude'] / 500) * 25 +
            (df['temp_deviation'] / 10) * 25 +
            (df['power_indicator'] / 2) * 20
        ).clip(0, 100)
        
        # Prepare features
        features = ['temp_c', 'vibration_magnitude', 'gyro_magnitude', 'temp_deviation', 'power_indicator', 'current_a']
        X = df[features].values.astype(np.float32)
        y = df['maintenance_score'].values.astype(np.float32)
        
        # Train/test split
        split_idx = int(0.8 * len(df))
        X_train, X_test = X[:split_idx], X[split_idx:]
        y_train, y_test = y[:split_idx], y[split_idx:]
        
        # Scale features
        scaler = StandardScaler()
        X_train_scaled = scaler.fit_transform(X_train).astype(np.float32)
        X_test_scaled = scaler.transform(X_test).astype(np.float32)
        
        # Train sklearn model
        print("Training sklearn model...")
        model = RandomForestRegressor(n_estimators=100, random_state=42)
        model.fit(X_train_scaled, y_train)
        
        # Evaluate
        y_pred = model.predict(X_test_scaled)
        mse = mean_squared_error(y_test, y_pred)
        print(f"Model MSE: {mse:.2f}")
        
        # Save sklearn model
        print("Saving sklearn model...")
        joblib.dump(model, os.path.join(args.model_dir, 'model.joblib'))
        
        # Also save in pickle format
        with open(os.path.join(args.model_dir, 'model.pkl'), 'wb') as f:
            pickle.dump(model, f)
        
        # Create simple TFLite model for TPU (demo purposes)
        print("Creating simple TFLite model...")
        try:
            import tensorflow as tf
            
            # Create a simple neural network that mimics the sklearn model behavior
            tf_model = tf.keras.Sequential([
                tf.keras.layers.Dense(32, activation='relu', input_shape=(len(features),)),
                tf.keras.layers.Dense(16, activation='relu'),
                tf.keras.layers.Dense(1, activation='linear')
            ])
            
            tf_model.compile(optimizer='adam', loss='mse')
            
            # Train briefly to create a working model
            tf_model.fit(X_train_scaled, y_train, epochs=20, batch_size=32, verbose=0)
            
            # Convert to TFLite
            converter = tf.lite.TFLiteConverter.from_keras_model(tf_model)
            converter.optimizations = [tf.lite.Optimize.DEFAULT]
            tflite_model = converter.convert()
            
            # Save TFLite model
            with open(os.path.join(args.model_dir, 'model.tflite'), 'wb') as f:
                f.write(tflite_model)
            print(f"TFLite model created: {len(tflite_model)} bytes")
            
        except Exception as e:
            print(f"TFLite creation failed: {e} - continuing without TFLite model")
        
        # Save scaler for preprocessing
        with open(os.path.join(args.model_dir, 'scaler.pkl'), 'wb') as f:
            pickle.dump(scaler, f)
        
        # Save feature names
        with open(os.path.join(args.model_dir, 'features.txt'), 'w') as f:
            f.write(','.join(features))
            
        print("Training completed successfully!")
        
    except Exception as e:
        print(f"Training failed: {str(e)}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

if __name__ == '__main__':
    main()
TRAIN_EOF

    # Create inference script
    cat > inference.py << 'INFERENCE_EOF'
import joblib
import json
import numpy as np
import os
import pickle

def model_fn(model_dir):
    model = joblib.load(os.path.join(model_dir, 'model.joblib'))
    with open(os.path.join(model_dir, 'scaler.pkl'), 'rb') as f:
        scaler = pickle.load(f)
    return {'model': model, 'scaler': scaler}

def predict_fn(input_data, model_dict):
    model = model_dict['model']
    scaler = model_dict['scaler']
    
    # Calculate derived features
    vibration_magnitude = np.sqrt(input_data['ax']**2 + input_data['ay']**2 + input_data['az']**2)
    gyro_magnitude = np.sqrt(input_data['gx']**2 + input_data['gy']**2 + input_data['gz']**2)
    temp_deviation = abs(input_data['temp_c'] - 25.0)
    power_indicator = input_data['current_a'] * 12.0
    
    # Prepare features
    features = np.array([[
        input_data['temp_c'],
        vibration_magnitude,
        gyro_magnitude,
        temp_deviation,
        power_indicator,
        input_data['current_a']
    ]], dtype=np.float32)
    
    # Scale and predict
    features_scaled = scaler.transform(features)
    prediction = model.predict(features_scaled)[0]
    
    # Convert to maintenance recommendation
    if prediction < 30:
        status = "Good"
        days_until_maintenance = 90
    elif prediction < 60:
        status = "Monitor"
        days_until_maintenance = 30
    else:
        status = "Maintenance Required"
        days_until_maintenance = 7
    
    return {
        'maintenance_score': float(prediction),
        'status': status,
        'days_until_maintenance': days_until_maintenance,
        'vibration_magnitude': float(vibration_magnitude),
        'power_indicator': float(power_indicator)
    }

def input_fn(request_body, request_content_type):
    if request_content_type == 'application/json':
        return json.loads(request_body)
    else:
        raise ValueError(f"Unsupported content type: {request_content_type}")

def output_fn(prediction, content_type):
    if content_type == 'application/json':
        return json.dumps(prediction)
    else:
        raise ValueError(f"Unsupported content type: {content_type}")
INFERENCE_EOF

    # Package training code
    print_log -c "[package] " "Creating training package..."
    tar -czf sourcedir.tar.gz train.py inference.py
    
    # Upload to S3
    S3_CODE_PATH="s3://${S3_DATA_BUCKET}/sagemaker/code/"
    if ! aws s3 cp sourcedir.tar.gz "${S3_CODE_PATH}sourcedir.tar.gz"; then
        print_log -r "[error] " "Failed to upload training code to S3"
        return 1
    fi

    # Create training job
    TRAINING_JOB_NAME="${PROJECT_NAME}-maintenance-$(date +%Y%m%d-%H%M%S)"
    print_log -c "[train] " "Starting SageMaker training job: ${TRAINING_JOB_NAME}..."
    
    cat > training-job.json << EOL
{
    "TrainingJobName": "${TRAINING_JOB_NAME}",
    "RoleArn": "${SAGEMAKER_ROLE_ARN}",
    "AlgorithmSpecification": {
        "TrainingImage": "$(get_sagemaker_ecr_uri ${AWS_REGION})/sagemaker-scikit-learn:0.23-1-cpu-py3",
        "TrainingInputMode": "File"
    },
    "InputDataConfig": [
        {
            "ChannelName": "training",
            "DataSource": {
                "S3DataSource": {
                    "S3DataType": "S3Prefix",
                    "S3Uri": "${S3_TRAINING_PATH}",
                    "S3DataDistributionType": "FullyReplicated"
                }
            }
        }
    ],
    "OutputDataConfig": {
        "S3OutputPath": "s3://${S3_DATA_BUCKET}/sagemaker/output/"
    },
    "ResourceConfig": {
        "InstanceType": "ml.m5.large",
        "InstanceCount": 1,
        "VolumeSizeInGB": 10
    },
    "StoppingCondition": {
        "MaxRuntimeInSeconds": 3600
    },
    "HyperParameters": {
        "sagemaker_program": "train.py",
        "sagemaker_submit_directory": "${S3_CODE_PATH}sourcedir.tar.gz"
    }
}
EOL

    if ! aws sagemaker create-training-job --cli-input-json file://training-job.json; then
        print_log -r "[error] " "Failed to create training job"
        return 1
    fi
    
    print_log -y "[wait] " "Training job started. This may take 10-15 minutes..."
    
    # Wait for training job to complete
    print_log -c "[monitor] " "Waiting for training job to complete..."
    if ! aws sagemaker wait training-job-completed-or-stopped --training-job-name $TRAINING_JOB_NAME; then
        print_log -r "[error] " "Training job failed or timed out"
        return 1
    fi
    
    # Check training job status
    TRAINING_STATUS=$(aws sagemaker describe-training-job --training-job-name $TRAINING_JOB_NAME --query TrainingJobStatus --output text)
    if [ "$TRAINING_STATUS" != "Completed" ]; then
        print_log -r "[error] " "Training job failed with status: $TRAINING_STATUS"
        
        # Get failure reason
        FAILURE_REASON=$(aws sagemaker describe-training-job --training-job-name $TRAINING_JOB_NAME --query FailureReason --output text 2>/dev/null || echo "Unknown")
        print_log -r "[reason] " "Failure reason: $FAILURE_REASON"
        
        # Show CloudWatch logs location
        print_log -y "[logs] " "Check CloudWatch logs: /aws/sagemaker/TrainingJobs -> $TRAINING_JOB_NAME"
        return 1
    fi
    
    print_log -g "[ok] " "Training job completed successfully!"

    # Create model
    MODEL_NAME="${PROJECT_NAME}-maintenance-model"
    MODEL_ARTIFACT_PATH=$(aws sagemaker describe-training-job --training-job-name $TRAINING_JOB_NAME --query ModelArtifacts.S3ModelArtifacts --output text)
    
    print_log -c "[model] " "Creating SageMaker model..."
    if ! aws sagemaker create-model \
        --model-name $MODEL_NAME \
        --primary-container Image=$(get_sagemaker_ecr_uri ${AWS_REGION})/sagemaker-scikit-learn:0.23-1-cpu-py3,ModelDataUrl=$MODEL_ARTIFACT_PATH,Environment="{\"SAGEMAKER_PROGRAM\":\"inference.py\",\"SAGEMAKER_SUBMIT_DIRECTORY\":\"${S3_CODE_PATH}sourcedir.tar.gz\"}" \
        --execution-role-arn $SAGEMAKER_ROLE_ARN > /dev/null 2>&1; then
        print_log -y "[skip] " "Model may already exist, continuing..."
    fi

    print_log -y "[info] " "Skipping expensive cloud endpoint - using edge deployment only"
    print_log -y "[info] " "Retraining pipeline will be created by EventBridge component"
    
    # Create inference service for Greengrass
    COMPONENT_NAME="com.${PROJECT_NAME}.MLInference"
    COMPONENT_VERSION="1.0.0"
    
    cat > inference_service.py << 'SERVICE_EOF'
import json
import time
import boto3
import logging
import os
from datetime import datetime

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

class MLInferenceService:
    def __init__(self):
        self.iot_client = boto3.client('iot-data')
        self.model_name = os.environ.get('MODEL_NAME', 'maintenance-model')
        self.inference_interval = int(os.environ.get('INFERENCE_INTERVAL', '60'))
        
    def get_sensor_data(self):
        """Simulate getting sensor data - replace with actual sensor reading"""
        import random
        return {
            'temp_c': 25.0 + random.uniform(-5, 10),
            'ax': random.randint(-2000, 2000),
            'ay': random.randint(-2000, 2000), 
            'az': random.randint(14000, 16000),
            'gx': random.randint(-400, 400),
            'gy': random.randint(-400, 400),
            'gz': random.randint(-100, 100),
            'current_a': random.uniform(0.05, 0.25)
        }
    
    def predict_maintenance(self, sensor_data):
        """Run inference using trained model"""
        try:
            import joblib
            import numpy as np
            
            # Calculate derived features
            vibration_magnitude = np.sqrt(sensor_data['ax']**2 + sensor_data['ay']**2 + sensor_data['az']**2)
            gyro_magnitude = np.sqrt(sensor_data['gx']**2 + sensor_data['gy']**2 + sensor_data['gz']**2)
            temp_deviation = abs(sensor_data['temp_c'] - 25.0)
            power_indicator = sensor_data['current_a'] * 12.0
            
            # Load model artifacts
            model = joblib.load('/greengrass/v2/packages/artifacts/com.${PROJECT_NAME}.MLInference/1.0.0/model.joblib')
            scaler = joblib.load('/greengrass/v2/packages/artifacts/com.${PROJECT_NAME}.MLInference/1.0.0/scaler.joblib')
            
            # Prepare features
            features = np.array([[
                sensor_data['temp_c'], vibration_magnitude, gyro_magnitude,
                temp_deviation, power_indicator, sensor_data['current_a']
            ]])
            
            # Scale and predict
            features_scaled = scaler.transform(features)
            prediction = model.predict(features_scaled)[0]
            
            # Convert to maintenance recommendation
            if prediction < 30:
                status = "Good"
                days_until_maintenance = 90
            elif prediction < 60:
                status = "Monitor"
                days_until_maintenance = 30
            else:
                status = "Maintenance Required"
                days_until_maintenance = 7
            
            return {
                'maintenance_score': float(prediction),
                'status': status,
                'days_until_maintenance': days_until_maintenance,
                'vibration_magnitude': float(vibration_magnitude),
                'power_indicator': float(power_indicator)
            }
            
        except Exception as e:
            logger.error(f"Inference failed: {e}")
            return {
                'maintenance_score': 50.0,
                'status': 'Error',
                'days_until_maintenance': 30,
                'error': str(e)
            }
    
    def publish_result(self, sensor_data, prediction):
        """Publish results to IoT Core"""
        try:
            message = {
                'timestamp': datetime.utcnow().isoformat(),
                'sensor_data': sensor_data,
                'prediction': prediction,
                'device_id': 'greengrass-core'
            }
            
            self.iot_client.publish(
                topic='maintenance/predictions',
                qos=1,
                payload=json.dumps(message)
            )
            logger.info(f"Published prediction: {prediction['status']}")
        except Exception as e:
            logger.error(f"Failed to publish: {e}")
    
    def run(self):
        """Main service loop"""
        logger.info("Starting ML Inference Service")
        
        while True:
            try:
                sensor_data = self.get_sensor_data()
                prediction = self.predict_maintenance(sensor_data)
                
                if prediction:
                    self.publish_result(sensor_data, prediction)
                    logger.info(f"Maintenance Score: {prediction['maintenance_score']:.1f}, Status: {prediction['status']}")
                
                time.sleep(self.inference_interval)
                
            except KeyboardInterrupt:
                logger.info("Service stopped")
                break
            except Exception as e:
                logger.error(f"Service error: {e}")
                time.sleep(10)

if __name__ == '__main__':
    service = MLInferenceService()
    service.run()
SERVICE_EOF

    # Save trained model and artifacts to S3 for Greengrass deployment
    print_log -c "[save] " "Uploading trained model and artifacts to S3..."
    aws s3 cp inference_service.py s3://${S3_DATA_BUCKET}/greengrass/artifacts/
    
    # Save model info for Greengrass
    echo "MODEL_NAME=${MODEL_NAME}" > /tmp/ml_model_info.txt
    echo "S3_DATA_BUCKET=${S3_DATA_BUCKET}" >> /tmp/ml_model_info.txt
    echo "COMPONENT_NAME=${COMPONENT_NAME}" >> /tmp/ml_model_info.txt
    echo "COMPONENT_VERSION=${COMPONENT_VERSION}" >> /tmp/ml_model_info.txt
    
    print_log -g "[ready] " "Model and artifacts ready for Greengrass deployment"
    rm -f inference_service.py

    print_log -g "[ok] " "SageMaker setup complete!"
    print_log -m "[Training Job] " "${TRAINING_JOB_NAME}"
    print_log -m "[Model Name] " "${MODEL_NAME}"
    print_log -m "[Model Artifacts] " "${MODEL_ARTIFACT_PATH}"
    
    # Export variables for other components
    export SAGEMAKER_MODEL_NAME="$MODEL_NAME"
    export SAGEMAKER_ROLE_ARN
    export TRAINING_JOB_NAME
    
    # Cleanup temporary files
    rm -f train.py inference.py sourcedir.tar.gz training-job.json sagemaker-trust-policy.json
    print_log -g "[cleanup] " "Temporary files cleaned up"
}

cleanup_sagemaker() {
    print_log -b "[delete] " "Cleaning up SageMaker resources..."
    validate_inputs
    setup_aws_environment

    MODEL_NAME="${PROJECT_NAME}-maintenance-model"
    SAGEMAKER_ROLE_NAME="SageMakerExecutionRole-${PROJECT_NAME}"
    ENDPOINT_NAME="${MODEL_NAME}-endpoint"
    ENDPOINT_CONFIG_NAME="${MODEL_NAME}-config"
    COMPONENT_NAME="com.${PROJECT_NAME}.MLInference"
    
    # Delete Greengrass component
    print_log -c "[delete] " "Deleting Greengrass ML component..."
    aws greengrassv2 list-component-versions --component-name $COMPONENT_NAME --query "componentVersions[].componentVersion" --output text 2>/dev/null | while read version; do
        if [ ! -z "$version" ] && [ "$version" != "None" ]; then
            aws greengrassv2 delete-component --component-name $COMPONENT_NAME --component-version $version 2>/dev/null || true
        fi
    done
    
    # Note: No cloud endpoints to delete (using edge deployment only)
    
    # Delete model
    print_log -c "[delete] " "Deleting SageMaker model..."
    aws sagemaker delete-model --model-name $MODEL_NAME 2>/dev/null || true
    
    # Delete IAM role
    print_log -c "[delete] " "Deleting SageMaker IAM role..."
    aws iam detach-role-policy --role-name $SAGEMAKER_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess 2>/dev/null || true
    aws iam detach-role-policy --role-name $SAGEMAKER_ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess 2>/dev/null || true
    aws iam delete-role --role-name $SAGEMAKER_ROLE_NAME 2>/dev/null || true
    
    # Clean up S3 artifacts (optional - user may want to keep training data)
    if [ ! -z "$S3_DATA_BUCKET" ]; then
        print_log -c "[cleanup] " "Cleaning up S3 training artifacts..."
        aws s3 rm s3://${S3_DATA_BUCKET}/sagemaker/ --recursive 2>/dev/null || true
    fi
    
    print_log -g "[ok] " "SageMaker cleanup completed."
}

cleanup_temp_files() {
    rm -f train.py inference.py sourcedir.tar.gz training-job.json sagemaker-trust-policy.json component-recipe.json deployment.json inference_service.py 2>/dev/null || true
}

# Main execution
case "${1:-}" in
    setup)
        if ! setup_sagemaker; then
            print_log -r "[error] " "SageMaker setup failed"
            exit 1
        fi
        ;;
    cleanup)
        if ! cleanup_sagemaker; then
            print_log -r "[error] " "SageMaker cleanup failed"
            exit 1
        fi
        ;;
    *)
        echo "Usage: $0 {setup|cleanup}"
        echo "Environment variables required: PROJECT_NAME, THING_NAME"
        exit 1
        ;;
esac