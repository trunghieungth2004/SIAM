# SIAM - Smart Industrial Asset's longevity Monitor

[![Hugo](https://img.shields.io/badge/Hugo-0.152.2-blue.svg)](https://gohugo.io/)
[![AWS](https://img.shields.io/badge/AWS-IoT%20%7C%20Greengrass%20%7C%20SageMaker-orange.svg)](https://aws.amazon.com/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

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

![Architecture Diagram](diagram/SIAM.drawio)

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
   export PROJECT_NAME="MyProject"
   export AWS_REGION="us-east-1"
   export PI_SSH_TARGET="pi@192.168.1.100"
   export THING_NAME="MyIoTDevice"
   ```

4. **Deploy AWS infrastructure**
   ```bash
   # Deploy all cloud components
   ./AWS.sh setup
   
   # Or deploy specific components
   ./AWS.sh vpc setup
   ./AWS.sh iot setup
   ./AWS.sh lambda setup
   ./AWS.sh sagemaker setup
   ```

5. **Set up edge device**
   ```bash
   # Install Greengrass on Raspberry Pi
   ./AWS.sh greengrass setup
   
   # Or collect local data without cloud
   ./AWS.sh local
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

### Cloud Deployment

Deploy specific AWS components:

```bash
# Deploy VPC infrastructure
./AWS.sh vpc setup

# Deploy IoT Core resources
./AWS.sh iot setup

# Deploy Lambda functions
./AWS.sh lambda setup

# Deploy SageMaker training pipeline
./AWS.sh sagemaker setup

# Deploy complete Greengrass system
./AWS.sh greengrass setup
```

### Local Data Collection

Run standalone data collection on Raspberry Pi:

```bash
./AWS.sh local
# Enter Pi SSH target (e.g., pi@192.168.1.100)
# Enter collection duration in days
# Service will run automatically and stop after duration
```

View real-time sensor data:
```bash
ssh pi@192.168.1.100 'sudo journalctl -u local-datalogger -f'
```

### Cleanup

Remove all deployed resources:

```bash
# Clean up specific components
./AWS.sh vpc cleanup
./AWS.sh iot cleanup
./AWS.sh greengrass cleanup

# Clean up everything
./AWS.sh cleanup
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

## Web Dashboard

The project includes a Hugo-based static website for documentation and monitoring:

```bash
cd website
hugo server
# Visit http://localhost:1313
```

Deploy to GitHub Pages:
```bash
# Automatic deployment via GitHub Actions
# Push to master branch triggers deployment
```

## Cost Estimation

**Monthly AWS Costs (Single Device):**
- IoT Core: $0.00 (free tier)
- Lambda: $0.00 (free tier)
- DynamoDB: $0.00 (free tier)
- S3: ~$0.10
- SageMaker: ~$0.20 (4 training jobs/month)
- **Total: ~$0.30/month**

**Hardware Costs (One-Time):**
- Raspberry Pi 5 (8GB): ~$80
- Coral TPU USB: ~$60
- Sensors + Components: ~$25
- Power Supply: ~$12
- **Total: ~$177/device**

## Development

### Prerequisites for Development

- GCC/G++ (for C compilation)
- Python 3.8+
- Node.js 18+ (for Lambda development)
- Hugo 0.152.2+ (for website)
- Docker (for containerization)
- AWS CLI v2

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

## Configuration

Environment variables for `AWS.sh`:

```bash
export PROJECT_NAME="YourProjectName"      # Required
export AWS_REGION="us-east-1"              # Required
export PI_SSH_TARGET="pi@192.168.1.100"   # Required for Greengrass/Local
export THING_NAME="YourIoTThing"           # Required for IoT setup
export VPC_CIDR="10.0.0.0/16"             # Optional, default shown
```

## Security

- AWS credentials stored in Secrets Manager
- VPC with private/public subnet isolation
- NAT Gateway for secure internet access
- VPC Endpoints for AWS services
- IoT certificates for device authentication
- API Gateway with IP restrictions/API keys

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Author

**Trung Hieu Nguyễn**
- GitHub: [@trunghieungth2004](https://github.com/trunghieungth2004)

## Acknowledgments

- AWS IoT Greengrass documentation and examples
- Google Coral Edge TPU resources
- TensorFlow Lite for Microcontrollers
- Hugo static site generator

## Additional Resources

- [Project Proposal](https://trunghieungth2004.github.io/SIAM/)
- [AWS IoT Greengrass Documentation](https://docs.aws.amazon.com/greengrass/)
- [Coral Edge TPU Documentation](https://coral.ai/docs/)
- [Amazon SageMaker Documentation](https://docs.aws.amazon.com/sagemaker/)

---
