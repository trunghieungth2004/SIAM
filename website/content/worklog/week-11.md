---
title: "Week 11 Worklog"
date: 2025-11-17
draft: false
weight: 11
---

# Week 11 Worklog

### Week 11 Objectives:
- Verify system functionality and monitor CloudWatch metrics
- Optimize system performance and cost efficiency
- Create comprehensive project documentation and user guides
- Prepare demo materials and presentation
- Document architecture and deployment processes
- Review AWS best practices and security posture

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - System verification: <br>  + Monitor CloudWatch metrics <br>  + Verify data flow end-to-end <br>  + Check alarm configurations <br>  + Review CloudWatch dashboards | 17/11/2025 | 17/11/2025 | CloudWatch documentation |
| 2 | - Performance Optimization: <br>  + Reduce Lambda cold starts <br>  + Optimize DynamoDB queries <br>  + Review API Gateway configuration <br>  + Monitor system performance | 18/11/2025 | 18/11/2025 | AWS performance best practices |
| 3 | - Cost Optimization Review: <br>  + Analyze billing dashboard <br>  + Identify cost drivers <br>  + Implement cost-saving measures <br>  + Estimate production monthly cost <br> - Set up billing alerts | 19/11/2025 | 19/11/2025 | AWS Cost Explorer |
| 4 | - Architecture Documentation: <br>  + Update architecture diagrams <br>  + Document component interactions <br>  + Write system overview <br>  + Create data flow diagrams | 20/11/2025 | 20/11/2025 | Documentation standards |
| 5 | - Deployment and API Documentation: <br>  + Write deployment guide <br>  + Document API endpoints <br>  + Create troubleshooting guide <br>  + Write README.md | 21/11/2025 | 22/11/2025 | OpenAPI specification |
| 6 | - Demo Preparation: <br>  + Create presentation slides <br>  + Rehearse demo flow <br>  + Prepare backup scenarios <br>  + Test demo environment | 23/11/2025 | 23/11/2025 | Presentation best practices |

### Week 11 Achievements:

- **System Verification and Monitoring:**
  - **Data Flow Verification:**
    - Traced sensor readings through entire pipeline:
      1. Raspberry Pi sensor read
      2. DataLogger publish to Stream Manager
      3. Stream Manager export to IoT Core
      4. IoT Rule trigger Ingestion Lambda
      5. DynamoDB and S3 writes
      6. MLInference local processing with TPU
      7. Prediction publish to IoT Core
    - Verified all components functioning correctly
    - Monitored CloudWatch metrics for accuracy
  
  - **CloudWatch Dashboard Review:**
    - Temperature metrics displaying correctly
    - Vibration and current sensor data flowing
    - ML prediction accuracy tracked
    - System health indicators operational
  
  - **Alarm Configuration Verification:**
    - Anomaly detection alarms configured
    - SNS email subscriptions working
    - CloudWatch dashboard showing alarm states
    - Alert notifications functioning

- **Performance Optimization:**
  - **Lambda Optimization:**
    - Reviewed Lambda cold start times
    - Query Lambda: ~40ms average latency after warmup
    - Ingestion Lambda: ~85ms average execution time
    - Considered Provisioned Concurrency for production (cost analysis needed)
  
  - **DynamoDB Query Optimization:**
    - Created Global Secondary Index: `device_id-timestamp-index`
    - Improved query performance by ~40%
    - Before: 15ms average query time
    - After: 9ms average query time
    - Enables efficient historical data queries
  
  - **S3 Data Compression:**
    - Implemented gzip compression for sensor data files
    - Reduced storage footprint by ~81%
    - Before: 450 MB/week estimated
    - After: 87 MB/week
    - Long-term cost savings for data retention
  
  - **Greengrass Stream Manager Tuning:**
    - Reduced buffer size: 1GB → 256MB (memory optimization)
    - Increased batch size: 10 → 50 messages (network efficiency)
    - Network bandwidth usage: Reduced by 35%

