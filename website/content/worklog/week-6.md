---
title: "Week 6 Worklog"
date: 2025-10-13
draft: false
weight: 6
---

### Week 6 Objectives:
- Learn Amazon SageMaker fundamentals and ML workflows
- Implement SageMaker component script for automated training
- Design and develop anomaly detection ML model
- Train the first model version on collected "normal" sensor data
- Evaluate model performance and prepare for edge deployment

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - Learn Amazon SageMaker fundamentals: <br>  + SageMaker components (Notebooks, Training Jobs, Endpoints) <br>  + Built-in algorithms <br>  + Bring-your-own-model (BYOM) <br>  + Model deployment strategies <br> - Study ML model selection for anomaly detection | 13/10/2025 | 13/10/2025 | [AWS SageMaker Documentation](https://docs.aws.amazon.com/sagemaker/) |
| 2 | - Design anomaly detection model: <br>  + Research Autoencoder architecture <br>  + Choose TensorFlow Lite for edge deployment <br>  + Design model architecture (encoder-decoder) <br> - Create training script in Python | 14/10/2025 | 14/10/2025 | TensorFlow documentation <br> Anomaly detection papers |
| 3 | - Implement SageMaker.sh component script: <br>  + Create SageMaker IAM role <br>  + Configure S3 paths for training data <br>  + Set up training job configuration <br>  + Implement model artifact retrieval | 15/10/2025 | 15/10/2025 | SageMaker SDK documentation |
| 4 | - Develop training container: <br>  + Create Dockerfile with TensorFlow <br>  + Implement train.py script <br>  + Add data preprocessing pipeline <br>  + Configure hyperparameters <br> - Test container locally with Docker | 16/10/2025 | 16/10/2025 | Docker, TensorFlow |
| 5 | - Launch first SageMaker Training Job: <br>  + Upload training data to S3 <br>  + Start training job via AWS CLI <br>  + Monitor CloudWatch Logs <br>  + Track training metrics | 17/10/2025 | 18/10/2025 | SageMaker console |
| 6 | - Evaluate trained model: <br>  + Download model artifacts from S3 <br>  + Test model with validation data <br>  + Calculate reconstruction error threshold <br>  + Convert to TensorFlow Lite for edge <br> - Document model performance | 19/10/2025 | 19/10/2025 | TensorFlow Lite converter |

### Week 6 Achievements:

- **Amazon SageMaker Fundamentals:**
  - Mastered SageMaker architecture:
    - **SageMaker Studio:** Integrated ML development environment
    - **Training Jobs:** Scalable model training on managed instances
    - **Model Registry:** Versioned model artifact storage
    - **Endpoints:** Real-time inference hosting
    - **Batch Transform:** Offline batch predictions
  - Learned SageMaker instance types:
    - ml.m5.xlarge: General purpose training (4 vCPU, 16 GB RAM)
    - ml.p3.2xlarge: GPU training for deep learning
    - ml.t3.medium: Low-cost development/testing
  - Understood SageMaker pricing:
    - Training: Per-second billing for instance usage
    - Endpoints: Hourly charges for hosted models
    - Data transfer: S3 to SageMaker in same region (free)
  - Studied SageMaker built-in algorithms:
    - Random Cut Forest (RCF) for anomaly detection
    - XGBoost, Linear Learner, K-Means
  - Chose custom model approach for better edge optimization

- **Anomaly Detection Model Design:**
  - Selected **Autoencoder** architecture:
    - Unsupervised learning (only "normal" data needed)
    - Learns compressed representation of normal patterns
    - Reconstruction error indicates anomalies
  - Designed model architecture:
    ```
    Input (9 features) → Encoder (Dense 16, 8, 4) → Bottleneck (2) → Decoder (Dense 4, 8, 16) → Output (9 features)
    Activation: ReLU for hidden layers, Linear for output
    Loss: Mean Squared Error (MSE)
    ```
  - Selected TensorFlow Lite for edge deployment:
    - Smaller model size (~50 KB vs 5 MB)
    - Optimized for CPU/TPU inference
    - Compatible with Coral TPU EdgeTPU Compiler
  - Chose model input features (9 total):
    - accel_x, accel_y, accel_z
    - gyro_x, gyro_y, gyro_z
    - current, voltage, temperature

- **SageMaker Component Implementation (SageMaker.sh):**
  - Created SageMaker IAM role with permissions:
    - S3 read/write for training data and model artifacts
    - CloudWatch Logs for training job logs
    - ECR access for custom training containers
  - Implemented training job configuration:
    ```bash
    aws sagemaker create-training-job \
      --training-job-name "siam-anomaly-v1-$(date +%s)" \
      --role-arn "$SAGEMAKER_ROLE_ARN" \
      --algorithm-specification TrainingImage="$TRAINING_IMAGE" \
      --input-data-config '[
        {
          "ChannelName": "training",
          "DataSource": {
            "S3DataSource": {
              "S3DataType": "S3Prefix",
              "S3Uri": "s3://siam-demo-data-lake/training/"
            }
          }
        }
      ]' \
      --output-data-config S3OutputPath="s3://siam-demo-data-lake/models/" \
      --resource-config InstanceType=ml.m5.xlarge,InstanceCount=1,VolumeSizeInGB=10 \
      --stopping-condition MaxRuntimeInSeconds=3600
    ```
  - Added automated model artifact download
  - Implemented TensorFlow Lite conversion post-training
  - Created EdgeTPU compilation integration

- **Training Container Development:**
  - Created custom Docker container with TensorFlow:
    ```dockerfile
    FROM tensorflow/tensorflow:2.13.0
    
    RUN pip install --no-cache-dir \
        pandas \
        scikit-learn \
        boto3
    
    COPY train.py /opt/ml/code/train.py
    WORKDIR /opt/ml/code
    
    ENTRYPOINT ["python", "train.py"]
    ```
  - Implemented train.py script:
    - Load CSV data from `/opt/ml/input/data/training/`
    - Normalize features (z-score normalization)
    - Build Autoencoder model with Keras
    - Train for 50 epochs with early stopping
    - Save model to `/opt/ml/model/`
  - Added data preprocessing pipeline:
    ```python
    def preprocess_data(df):
        features = ['accel_x', 'accel_y', 'accel_z', 
                   'gyro_x', 'gyro_y', 'gyro_z',
                   'current', 'voltage', 'temperature']
        X = df[features].values
        
        # Z-score normalization
        mean = X.mean(axis=0)
        std = X.std(axis=0)
        X_normalized = (X - mean) / std
        
        return X_normalized, mean, std
    ```
  - Configured hyperparameters:
    - Learning rate: 0.001
    - Batch size: 32
    - Epochs: 50 (with early stopping patience=5)
    - Optimizer: Adam
  - Tested container locally with sample data

- **First SageMaker Training Job:**
  - Uploaded training dataset to S3:
    - Path: `s3://siam-demo-data-lake/training/normal_baseline_v1.csv`
    - Size: 138,216 samples
  - Started training job: `siam-anomaly-v1-1697644800`
  - Monitored training progress via CloudWatch Logs:
    ```
    Epoch 1/50 - loss: 0.4523 - val_loss: 0.3891
    Epoch 2/50 - loss: 0.3142 - val_loss: 0.2756
    ...
    Epoch 28/50 - loss: 0.0234 - val_loss: 0.0198
    Early stopping triggered at epoch 28
    ```
  - Training duration: 18 minutes
  - Final validation loss: 0.0198
  - Training cost: $0.08 (ml.m5.xlarge for 18 minutes)

- **Model Evaluation:**
  - Downloaded model artifacts from S3:
    - TensorFlow SavedModel format (output from SageMaker)
    - Normalization parameters: `scaler.pkl` and `days_scaler.pkl`
    - Feature list: `features.txt`
  - Tested model on validation dataset:
    - Mean reconstruction error (normal data): 0.0201
    - Max reconstruction error (normal data): 0.0487
    - Set anomaly threshold: 0.065 (mean + 3 × std)
  - Created "anomaly" test dataset (manually imbalanced fan):
    - Mean reconstruction error (anomaly): 0.1234
    - Successfully detected 97.3% of anomalies
  - Note: TensorFlow Lite conversion and EdgeTPU compilation happen automatically via EdgeTPUCompiler.sh:
    - EC2 t3.micro instance launched automatically
    - Downloads model from SageMaker S3 output
    - Converts to TFLite with INT8 quantization
    - Compiles for Coral TPU using `edgetpu_compiler`
    - Uploads compiled model to S3: `model_edgetpu_latest.tar.gz`
    - Instance self-terminates after ~3-5 minutes
  - Final model size: ~54 KB (EdgeTPU optimized)

- **Model Performance Metrics:**
  - Precision: 0.973 (low false positives)
  - Recall: 0.965 (catches most anomalies)
  - F1-Score: 0.969
  - Inference time (CPU): ~8ms per sample
  - Inference time (Coral TPU): ~1.2ms per sample

### Training Loss Curve:

```
Loss
0.45│
    │
0.30│       ╲
    │        ╲___
0.15│            ╲______
    │                   ╲___________
0.00└───────────────────────────────────
    0   10   20   30   40   50   Epoch
```

### Challenges Encountered:

- **SageMaker Container Debugging:** Hard to debug inside SageMaker - solved with local mode testing
- **S3 Path Configuration:** Training job failed due to incorrect S3 URI format - fixed IAM permissions
- **Model Overfitting:** Initial model overfit training data - added dropout (0.2) to encoder layers
- **EdgeTPU Compilation:** Not all TensorFlow ops supported - simplified architecture

### Key Learnings:

- SageMaker Training Jobs abstract infrastructure complexity
- Autoencoders are powerful for unsupervised anomaly detection
- TensorFlow Lite reduces model size by 99% with minimal accuracy loss
- Coral TPU provides 6-7× speedup over CPU inference
- Model threshold tuning is critical to balance false positives/negatives

### Next Week Preview:

In Week 7, I will integrate the trained model into the Raspberry Pi edge device using AWS IoT Greengrass. This involves creating Greengrass components for the datalogger and ML inference, configuring Stream Manager for offline buffering, and deploying the first version of the edge intelligence system.
