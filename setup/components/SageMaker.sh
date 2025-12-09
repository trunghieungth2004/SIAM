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

    # Get absolute path to data directory
    SETUP_DIR="$(dirname "$(dirname "$0")")"
    DATA_DIR="${SETUP_DIR}/data"
    
    # Create data directory if it doesn't exist
    mkdir -p "$DATA_DIR"
    
    # First, check for training data file in local data directory
    FOUND_DATA_FILE=$(ls -t "${DATA_DIR}"/sensor_log_*.csv 2>/dev/null | head -1)
    
    # If no local data found and PI_SSH_TARGET is set, try to fetch from Pi
    if [ -z "$FOUND_DATA_FILE" ] && [ ! -z "$PI_SSH_TARGET" ]; then
        print_log -c "[fetch] " "No local data found. Checking for training data on Raspberry Pi..."
        
        # Check if CSV files exist on Pi
        PI_CSV_COUNT=$(ssh "$PI_SSH_TARGET" "ls -1 ~/local_datalogger/sensor_log_*.csv 2>/dev/null | wc -l" 2>/dev/null || echo "0")
        
        if [ "$PI_CSV_COUNT" -gt 0 ]; then
            print_log -g "[found] " "Found $PI_CSV_COUNT CSV file(s) on Pi"
            
            # Get the most recent CSV file
            PI_LATEST_CSV=$(ssh "$PI_SSH_TARGET" "ls -t ~/local_datalogger/sensor_log_*.csv 2>/dev/null | head -1" 2>/dev/null)
            
            if [ ! -z "$PI_LATEST_CSV" ]; then
                print_log -c "[scp] " "Copying training data from Pi: $PI_LATEST_CSV"
                
                # SCP the file to local data directory
                if scp "${PI_SSH_TARGET}:${PI_LATEST_CSV}" "${DATA_DIR}/"; then
                    print_log -g "[ok] " "Training data copied successfully"
                    # Re-check for the file after copy
                    FOUND_DATA_FILE=$(ls -t "${DATA_DIR}"/sensor_log_*.csv 2>/dev/null | head -1)
                else
                    print_log -r "[error] " "Failed to copy training data from Pi"
                    return 1
                fi
            fi
        else
            print_log -y "[info] " "No CSV files found on Pi at ~/local_datalogger/"
        fi
    elif [ ! -z "$FOUND_DATA_FILE" ]; then
        print_log -g "[found] " "Using existing local training data: ${FOUND_DATA_FILE}"
    fi
    
    if [ -z "$FOUND_DATA_FILE" ]; then
        print_log -r "[error] " "Training data file not found in ${DATA_DIR}/"
        print_log -y "[info] " "Expected format: sensor_log_YYYYMMDD_HHMMSS.csv"
        if [ -z "$PI_SSH_TARGET" ]; then
            print_log -y "[info] " "Set PI_SSH_TARGET or copy your sensor data CSV file to the data directory first."
        else
            print_log -y "[info] " "No sensor data found on Pi. Please collect data first using local datalogger."
        fi
        return 1
    fi
    
    print_log -g "[found] " "Using training data: ${FOUND_DATA_FILE}"
    
    # Validate CSV format
    if ! head -1 "$FOUND_DATA_FILE" | grep -q "timestamp,temp_c,ax,ay,az,gx,gy,gz,current_a"; then
        print_log -r "[error] " "Invalid CSV format. Expected header: timestamp,temp_c,ax,ay,az,gx,gy,gz,current_a"
        return 1
    fi
    
    # Count rows for validation
    ROW_COUNT=$(wc -l < "$FOUND_DATA_FILE")
    ROW_COUNT=$((ROW_COUNT - 1)) # Subtract header row
    
    if [ "$ROW_COUNT" -lt 100 ]; then
        print_log -y "[warn] " "Training data has only $ROW_COUNT rows. Recommend at least 100 samples for reliable training."
        print_log -y "[warn] " "Training will continue but model quality may be poor."
    else
        print_log -g "[ok] " "Training data contains $ROW_COUNT samples"
    fi
    
    # Get S3 bucket for model artifacts - always discover to ensure correct bucket
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
    
    # Create timestamped backup in S3
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    BACKUP_FILENAME="training-${TIMESTAMP}.csv"
    
    print_log -c "[upload] " "Uploading training data to S3..."
    
    # Upload with backup (versioned)
    if ! aws s3 cp "$FOUND_DATA_FILE" "${S3_TRAINING_PATH}${BACKUP_FILENAME}"; then
        print_log -r "[error] " "Failed to upload training data to S3"
        return 1
    fi
    print_log -g "[ok] " "Training data backed up to: ${S3_TRAINING_PATH}${BACKUP_FILENAME}"
    
    # Also upload as training.csv for SageMaker to use
    if ! aws s3 cp "$FOUND_DATA_FILE" "${S3_TRAINING_PATH}training.csv"; then
        print_log -r "[error] " "Failed to upload training.csv to S3"
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
    print_log -c "[create] " "Creating autoencoder training script for anomaly detection..."
    cat > train.py << 'TRAIN_EOF'