- **Cost Optimization Review:**
  - **AWS Cost Analysis (7-day actual usage):**
    - IoT Core: $1.83 (messaging + connectivity)
    - Lambda: $0.47 (invocations + compute)
    - DynamoDB: $2.14 (on-demand writes/reads)
    - S3: $0.31 (storage + requests)
    - API Gateway: $0.08 (5,000 requests)
    - SageMaker: $0.00 (no training this week)
    - CloudWatch: $1.22 (logs + metrics)
    - Greengrass: $0.00 (free tier)
    - Data Transfer: $0.15
    - **Total:** $6.20/week ≈ **$26.59/month**
  
  - **Projected Annual Cost:** ~$319
  
  - **Cost Optimization Measures Implemented:**
    - Enabled S3 Intelligent-Tiering (saves ~15% long-term)
    - Reduced CloudWatch Logs retention to 7 days (from 30)
    - Implemented API Gateway caching (reduces Lambda invocations)
    - Optimized DynamoDB with on-demand billing (vs. provisioned)
    - Scheduled SageMaker training during off-peak (spot instances future consideration)

- **Documentation Creation:**
  - **Architecture Documentation:**
    - Created detailed architecture diagram with all components
    - Documented data flow with sequence diagrams
    - Explained design decisions and trade-offs
    - Drew.io source file uploaded to `/documentation/SIAM_Architecture.drawio`
  
  - **Deployment Guide:**
    - Step-by-step AWS infrastructure setup instructions
    - Prerequisites: AWS account, AWS CLI, Raspberry Pi hardware
    - Component setup order and dependencies
    - Verification steps for each component
    - Troubleshooting common setup issues
  
  - **API Documentation:**
    - Complete OpenAPI 3.0 specification
    - Endpoint descriptions with request/response examples
    - Authentication requirements
    - Rate limiting and quota documentation
    - Error code reference table
  
  - **Troubleshooting Guide:**
    - Common issues and solutions:
      - Greengrass not connecting → Check certificates
      - Lambda timeout → Increase timeout or optimize code
      - DynamoDB throttling → Check on-demand billing enabled
      - API 429 errors → Rate limiting triggered, retry with backoff
    - CloudWatch Logs analysis tips
    - Debugging Greengrass components
  
  - **README.md:**
    ```markdown
    # SIAM - Smart Industrial Asset's longevity Monitor
    
    A hybrid edge-cloud platform for predictive maintenance using AWS IoT.
    
    ## Features
    - Real-time sensor data collection (MPU-6050, INA219, DS18B20)
    - Edge ML inference with Coral TPU (1.3ms latency)
    - Offline-first architecture (zero data loss)
    - Automated model retraining (bi-weekly)
    - RESTful API with Swagger documentation
    - Real-time web dashboard
    - CloudWatch monitoring and alerting
    
    ## Architecture
    Edge (Raspberry Pi 5) → AWS IoT Greengrass → IoT Core → Lambda → DynamoDB/S3
    
    ## Quick Start
    1. Clone repository
    2. Configure AWS credentials
    3. Run ./setup/AWS.sh setup
    4. Deploy to Raspberry Pi
    
    ## Cost
    ~$27/month per device (AWS services)
    ```

- **Demo Preparation:**
  - Created demo scenario script:
    1. Show dashboard with normal operation
    2. Induce anomaly (attach weight to fan)
    3. Wait for ML detection (~2 minutes)
    4. Show alarm notification email
    5. Show CloudWatch metrics spike
    6. Demonstrate offline resilience (disconnect WiFi)
    7. Show Stream Manager buffering
    8. Reconnect and sync data
  - Prepared demo video (screen recording + voiceover)
  - Created slide deck with architecture diagrams
  - Prepared Q&A responses for common questions

### Week 11 Summary:

Week 11 focused on finalizing the SIAM project for presentation. Key activities included verifying all system components, optimizing performance and cost efficiency, and creating comprehensive documentation. The system is now well-documented, optimized, and ready for demonstration to FCJ mentors.

### Challenges Encountered:

- **Documentation Scope:** Balancing detail vs. readability - refined to focus on key information
- **Demo Timing:** Anomaly detection timing for live demo - adjusted threshold for demonstration
- **Cost Optimization:** Finding balance between performance and budget constraints
- **Architecture Diagrams:** Creating clear, understandable visualizations of complex system

### Key Learnings:

- Clear documentation accelerates troubleshooting and onboarding
- Performance optimization should focus on biggest bottlenecks first
- Cost optimization requires ongoing monitoring and adjustment
- Demo preparation requires practice and backup plans
- Architecture diagrams are invaluable for explaining system design

### Next Week Preview:

Week 12 is the final week - I will complete the project by finalizing documentation, conducting the final demo presentation to FCJ mentors, performing project handover, and reflecting on the entire 12-week journey. The focus will be on project completion, lessons learned, and future improvement recommendations.
