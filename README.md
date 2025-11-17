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
- **AWS Integration**: IoT Core, Greengrass, Lambda, DynamoDB, S3, SageMaker
- **Automated MLOps**: Weekly model retraining with EventBridge and SageMaker
- **Real-time Dashboard**: Web-based monitoring via S3 Static Website
- **Offline Resilience**: Zero data loss with Greengrass Stream Manager
- **Docker Containerization**: Solves Coral TPU library obsolescence

## Architecture

The platform uses a hybrid edge-cloud architecture:

- **Edge Layer**: Raspberry Pi 5 + Coral TPU running AWS IoT Greengrass
  - Native C datalogger component
  - Dockerized Python ML inference service
  
- **Cloud Layer**: AWS VPC with serverless compute
  - IoT Core for MQTT ingestion
  - Lambda functions for processing
  - DynamoDB for real-time data
  - S3 for data lake and hosting
  - SageMaker for model training

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
│   ├── AWS.sh                      # Main orchestration script
│   ├── components/                 # Component-specific setup scripts
│   │   ├── VPC.sh                  # AWS VPC setup
│   │   ├── IoT.sh                  # IoT Core setup
│   │   ├── Greengrass.sh           # Greengrass deployment
│   │   ├── Lambda.sh               # Lambda functions
│   │   ├── SageMaker.sh            # ML training pipeline
│   │   ├── Local.sh                # Local data collection
│   │   └── Greengrass/             # Greengrass components
│   │       ├── DataLogger/         # C datalogger component
│   │       └── MLInference/        # Docker ML inference
│   └── scripts/                    # Utility scripts
├── src/                            # ESP32 prototype source code
│   ├── main.cpp                    # Main application
│   └── connection/                 # WiFi and AWS connectivity
├── data/                           # Sensor data logs
├── diagram/                        # Architecture diagrams
├── website/                        # Hugo static site
│   ├── content/                    # Proposal and documentation
│   ├── layouts/                    # Hugo templates
│   └── static/                     # CSS, JS, images
└── README.md                       # This file
```

## Usage

The `AWS.sh` script provides an interactive menu for component selection:

```bash
./AWS.sh setup    # Deploy AWS infrastructure
./AWS.sh cleanup  # Remove AWS resources
./AWS.sh local    # Set up local data collection
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

- **Ingestion**: Processes IoT data to DynamoDB and S3
- **Query**: API Gateway backend for web dashboard
- **Retrain**: Triggers SageMaker training jobs
- **Deploy**: Updates Greengrass components with new models
- Located in: `setup/components/Lambda/`

### 4. SageMaker Training

- Automated weekly retraining with EventBridge
- TensorFlow model with multi-output prediction
- Edge TPU compiler for model optimization
- Located in: `setup/components/SageMaker.sh`

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

- AWS credentials stored in Secrets Manager
- VPC with private/public subnet isolation
- NAT Instance (EC2) for cost-effective internet access
- VPC Endpoints for AWS services
- IoT certificates for device authentication
- API Gateway with IP restrictions/API keys

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