import pandas as pd
import numpy as np
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import mean_squared_error
import argparse
import os
import sys
import pickle
import json

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
        print(f"Loaded {len(df)} rows of training data (normal operation data)")
        
        # Feature engineering - same features as before for consistency
        df['vibration_magnitude'] = np.sqrt(df['ax']**2 + df['ay']**2 + df['az']**2)
        df['gyro_magnitude'] = np.sqrt(df['gx']**2 + df['gy']**2 + df['gz']**2)
        df['temp_deviation'] = abs(df['temp_c'] - 25.0)
        df['power_indicator'] = df['current_a'] * 12.0
        
        # Prepare features - AUTOENCODER LEARNS TO RECONSTRUCT THESE
        features = ['temp_c', 'vibration_magnitude', 'gyro_magnitude', 'temp_deviation', 'power_indicator', 'current_a']
        X = df[features].values.astype(np.float32)
        
        print(f"Training autoencoder on {len(X)} normal operation samples")
        print(f"Feature dimensions: {X.shape[1]}")
        
        # Train/test split
        split_idx = int(0.8 * len(df))
        X_train, X_test = X[:split_idx], X[split_idx:]
        
        # Scale features
        scaler = StandardScaler()
        X_train_scaled = scaler.fit_transform(X_train).astype(np.float32)
        X_test_scaled = scaler.transform(X_test).astype(np.float32)
        
        # Build Autoencoder for Edge TPU
        print("Building autoencoder architecture...")
        import tensorflow as tf
        
        input_dim = len(features)
        encoding_dim = 3  # Compressed bottleneck - forces model to learn essential patterns
        
        # Encoder
        inputs = tf.keras.Input(shape=(input_dim,))
        encoded = tf.keras.layers.Dense(16, activation='relu')(inputs)
        encoded = tf.keras.layers.Dense(8, activation='relu')(encoded)
        encoded = tf.keras.layers.Dense(encoding_dim, activation='relu', name='bottleneck')(encoded)
        
        # Decoder
        decoded = tf.keras.layers.Dense(8, activation='relu')(encoded)
        decoded = tf.keras.layers.Dense(16, activation='relu')(decoded)
        decoded = tf.keras.layers.Dense(input_dim, activation='linear')(decoded)
        
        # Autoencoder model
        autoencoder = tf.keras.Model(inputs=inputs, outputs=decoded)
        
        autoencoder.compile(
            optimizer=tf.keras.optimizers.Adam(learning_rate=0.001),
            loss='mse',  # Reconstruction error
            metrics=['mae']
        )
        
        print("\nAutoencoder architecture:")
        autoencoder.summary()
        
        # Train autoencoder on NORMAL data only
        print("\nTraining autoencoder on normal operating patterns...")
        history = autoencoder.fit(
            X_train_scaled,
            X_train_scaled,  # Target = input (reconstruction)
            epochs=100,
            batch_size=32,
            validation_split=0.2,
            verbose=1
        )
        
        # Evaluate reconstruction error on test set
        X_test_reconstructed = autoencoder.predict(X_test_scaled)
        reconstruction_errors = np.mean(np.square(X_test_scaled - X_test_reconstructed), axis=1)
        
        # Calculate anomaly thresholds based on reconstruction error distribution
        threshold_95 = np.percentile(reconstruction_errors, 95)
        threshold_99 = np.percentile(reconstruction_errors, 99)
        mean_error = np.mean(reconstruction_errors)
        std_error = np.std(reconstruction_errors)
        
        print(f"\nReconstruction Error Statistics (Normal Data):")
        print(f"  Mean: {mean_error:.6f}")
        print(f"  Std: {std_error:.6f}")
        print(f"  95th percentile: {threshold_95:.6f}")
        print(f"  99th percentile: {threshold_99:.6f}")
        
        # Save thresholds for inference
        thresholds = {
            'mean': float(mean_error),
            'std': float(std_error),
            'threshold_95': float(threshold_95),
            'threshold_99': float(threshold_99),
            'threshold_warning': float(threshold_95),  # Warning threshold
            'threshold_critical': float(threshold_99)  # Critical threshold
        }
        
        # Convert to TFLite with INT8 quantization for Edge TPU
        print("\nConverting to TFLite with INT8 quantization for Edge TPU...")
        
        def representative_dataset():
            for i in range(min(100, len(X_train_scaled))):
                yield [X_train_scaled[i:i+1].astype(np.float32)]
        
        converter = tf.lite.TFLiteConverter.from_keras_model(autoencoder)
        converter.optimizations = [tf.lite.Optimize.DEFAULT]
        converter.representative_dataset = representative_dataset
        converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
        converter.inference_input_type = tf.uint8
        converter.inference_output_type = tf.uint8
        tflite_model = converter.convert()
        
        with open(os.path.join(args.model_dir, 'model.tflite'), 'wb') as f:
            f.write(tflite_model)
        print(f"TFLite autoencoder model created: {len(tflite_model)} bytes")
        
        # Save scaler and thresholds
        with open(os.path.join(args.model_dir, 'scaler.pkl'), 'wb') as f:
            pickle.dump(scaler, f)
        
        with open(os.path.join(args.model_dir, 'thresholds.json'), 'w') as f:
            json.dump(thresholds, f, indent=2)
        
        with open(os.path.join(args.model_dir, 'features.txt'), 'w') as f:
            f.write(','.join(features))
        
        print("\n" + "="*60)
        print("AUTOENCODER TRAINING COMPLETED SUCCESSFULLY")
        print("="*60)
        print(f"Model type: Autoencoder for Anomaly Detection")
        print(f"Input features: {len(features)}")
        print(f"Encoding dimension: {encoding_dim}")
        print(f"Anomaly detection: Reconstruction error thresholding")
        print("="*60)
        
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
import json
import numpy as np
import os
import pickle
import tflite_runtime.interpreter as tflite

