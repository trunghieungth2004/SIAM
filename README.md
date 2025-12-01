# SIAM - Smart Industrial Asset's longevity Monitor

[![Hugo](https://img.shields.io/badge/Hugo-0.152.2-blue.svg)](https://gohugo.io/)
[![AWS](https://img.shields.io/badge/AWS-IoT%20%7C%20Greengrass%20%7C%20SageMaker-orange.svg)](https://aws.amazon.com/)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

A hybrid edge-cloud platform for predictive maintenance using AWS IoT Greengrass, Coral TPU, and Amazon SageMaker.

**[View Project Proposal](https://trunghieungth2004.github.io/SIAM/)**

## Overview

SIAM is an end-to-end predictive maintenance platform that combines edge computing with cloud-based machine learning to monitor industrial equipment in real-time. The system uses a Raspberry Pi 5 with Coral TPU for local inference and AWS services for data ingestion, storage, and automated model retraining.

### Key Features

- **Native C Datalogger**: High-performance sensor reading (MPU-6050, INA219, DS18B20)
- **Edge ML Inference**: Real-time anomaly detection on Coral TPU
- **AWS Integration**: Greengrass, Lambda, DynamoDB, S3, SageMaker, API Gateway
- **REST API**: API Gateway with usage plans, rate limiting, and automatic key rotation
- **Interactive API Docs**: Swagger/OpenAPI documentation for testing endpoints
- **Automated MLOps**: Bi-weekly model retraining and monthly API key rotation via EventBridge
- **Real-time Dashboard**: Web-based monitoring with S3 Static Website hosting
- **Offline Resilience**: Zero data loss with Greengrass Stream Manager
- **Docker Containerization**: Solves Coral TPU library obsolescence

## Architecture

The platform uses a hybrid edge-cloud architecture:

- **Edge Layer**: Raspberry Pi 5 + Coral TPU running AWS IoT Greengrass
  - Native C datalogger component
  - Dockerized Python ML inference service
  - Local buffering with Stream Manager
  
- **Cloud Layer**: Serverless AWS infrastructure
  - Lambda functions for data processing and queries
  - DynamoDB for time-series sensor data storage
  - S3 for data lake, model artifacts, and web hosting
  - SageMaker for automated model training
  - API Gateway for REST API with authentication
  - EventBridge for automation (retraining, deployment, key rotation)

![Architecture Diagram](https://drive.google.com/file/d/1oSuNWL722zBMHkhSlheuezGVoR6sTiq3/view?usp=sharing)

## Quick Start

### Prerequisites

- AWS Account with Administrator access
- AWS CLI v2 configured with Administrator role credentials
- Raspberry Pi 5 (or compatible device)
- Coral TPU USB Accelerator
- Sensors: MPU-6050, INA219, DS18B20
- Bash shell (Linux/macOS)

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/trunghieungth2004/SIAM.git
   cd SIAM
   ```

2. **Configure AWS credentials**
   ```bash
   aws configure
   # Enter your AWS Access Key ID, Secret Access Key, and region
   # Note: Credentials must have Administrator permissions
   ```

3. **Set up the project**
   ```bash
   cd setup
   ./AWS.sh setup
   ```

## Project Structure

```
SIAM/
├── setup/                          # Infrastructure automation scripts
│   ├── AWS.sh                      # Main orchestration script with duration tracking
│   ├── data/                       # Training data (auto-fetched from Pi)
│   ├── Application/                # Frontend dashboard and Swagger UI
│   │   ├── index.html              # Main dashboard
│   │   ├── app.js                  # Dashboard logic
│   │   ├── swagger.html            # Interactive API documentation
│   │   ├── style.css               # Styling
│   │   └── error.html              # Error page
│   ├── certificates/               # Greengrass device certificates
│   │   └── IOT/                    # IoT Core certificates (if used)
│   │       └── GreengrassCore_*/   # Device-specific certificates
│   ├── components/                 # Component-specific setup scripts
│   │   ├── common.sh               # Shared utilities
│   │   ├── S3.sh                   # S3 buckets (data + frontend hosting)
│   │   ├── DynamoDB.sh             # NoSQL tables
│   │   ├── SNS.sh                  # Notification service
│   │   ├── SQS.sh                  # Message queues
│   │   ├── Lambda.sh               # Function deployment
│   │   ├── APIGateway.sh           # REST API with discovery-based config
│   │   ├── SageMaker.sh            # ML training pipeline
│   │   ├── CloudWatch.sh           # Monitoring and alarms
│   │   ├── EventBridge.sh          # Automation rules
│   │   ├── Greengrass.sh           # Edge deployment
│   │   ├── Local.sh                # Local data collection
│   │   ├── VPC.sh                  # VPC setup (deprecated, not used)
│   │   ├── IoT.sh                  # IoT Core setup (deprecated, not used)
│   │   ├── Application/            # Frontend build artifacts
│   │   ├── Lambda/                 # Lambda source files
│   │   │   ├── ingestion.js        # IoT data processor
│   │   │   ├── query.mjs           # API query handler
│   │   │   ├── deploy.mjs          # Greengrass deployment
│   │   │   ├── retrain.mjs         # Training trigger (AWS service discovery)
│   │   │   └── rotate.mjs          # API key rotation (AWS service discovery)
│   │   ├── Greengrass/             # Greengrass components
│   │   │   ├── Pi.sh               # Pi preparation with Tailscale support
│   │   │   ├── DataLogger/         # C datalogger component
│   │   │   │   ├── datalogger.c    # Native C sensor reader
│   │   │   │   ├── streammanager_datalogger.py  # StreamManager integration
│   │   │   │   └── component_recipe.json        # Component configuration
│   │   │   └── MLInference/        # Docker ML inference
│   │   │       ├── tpu_inference_service.py     # TPU inference service
│   │   │       ├── Dockerfile.tpu              # Docker build file
│   │   │       └── component_recipe.json        # Component configuration
│   │   └── Local/                  # Local datalogger
│   │       └── local_datalogger.c  # Standalone C datalogger for Pi
│   └── scripts/                    # Utility scripts
│       ├── EdgeTPUCompiler.sh      # Model compilation for Coral TPU
│       └── RotateAPIKey.sh         # Manual key rotation (deprecated - use EventBridge)
├── src/                            # ESP32 prototype source code
│   ├── main.cpp                    # Main application
│   └── connection/                 # WiFi and AWS connectivity
├── website/                        # Hugo static site
│   ├── content/                    # Proposal and documentation
│   ├── layouts/                    # Hugo templates
│   └── static/                     # CSS, JS, images
└── README.md                       # This file
```

## Usage

The `AWS.sh` script provides an interactive menu for component selection:

```bash
./AWS.sh setup        # Deploy AWS infrastructure (interactive component selection)
./AWS.sh cleanup      # Remove AWS resources (interactive component selection)
./AWS.sh local        # Set up local data collection on Raspberry Pi
./AWS.sh local cleanup # Remove local data collection service
./AWS.sh rotate-key   # Manually rotate API Gateway key
```

### Cleanup

Remove deployed AWS resources:

```bash
cd setup
./AWS.sh cleanup
# Follow interactive prompts to:
# 1. Enter project name
# 2. Enter IoT device (Thing) name
# 3. Confirm deletion
# 4. Select components to remove
# 5. Enter Raspberry Pi SSH target (if Greengrass selected)
```

## Components

### 1. Data Logger (Native C)

High-performance sensor reading application:
- Reads MPU-6050 (accelerometer/gyroscope) via I2C
- Reads INA219 (current sensor) via I2C
- Reads DS18B20 (temperature sensor) via 1-Wire
- Outputs CSV format compatible with SageMaker
- Located in: `setup/components/Local/local_datalogger.c`

### 2. ML Inference (Docker + Python)

Real-time anomaly detection:
- TensorFlow Lite model with INT8 quantization
- Coral TPU acceleration
- Subscribes to Greengrass Stream Manager
- Publishes predictions to IoT Core
- Located in: `setup/components/Greengrass/MLInference/`

### 3. AWS Lambda Functions

- **Ingestion**: Processes Greengrass data to DynamoDB and S3
- **Query**: API Gateway backend for web dashboard with time-range filtering
- **Retrain**: Triggers SageMaker training jobs (bi-weekly via EventBridge)
- **Rotate**: Automates API key rotation with frontend updates (monthly via EventBridge)
- **Deploy**: Updates Greengrass components with new models (event-driven)
- All functions use AWS SDK v3 with service discovery (no resource file dependency)
- Located in: `setup/components/Lambda/`

### 4. SageMaker Training

- Automated bi-weekly retraining with EventBridge (cost-optimized)
- Local-first data fetching: checks `setup/data/` then SSH/SCP from Pi
- TensorFlow model with INT8 quantization for Edge TPU
- Multi-output prediction: maintenance score and days to failure
- Auto-cleanup: deletes local training CSV and temp files post-training
- Located in: `setup/components/SageMaker.sh`

### 5. API Gateway

- REST API endpoint: `/data` with query parameters
- Authentication: x-api-key header with usage plans
- Rate limiting: 10 req/s, burst 20, daily quota 10k
- CORS enabled for frontend access
- Automatic key rotation: monthly via EventBridge Lambda
- Discovery-based configuration (no resource file dependency)
- Interactive Swagger documentation at `/swagger.html`
- Located in: `setup/components/APIGateway.sh`

## Development

### Prerequisites for Development

- GCC/G++ (for C compilation)
- Python 3.9+ (for ML inference)
- Node.js 18+ (for Lambda development)
- Hugo 0.152.2+ (for website)
- Docker (for containerization)
- AWS CLI v2

#### Coral TPU Dependencies (for Raspberry Pi)

- **System packages**: `libedgetpu1-std`, `libgpiod-dev`, `i2c-tools`
- **Python packages**:
  - `numpy==1.23.5`
  - `scipy==1.10.1`
  - `scikit-learn==1.2.2`
  - `tflite_runtime==2.5.0.post1` (aarch64)
  - `pycoral==2.0.0` (aarch64)
  - `awsiotsdk`
  - `aws-greengrass-stream-manager-sdk-python`
- **Docker base**: `python:3.9-slim` with virtual environment
- **Hardware**: Coral USB Accelerator with udev rules configured

### Testing

Run local tests:
```bash
# Compile datalogger locally
cd setup/components/Local
gcc -o datalogger local_datalogger.c -lm

# Test Lambda functions locally
cd setup/components/Lambda
npm install
node ingestion.js
```

## Security

- **API Authentication**: API Gateway with usage plans and API keys
- **Rate Limiting**: Request throttling (10 req/s, burst 20) and daily quotas
- **Automatic Rotation**: Monthly API key rotation via EventBridge Lambda
- **Edge Security**: Greengrass device certificates for authentication
- **IAM Least Privilege**: Component-specific roles with inline policies
- **No Resource Files**: AWS service discovery prevents credential exposure
- **Frontend Security**: S3 static hosting with CloudFront-ready architecture
- **Tailscale Support**: Pi SSH validation with Tailscale authentication checks

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- AWS IoT Greengrass documentation and examples
- Google Coral Edge TPU resources
- TensorFlow Lite for Microcontrollers
- Hugo static site generator

## Additional Resources

- [Project Proposal](https://trunghieungth2004.github.io/SIAM/)
- [AWS Documentation](https://docs.aws.amazon.com/)
- [Coral Edge TPU Documentation](https://coral.ai/docs/)

---
