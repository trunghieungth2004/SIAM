---
title: "Week 8 Worklog"
date: 2025-10-27
draft: false
weight: 8
---

### Week 8 Objectives:
- Complete end-to-end pipeline integration (edge to cloud)
- Implement CloudWatch monitoring and alarms
- Set up SNS notifications for anomaly alerts
- Test system with simulated equipment failure
- Validate offline resilience and data recovery
- Optimize system performance and resource usage

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - Implement CloudWatch.sh component script: <br>  + Create custom CloudWatch metrics <br>  + Configure log groups for all components <br>  + Set up metric filters <br>  + Create CloudWatch dashboard | 27/10/2025 | 27/10/2025 | [AWS CloudWatch Documentation](https://docs.aws.amazon.com/cloudwatch/) |
| 2 | - Configure CloudWatch Alarms: <br>  + Anomaly detection alarm <br>  + Greengrass offline alarm <br>  + Lambda error rate alarm <br>  + DynamoDB throttling alarm <br> - Integrate SNS for email notifications | 28/10/2025 | 28/10/2025 | CloudWatch Alarms guide |
| 3 | - Create CloudWatch Dashboard: <br>  + Real-time sensor metrics <br>  + Prediction confidence scores <br>  + System health indicators <br>  + Component status widgets <br> - Test dashboard visualization | 29/10/2025 | 29/10/2025 | Dashboard JSON configuration |
| 4 | - End-to-end pipeline testing: <br>  + Verify sensor → edge → cloud flow <br>  + Check Lambda ingestion and query <br>  + Validate DynamoDB writes <br>  + Test API Gateway responses <br> - Monitor CloudWatch metrics | 30/10/2025 | 30/10/2025 | Integration testing plan |
| 5 | - Simulate equipment failure: <br>  + Attach weight to fan blade (imbalance) <br>  + Collect 1 hour of anomalous data <br>  + Verify ML model detects anomaly <br>  + Confirm CloudWatch alarm triggered <br>  + Validate SNS email notification | 31/10/2025 | 31/10/2025 | Anomaly testing procedure |
| 6 | - Test offline resilience: <br>  + Disconnect network for 2 hours <br>  + Verify local buffering (Stream Manager) <br>  + Reconnect and confirm data sync <br>  + Check for data loss <br> - Perform system optimization | 01/11/2025 | 02/11/2025 | Resilience testing guide |

### Week 8 Achievements:

- **CloudWatch Component Implementation (CloudWatch.sh):**
  - Created automated CloudWatch setup script
  - Configured log groups for all AWS components:
    - `/aws/lambda/siam-ingestion` - Ingestion Lambda logs
    - `/aws/lambda/siam-query` - Query Lambda logs
    - `/aws/greengrass/siam-edge-01` - Greengrass Core logs
    - `/aws/iot/siam-predictions` - ML prediction logs
  - Set log retention: 7 days (cost optimization)
  - Enabled log insights for advanced queries
  - Created custom CloudWatch metrics:
    - `SIAM/SensorData/Temperature` - Real-time temperature
    - `SIAM/SensorData/Current` - Motor current draw
    - `SIAM/Predictions/ReconstructionError` - ML model score
    - `SIAM/System/GreengrassConnected` - Device online status
  - Implemented metric filters for pattern matching:
    - ERROR log pattern → `ErrorCount` metric
    - "anomaly detected" pattern → `AnomalyCount` metric

- **CloudWatch Alarms Configuration:**
  - Created **Anomaly Detection Alarm**:
    - Metric: `SIAM/Predictions/ReconstructionError`
    - Threshold: > 0.065 (model threshold)
    - Evaluation periods: 2 out of 3 datapoints
    - Actions: Publish to SNS topic `siam-alerts`
  - Created **Greengrass Offline Alarm**:
    - Metric: `SIAM/System/GreengrassConnected`
    - Threshold: < 1 (device disconnected)
    - Evaluation periods: 3 consecutive datapoints (3 minutes)
    - Actions: SNS notification + CloudWatch event
  - Created **Lambda Error Rate Alarm**:
    - Metric: `AWS/Lambda` Errors metric
    - Threshold: > 5 errors in 5 minutes
    - Actions: SNS notification to admin
  - Created **DynamoDB Throttle Alarm**:
    - Metric: `AWS/DynamoDB` ThrottledRequests
    - Threshold: > 0
    - Actions: SNS notification + auto-scaling trigger
  - Configured SNS email subscriptions:
    - Subscribed engineering email to `siam-alerts` topic
    - Confirmed subscription via email
    - Tested with manual alarm trigger

- **CloudWatch Dashboard Creation:**
  - Designed comprehensive monitoring dashboard: `SIAM-Production-Dashboard`
  - Widgets implemented:
    1. **Sensor Time-Series Widget:**
       - Line graph: Temperature, Current, Voltage
       - 1-hour rolling window
       - Auto-refresh every 1 minute
    2. **Reconstruction Error Widget:**
       - Line graph with anomaly threshold line
       - Color-coded: Green (normal), Red (anomaly)
    3. **Anomaly Count Widget:**
       - Number widget showing total anomalies detected
       - 24-hour period
    4. **System Health Widget:**
       - Pie chart: Component status (Running/Stopped/Error)
    5. **Lambda Performance Widget:**
       - Bar graph: Invocation count, error rate, duration
    6. **DynamoDB Metrics Widget:**
       - Line graph: Read/write capacity units consumed
    7. **Greengrass Status Widget:**
       - Number widget: Connection status (1=Online, 0=Offline)
  - Exported dashboard configuration to `dashboard.json`
  - Implemented auto-deployment in CloudWatch.sh script

- **End-to-End Pipeline Testing:**
  - **Test 1: Normal Operation Flow**
    1. DataLogger reads sensors every 1 second
    2. Data published to Stream Manager
    3. Stream Manager exports to IoT Core (batch every 5s)
    4. IoT Rule triggers Ingestion Lambda
    5. Lambda writes to DynamoDB and S3
    6. MLInference reads from Stream Manager
    7. Prediction published to IoT Core
    8. CloudWatch metrics updated
    - Result:  All steps successful, latency < 2s end-to-end
  
  - **Test 2: API Query Flow**
    1. Frontend calls API Gateway with x-api-key
    2. API Gateway triggers Query Lambda
    3. Lambda queries DynamoDB
    4. Response returned with CORS headers
    - Result:  Response time ~150ms, data accurate
  
  - **Test 3: Monitoring Flow**
    1. Custom metrics published to CloudWatch
    2. Dashboard widgets updated in real-time
    3. Metrics visible in CloudWatch console
    - Result:  Dashboard refreshing every minute

- **Simulated Equipment Failure Testing:**
  - **Setup:**
    - Attached 10g weight to one fan blade (created imbalance)
    - Expected: Increased vibration (accelerometer) and current draw
  - **Data Collection (1 hour):**
    - Collected 3,600 anomalous samples
    - Observed metrics:
      - Accelerometer Z-axis stddev: 0.12 (normal: 0.02)
      - Current draw: 0.68A (normal: 0.52A, +31% increase)
      - Gyroscope readings: erratic fluctuations
  - **ML Model Performance:**
    - Reconstruction error: Mean = 0.0923 (normal: 0.0201)
    - Anomalies detected: 3,487 out of 3,600 (96.9% detection rate)
    - False positives: 13 (0.36%)
  - **CloudWatch Alarm Triggering:**
    - Anomaly alarm entered ALARM state after 2 minutes
    - SNS email notification received:
      ```
      Subject: ALARM: SIAM-AnomalyDetected
      
      Alarm: SIAM-AnomalyDetected in US East (N. Virginia)
      Description: High reconstruction error detected
      Threshold: 0.065
      Current Value: 0.0923
      
      Device: RaspberryPi_5_Core
      Timestamp: 2025-10-31T14:23:45Z
      ```
    - Dashboard showed red alert banner
  - **Test Result:**  System successfully detected equipment failure

- **Offline Resilience Testing:**
  - **Test Procedure:**
    1. Disconnected Raspberry Pi WiFi at 10:00 AM
    2. Continued data collection for 2 hours (offline)
    3. Reconnected WiFi at 12:00 PM
    4. Monitored data synchronization
  
  - **Results:**
    - **During Offline Period (10:00-12:00):**
      - DataLogger: Continued writing to Stream Manager (7,200 messages)
      - Stream Manager: Buffered all messages to disk (`/greengrass/v2/work/aws.greengrass.StreamManager/SensorDataStream/`)
      - MLInference: Continued local predictions (no cloud publish)
      - Disk usage: 14.3 MB for buffered data
    
    - **Greengrass Offline Alarm:**
      - Triggered at 10:03 AM (3 minutes after disconnect)
      - SNS notification sent to admin
    
    - **After Reconnection (12:00):**
      - Stream Manager auto-synced buffered messages
      - Sync completed in 4 minutes 32 seconds
      - All 7,200 messages successfully exported to IoT Core
      - Ingestion Lambda processed backlog (no errors)
      - DynamoDB wrote all 7,200 records
      - S3 data lake received all raw sensor data
    
    - **Data Integrity Check:**
      - Queried DynamoDB for time range 10:00-12:00
      - Retrieved all 7,200 records
      - Verified no gaps in timestamps
      - **Zero data loss confirmed** 

- **System Performance Optimization:**
  - **Edge Device (Raspberry Pi 5):**
    - CPU usage: 18% average (DataLogger: 3%, MLInference: 12%, Greengrass: 3%)
    - Memory usage: 1.2 GB / 8 GB (15%)
    - Disk I/O: Minimal (Stream Manager optimized for batch writes)
    - Network: 2.3 KB/s average (efficient batching)
  
  - **Cloud Services:**
    - Lambda cold start optimization:
      - Added Provisioned Concurrency (1 instance) for Query Lambda
      - Reduced cold start from 450ms to <50ms
    - DynamoDB optimization:
      - On-demand billing handles variable traffic well
      - Average read latency: 8ms
      - Average write latency: 12ms
    - API Gateway:
      - Added caching (5-minute TTL) for frequent queries
      - Reduced Lambda invocations by 60%
  
  - **Cost Optimization:**
    - Enabled S3 Intelligent-Tiering for data lake
    - Reduced CloudWatch Logs retention to 7 days
    - Scheduled Greengrass deployments during off-peak hours

- **Integration Test Summary:**
  -  Sensor data collection: 100% uptime over 7 days
  -  Edge ML inference: 1.3ms average latency
  -  Cloud data ingestion: 99.97% success rate
  -  API response time: 142ms average (p95: 280ms)
  -  Anomaly detection accuracy: 96.9%
  -  Offline resilience: Zero data loss after 2-hour outage
  -  CloudWatch alarms: 100% trigger accuracy
  -  SNS notifications: Delivered within 30 seconds

### System Architecture Diagram (Verified):

```
┌─────────────────────────────────────────────────────────┐
│ Edge Device (Raspberry Pi 5)                            │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │ Sensors  │───▶│ DataLogger   │───▶│ Stream       │  │
│  │(MPU/INA/ │    │ (Native C)   │    │ Manager      │──┼──▶ IoT Core
│  │ DS18B20) │    └──────────────┘    └──────┬───────┘  │
│  └──────────┘           │                   │          │
│                         │                   ▼          │
│                         │            ┌──────────────┐  │
│                         └───────────▶│ MLInference  │  │
│                                      │ (Docker+TPU) │──┼──▶ IoT Core
│                                      └──────────────┘  │
└─────────────────────────────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────┐
│ AWS Cloud                                                │
│  IoT Core ──▶ Lambda ──▶ DynamoDB / S3 ──▶ API Gateway  │
│                  │                              │        │
│                  ▼                              ▼        │
│            CloudWatch ◀────────────────── Web Dashboard  │
│                  │                                       │
│                  ▼                                       │
│                SNS ──▶ Email Alerts                      │
└─────────────────────────────────────────────────────────┘
```

### Challenges Encountered:

- **CloudWatch Metric Delay:** Custom metrics took 2-3 minutes to appear - expected behavior for CloudWatch
- **Stream Manager Memory:** Initial config used too much memory - reduced buffer size from 1GB to 256MB
- **Alarm False Positives:** Initial threshold too sensitive - tuned to 2 out of 3 datapoints
- **S3 Data Lake Growth:** 7 days of data = 1.2 GB - implemented lifecycle policy (archive after 90 days)

### Key Learnings:

- CloudWatch is essential for production monitoring and troubleshooting
- Stream Manager's offline buffering is critical for industrial IoT reliability
- Real-world anomaly testing validates ML model effectiveness
- SNS provides reliable, fast alerting for critical events
- Dashboard visualization helps stakeholders understand system health

### Next Week Preview:

In Week 9, I will implement the automated MLOps pipeline using EventBridge and Lambda. This includes bi-weekly model retraining, automated deployment to the edge, and monthly API key rotation. The focus shifts to production automation and operational excellence.
