---
title: "Home"
date: 2025-12-07
draft: false
---

Welcome to the SIAM project documentation.

## Project Overview

SIAM is a hybrid edge-cloud platform for predictive maintenance that monitors industrial equipment in real-time, detects anomalous behavior, and predicts equipment health.

### Key Features

- **Edge-First Data Collection**: Native C application collecting high-resolution sensor data
- **Offline Resilience**: Zero data loss during network outages using AWS IoT Greengrass Stream Manager
- **Cloud Integration**: Serverless AWS backend with automated MLOps pipeline
- **Real-Time Monitoring**: Web dashboard with live sensor graphs and alerts
- **Automated ML Pipeline**: Bi-weekly model retraining and deployment
- **Secure API**: REST API with x-api-key authentication and automatic monthly key rotation

### Architecture

The platform combines:
- **Edge Device**: Raspberry Pi 5 with Coral TPU running AWS IoT Greengrass
- **Cloud Services**: AWS IoT Core, Lambda, DynamoDB, S3, SageMaker, API Gateway, EventBridge
- **Sensors**: MPU-6050 (vibration), INA219 (current), DS18B20 (temperature)

### Documentation

- [Project Proposal](/proposal/) - Complete project plan with architecture, timeline, and budget

### Technology Stack

- **Edge**: C (native datalogger), Python (ML inference), Docker
- **Cloud**: AWS serverless services
- **Frontend**: Vanilla JavaScript, Swagger UI
- **ML**: Amazon SageMaker, TensorFlow Lite (Coral TPU)
