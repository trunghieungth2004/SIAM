---
title: "Proposal"
date: 2025-11-11
draft: false
---

# Project Proposal: SIAM (Smart Industrial Asset's longevity Monitor)

<div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
  <h2 style="margin: 0;">A Hybrid Edge-Cloud Platform for Predictive Maintenance</h2>
  <a href="/documentation/SIAM_Proposal.docx" download style="display: inline-flex; align-items: center; justify-content: center; width: 40px; height: 40px; border: 2px solid #0078d4; text-decoration: none; border-radius: 5px; font-size: 24px;" title="Download Proposal (Word Document)">📄</a>
</div>

## 1. Executive Summary

This proposal outlines the development of a high-performance, resilient predictive maintenance platform, SIAM (Smart Industrial Asset's longevity Monitor). The system is designed to monitor industrial equipment (represented by a demo fan machine) in real-time, detect anomalous behavior, and predict equipment health.

This solution leverages a hybrid architecture, combining a powerful edge device (Raspberry Pi 5 with a Coral TPU) with a secure, serverless AWS backend. The edge device runs AWS IoT Greengrass to manage two distinct applications:

1. A native C-based datalogger that reads directly from hardware sensors (MPU-6050, INA219, DS18B20) and writes data to Greengrass Stream Manager.
2. A Docker-containerized Python ML inference application that reads from Stream Manager, performs real-time anomaly detection using the Coral TPU, and publishes predictions back to the cloud.

The cloud backend, built on a secure AWS VPC, uses AWS IoT Core to ingest data, which is then processed by an AWS Lambda function and stored in DynamoDB and an S3 Data Lake. The system is fully automated with an MLOps pipeline using Amazon EventBridge and Amazon SageMaker to retrain and redeploy new models weekly. A public web-based dashboard, hosted on S3, provides real-time monitoring and alert status.

## 2. Problem Statement

### What's the Problem?

Traditional equipment maintenance is reactive; operators fix machines after they break, leading to costly unplanned downtime. Existing monitoring systems often lack offline capability (causing data loss) and fail to adapt to changing equipment behavior ("model drift").

### The Solution

This platform provides an end-to-end solution for intelligent, proactive maintenance.

1. **Edge-First Data Collection**: A native C application on the Raspberry Pi collects high-resolution data from sensors (MPU-6050, INA219, DS18B20).
2. **Offline Resilience & Local Pub/Sub**: The C datalogger publishes sensor data to Greengrass Stream Manager. This stream acts as a local, persistent buffer, ensuring zero data loss during network outages and decoupling the data collection from its consumption.
3. **Cloud Ingestion**: Stream Manager automatically syncs this data to AWS IoT Core, which triggers an Ingestion Lambda. This function logs data to DynamoDB and S3. A SQS Dead-Letter Queue (DLQ) captures any failed ingestion.
4. **Automated ML Pipeline**: An EventBridge rule schedules a weekly Retrain Lambda, which starts a SageMaker Training Job on the latest data from the S3 data lake.
5. **Intelligent Edge Deployment**: The newly trained model is automatically deployed back to the Raspberry Pi as a Greengrass component.
6. **Decoupled Edge Inference**: A separate Docker container running a Python application reads the sensor data from the local Stream Manager, loads the deployed model, and performs TPU-accelerated inference. This containerized approach is a key design choice, solving the "dependency hell" that often occurs when edge ML hardware (like the Coral TPU) has its software support abandoned by the manufacturer, which normally prevents host OS upgrades.
7. **Real-Time Monitoring**: A web application, hosted on S3, queries live data from DynamoDB via an API Gateway to display real-time sensor graphs and alert status.

### Benefits and Return on Investment

- **Reduced Downtime**: Proactively identifies equipment faults before they cause a catastrophic failure.
- **High Reliability**: Guarantees zero data loss, even during network outages.
- **Adaptive Intelligence**: The automated MLOps pipeline ensures the model never becomes "stale."
- **Solves Obsolescence**: The containerized inference engine allows the host Pi OS to be upgraded for security patches while the legacy Coral TPU libraries continue to function in their isolated Docker environment.

## 3. Solution Architecture

The platform is a hybrid edge-cloud system. The edge is responsible for data collection and real-time inference, while the cloud is responsible for data storage, aggregation, and model training.

<iframe frameborder="0" style="width:100%;height:600px;" src="https://viewer.diagrams.net/?tags=%7B%7D&lightbox=1&highlight=0000ff&layers=1&nav=1&title=SIAM.drawio&dark=0#Uhttps%3A%2F%2Fdrive.google.com%2Fuc%3Fid%3D1oSuNWL722zBMHkhSlheuezGVoR6sTiq3%26export%3Ddownload"></iframe>

### AWS Services Used

- **Edge**: AWS IoT Greengrass (Core, Stream Manager, Component Deployments)
- **Ingestion**: AWS IoT Core (MQTT Broker, Rules)
- **Compute**: AWS Lambda (Ingestion, Query, Retrain-Trigger, Deploy)
- **Storage**: Amazon DynamoDB, Amazon S3 (Data Lake, Model Artifacts, Web Hosting)
- **Networking**: AWS VPC (Private/Public Subnets), NAT Gateway, VPC Endpoints, API Gateway
- **Machine Learning**: Amazon SageMaker (Training Jobs), Amazon EventBridge (Scheduler)
- **Security**: AWS Secrets Manager, IAM
- **Reliability & Monitoring**: Amazon SQS (Dead-Letter Queue), Amazon CloudWatch, Amazon SNS

### Component Design

- **Edge Device**: A Raspberry Pi 5 running Raspberry Pi OS Lite. AWS Greengrass Core runs as the main agent. Two primary applications are deployed as components:
  1. **datalogger**: A native C application that reads from I2C/1-Wire sensors and publishes data to a local Stream Manager stream.
  2. **inference**: A Docker container running Python, which subscribes to the local Stream Manager stream, loads the ML model, performs inference on the Coral TPU.

- **Cloud Pipeline**: Greengrass Stream Manager -> IoT Core -> IoT Rule -> Ingestion Lambda. The Lambda (in a private subnet) writes to DynamoDB and S3.

- **Web Application**: A React app on S3 Static Website. The app fetches data from API Gateway, which triggers the Query Lambda (in a private subnet) to read from DynamoDB. The endpoint can be secured via IP restrictions or an API key.

- **MLOps Pipeline**: An EventBridge rule runs weekly, triggering the Retrain Lambda (which runs outside the VPC). This Lambda starts the SageMaker Training Job. Upon the job's completion, it triggers a separate Deploy Lambda (in the VPC) which creates a new Greengrass Deployment. This deployment is triggered to send the new, updated model to the Pi.

## 4. Technical Implementation

### Implementation Phases

1. **Phase 0: Prototyping & Design (Weeks 1-2)**
   - Set up an ESP32 with sensors to learn the basics of AWS IoT Core, MQTT, and Lambda.
   - Design the full system architecture, culminating in the SIAM.drawio diagram.
   - Prototype individual components (local C datalogger, Python inference scripts, shell script structures).

2. **Phase 1: Cloud Foundation (Week 3)**
   - Deploy the entire AWS backend infrastructure using automated scripts.
   - Test and validate cloud resources, cleaning up after each session to prevent cost accumulation during development.

3. **Phase 2: Edge Device Setup (Week 4)**
   - Provision the Raspberry Pi with Greengrass Core software.
   - Develop and compile the standalone C datalogger application.
   - Run the C datalogger as a local systemd service for 24-72 hours to collect a high-quality "normal" dataset.

4. **Phase 4: Initial Model Training (Week 6)**
   - Prepare the collected sensor data for training.
   - Train the first version of the anomaly detection model using SageMaker.

5. **Phase 5: Full Integration (Weeks 7-8)**
   - Convert the C datalogger into a native Greengrass component.
   - Build the Docker-based Python inference component (with Coral TPU libraries).
   - Deploy Stream Manager, the datalogger component, and the inference component via Greengrass.
   - **Final Goal**: Demonstrate the full, end-to-end pipeline: sensor data is collected locally, read by the inference container, and real-time predictions are made on the edge device.

### Technical Requirements

- **Edge Hardware**: Raspberry Pi 5, Coral TPU, MPU-6050, INA219, DS18B20, 4.7kΩ resistor, OLED display, RGB LED, breadboard, wires.
- **Edge Software**: Raspberry Pi OS Lite (64-bit), Docker, GCC/G++, Python, AWS IoT Greengrass Core.
- **Cloud Software**: AWS CLI (for management), Python (for SageMaker scripts), Node.js (for Lambda functions).

### Setup Implementation

All infrastructure is deployed through the `AWS.sh` orchestration script, which provisions VPC, IoT Core, Greengrass, Lambda functions, DynamoDB, S3, SageMaker, and EventBridge. Two Greengrass components are deployed to the edge: a native C DataLogger and a Dockerized Python ML inference service with Coral TPU support.

### Hardware Considerations

This proposal is based on a high-performance edge device. The following tiers are possible:

1. **Prototyping**: A breadboard and jumper wires will be used for the initial prototype, with a long-term goal of designing a dedicated PCB (Printed Circuit Board) for a more robust and compact final device.

- **High-End (As-Designed)**: Pi 5 + Coral TPU.
  - Pros: Extremely fast, real-time inference on the edge. High-throughput data logging.
  - Cons: Highest cost, library complexity for TPU (solved by our Docker approach).

- **Mid-Range**: Pi 5 (no TPU).
  - Pros: All-in-one solution with a powerful CPU and integrated GPU for high-performance ML inference. No need for a separate TPU.
  - Cons: Significantly higher cost and power consumption. Greengrass setup is different.

- **Low-End**: Pi 4 / Pi Zero 2W.
  - Pros: Very low cost.
  - Cons: Slower C datalogging. On-device inference would be too slow to be practical. This architecture would likely need to be modified to send data to a cloud-hosted SageMaker endpoint for inference, losing offline capabilities.

## 5. Timeline & Milestones (3 Months)

- **Month 1: Foundation & Single-Device Prototype (Weeks 1-4)**
  - Milestone 1 (Wk 2): Complete Phase 0 (ESP32 prototyping and final architecture design).
  - Milestone 2 (Wk 3): Complete Phase 1 & 2 (Cloud and Edge setup scripts run successfully).
  - Milestone 3 (Wk 4): Complete Phase 3 (Local C datalogger is built and collecting data).

- **Month 2: Full Pipeline Integration (Weeks 5-8)**
  - Milestone 4 (Wk 6): Complete Phase 4 (Initial ML model is trained in SageMaker).
  - Milestone 5 (Wk 8): Complete Phase 5 (Full Greengrass integration is working). The Pi is performing local, real-time inference using the trained model.

- **Month 3: Automation, Dashboard & Validation (Weeks 9-12)**
  - Milestone 6 (Wk 9): Implement the full MLOps pipeline (EventBridge -> Retrain Lambda -> SageMaker).
  - Milestone 7 (Wk 10): Build the S3/API Gateway web application for monitoring.
  - Milestone 8 (Wk 11): Perform system-wide stress testing and model validation using a second "failure" device (a fan with an imbalance) to prove the anomaly detection loop.
  - Milestone 9 (Wk 12): Final documentation, code cleanup, and project handover.

## 6. Budget Estimation

### Infrastructure Costs (Monthly, Single-Device Prototype):

- **AWS Lambda**: ~$0.00 (All 3 functions will fall within the 1 million free requests/month).
- **AWS IoT Greengrass**: $0.00 (Free for up to 10 devices).
- **AWS IoT Core**: ~$0.00 (1 device sending 1 msg/min is ~43,200 msgs/month, well under the 500,000 free tier).
- **Amazon DynamoDB**: ~$0.00 (Will fall within the 25 GB / 25 WCU free tier).
- **Amazon S3**: ~$0.10 (Negligible cost for data lake storage and hosting).
- **API Gateway, SQS, EventBridge**: ~$0.00 (All covered by generous free tiers).
- **Total Monthly Cloud Cost**: Effectively $0.00 - $0.20 (for the first 12 months).

### On-Demand & Hardware Costs:

- **Amazon SageMaker**: ~$0.20/month (for four 10-minute training jobs on an ml.m5.large). This is the primary on-demand cost.
- **Hardware (One-Time Cost)**:
  - Raspberry Pi 5 (8GB): ~$80
  - Official 27W Power Supply: ~$12
  - Google Coral TPU (USB): ~$60
  - Sensors (MPU, INA, DS18B20), OLED, etc.: ~$25
  - **Estimated Total Hardware Cost**: ~$177 per device

## 7. Risk Assessment & Mitigation

- **Risk 1: Network Outage at the Edge (Medium)**
  - Impact: Loss of real-time monitoring.
  - Mitigation: Greengrass Stream Manager. Buffers all sensor data to the Pi's local disk and syncs when reconnected, ensuring zero data loss.

- **Risk 2: ML Model Becomes "Stale" (High)**
  - Impact: Model accuracy degrades as the machine ages.
  - Mitigation: The automated MLOps pipeline. Retraining the model weekly on fresh data ensures the system adapts.

- **Risk 3: Coral TPU Library Obsolescence (High)**
  - Impact: Future Pi OS updates break the libedgetpu library, halting inference.
  - Mitigation: Docker Containerization. The inference application and its specific, legacy libraries are packaged in a Docker container. This isolates it from the host OS, allowing the host OS to be patched and upgraded independently.

- **Risk 4: Ingestion Failure (Low)**
  - Impact: A malformed data packet or transient error causes data loss.
  - Mitigation: The SQS Dead-Letter Queue (DLQ). Failed messages are captured for inspection and reprocessing.

## 8. Expected Outcomes

1. A fully functional, end-to-end predictive maintenance platform prototype.
2. A resilient edge device that reliably logs data and performs local inference, even when offline.
3. A working, real-time dashboard for visualizing sensor data and predictions.
4. A "hands-off" automated MLOps pipeline that continuously improves the system's intelligence without human intervention.