def model_fn(model_dir):
    """Loads the TFLite autoencoder model, scaler, and thresholds."""
    interpreter = tflite.Interpreter(model_path=os.path.join(model_dir, 'model.tflite'))
    interpreter.allocate_tensors()
    with open(os.path.join(model_dir, 'scaler.pkl'), 'rb') as f:
        scaler = pickle.load(f)
    with open(os.path.join(model_dir, 'thresholds.json'), 'r') as f:
        thresholds = json.load(f)
    return {'interpreter': interpreter, 'scaler': scaler, 'thresholds': thresholds}

def predict_fn(input_data, model_dict):
    """Runs anomaly detection using autoencoder reconstruction error."""
    interpreter = model_dict['interpreter']
    scaler = model_dict['scaler']
    thresholds = model_dict['thresholds']
    
    # Calculate derived features
    vibration_magnitude = np.sqrt(input_data['ax']**2 + input_data['ay']**2 + input_data['az']**2)
    gyro_magnitude = np.sqrt(input_data['gx']**2 + input_data['gy']**2 + input_data['gz']**2)
    temp_deviation = abs(input_data['temp_c'] - 25.0)
    power_indicator = input_data['current_a'] * 12.0
    
    # Prepare features in exact training order
    features = np.array([[
        input_data['temp_c'],
        vibration_magnitude,
        gyro_magnitude,
        temp_deviation,
        power_indicator,
        input_data['current_a']
    ]], dtype=np.float32)
    
    # Scale features
    features_scaled = scaler.transform(features)
    
    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()
    
    # Run autoencoder to get reconstruction
    interpreter.set_tensor(input_details[0]['index'], features_scaled)
    interpreter.invoke()
    
    # Get reconstructed output
    reconstructed = interpreter.get_tensor(output_details[0]['index'])
    
    # Calculate reconstruction error (MSE)
    reconstruction_error = float(np.mean(np.square(features_scaled - reconstructed)))
    
    # Anomaly detection based on reconstruction error thresholds
    threshold_warning = thresholds['threshold_warning']
    threshold_critical = thresholds['threshold_critical']
    
    if reconstruction_error < threshold_warning:
        status = "Normal"
        anomaly_score = (reconstruction_error / threshold_warning) * 30  # 0-30 range
        confidence = 0.95
        days_until_maintenance = 90
    elif reconstruction_error < threshold_critical:
        status = "Warning"
        anomaly_score = 30 + ((reconstruction_error - threshold_warning) / (threshold_critical - threshold_warning)) * 40  # 30-70 range
        confidence = 0.80
        days_until_maintenance = 30
    else:
        status = "Anomaly Detected"
        anomaly_score = min(100, 70 + ((reconstruction_error - threshold_critical) / threshold_critical) * 30)  # 70-100 range
        confidence = 0.90
        days_until_maintenance = 7
    
    return {
        'status': status,
        'reconstruction_error': reconstruction_error,
        'anomaly_score': float(anomaly_score),
        'confidence': float(confidence),
        'days_until_maintenance': days_until_maintenance,
        'threshold_warning': threshold_warning,
        'threshold_critical': threshold_critical,
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
        "TrainingImage": "763104351884.dkr.ecr.${AWS_REGION}.amazonaws.com/tensorflow-training:2.13-cpu-py310",
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
        --primary-container Image=763104351884.dkr.ecr.${AWS_REGION}.amazonaws.com/tensorflow-inference:2.13-cpu,ModelDataUrl=$MODEL_ARTIFACT_PATH,Environment="{\"SAGEMAKER_PROGRAM\":\"inference.py\",\"SAGEMAKER_SUBMIT_DIRECTORY\":\"${S3_CODE_PATH}sourcedir.tar.gz\"}" \
        --execution-role-arn $SAGEMAKER_ROLE_ARN > /dev/null 2>&1; then
        print_log -y "[skip] " "Model may already exist, continuing..."
    fi

    # Create inference service for Greengrass
    COMPONENT_NAME="com.${PROJECT_NAME}.MLInference"
    COMPONENT_VERSION="1.0.0"
    
    cat > inference_service.py << SERVICE_EOF
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
        """Run inference using trained TFLite model"""
        try:
            import numpy as np
            import pickle
            import tflite_runtime.interpreter as tflite

            # Calculate derived features
            vibration_magnitude = np.sqrt(sensor_data['ax']**2 + sensor_data['ay']**2 + sensor_data['az']**2)
            gyro_magnitude = np.sqrt(sensor_data['gx']**2 + sensor_data['gy']**2 + sensor_data['gz']**2)
            temp_deviation = abs(sensor_data['temp_c'] - 25.0)
            power_indicator = sensor_data['current_a'] * 12.0

            # Get artifact path from environment
            artifact_dir = os.environ.get('AWS_GG_COMPONENT_ARTIFACT_DIR')
            if not artifact_dir:
                # Fallback for local testing or older Greengrass versions
                artifact_dir = "/greengrass/v2/packages/artifacts-unarchived/${COMPONENT_NAME}/${COMPONENT_VERSION}/"

            # Load model and scaler
            with open(os.path.join(artifact_dir, 'scaler.pkl'), 'rb') as f:
                scaler = pickle.load(f)
            
            interpreter = tflite.Interpreter(model_path=os.path.join(artifact_dir, 'model.tflite'))
            interpreter.allocate_tensors()
            
            input_details = interpreter.get_input_details()
            output_details = interpreter.get_output_details()

            # Prepare features
            features = np.array([[
                sensor_data['temp_c'], vibration_magnitude, gyro_magnitude,
                temp_deviation, power_indicator, sensor_data['current_a']
            ]], dtype=np.float32)

            # Scale and predict
            features_scaled = scaler.transform(features)
            
            interpreter.set_tensor(input_details[0]['index'], features_scaled)
            interpreter.invoke()
            
            # Get reconstructed output from autoencoder
            reconstructed = interpreter.get_tensor(output_details[0]['index'])
            
            # Calculate reconstruction error
            reconstruction_error = float(np.mean(np.square(features_scaled - reconstructed)))
            
            # Load thresholds (if available)
            threshold_warning = 0.01  # Default fallback
            threshold_critical = 0.02  # Default fallback
            try:
                import json
                with open(os.path.join(artifact_dir, 'thresholds.json'), 'r') as f:
                    thresholds = json.load(f)
                    threshold_warning = thresholds.get('threshold_warning', 0.01)
                    threshold_critical = thresholds.get('threshold_critical', 0.02)
            except:
                pass

            # Anomaly detection based on reconstruction error
            if reconstruction_error < threshold_warning:
                status = "Normal"
                anomaly_score = (reconstruction_error / threshold_warning) * 30
                days_until_maintenance = 90
            elif reconstruction_error < threshold_critical:
                status = "Warning"
                anomaly_score = 30 + ((reconstruction_error - threshold_warning) / (threshold_critical - threshold_warning)) * 40
                days_until_maintenance = 30
            else:
                status = "Anomaly Detected"
                anomaly_score = min(100, 70 + ((reconstruction_error - threshold_critical) / threshold_critical) * 30)
                days_until_maintenance = 7
            
            return {
                'reconstruction_error': reconstruction_error,
                'anomaly_score': float(anomaly_score),
                'status': status,
                'days_until_maintenance': days_until_maintenance,
                'threshold_warning': threshold_warning,
                'threshold_critical': threshold_critical,
                'vibration_magnitude': float(vibration_magnitude),
                'power_indicator': float(power_indicator)
            }
            
        except Exception as e:
            logger.error(f"Inference failed: {e}")
            return {
                'reconstruction_error': 0.0,
                'anomaly_score': 50.0,
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
                    logger.info(f"Anomaly Score: {prediction['anomaly_score']:.1f}, Status: {prediction['status']}, Recon Error: {prediction['reconstruction_error']:.6f}")
                
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
    
    # Trigger Edge TPU compilation
    print_log -c "[compile] " "Triggering Edge TPU model compilation..."
    if bash "$(dirname "$0")/../scripts/EdgeTPUCompiler.sh" setup; then
        print_log -g "[ok] " "Edge TPU compilation started"
    else
        print_log -y "[warn] " "Edge TPU compilation failed"
    fi
    
    # Cleanup temporary files
    rm -f train.py inference.py sourcedir.tar.gz training-job.json sagemaker-trust-policy.json
    print_log -g "[cleanup] " "Temporary files cleaned up"
    
    # Delete local training data CSV file used for this training
    if [ -n "$FOUND_DATA_FILE" ] && [ -f "$FOUND_DATA_FILE" ]; then
        print_log -c "[delete] " "Deleting local training data: $(basename $FOUND_DATA_FILE)"
        rm -f "$FOUND_DATA_FILE"
        print_log -g "[ok] " "Local training data file deleted"
    fi
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
    
    # Get absolute path to data directory
    SETUP_DIR="$(dirname "$(dirname "$0")")"
    DATA_DIR="${SETUP_DIR}/data"
    
    # Delete local CSV files
    if [ -d "$DATA_DIR" ]; then
        print_log -c "[delete] " "Deleting local training data CSV files..."
        rm -f "${DATA_DIR}"/sensor_log_*.csv 2>/dev/null || true
        print_log -g "[ok] " "Local CSV files deleted"
    fi
    
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
    
    # Trigger Edge TPU compiler cleanup
    print_log -c "[cleanup] " "Cleaning up Edge TPU compiler resources..."
    bash "$(dirname "$0")/../scripts/EdgeTPUCompiler.sh" cleanup 2>/dev/null || true
    
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