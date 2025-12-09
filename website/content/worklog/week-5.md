---
title: "Week 5 Worklog"
date: 2025-10-06
draft: false
weight: 5
---

# Week 5 Worklog

### Week 5 Objectives:
- Analyze local sensor data collected from Raspberry Pi
- Implement Lambda functions for data ingestion and querying
- Complete API Gateway setup with authentication
- Prepare dataset for machine learning training
- Learn AWS Lambda best practices and Node.js development

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - Analyze 48-hour local sensor data collection <br> - Identify data patterns and anomalies <br> - Calculate statistics (mean, std, min, max) <br> - Visualize time-series data with Python <br> - Clean and validate sensor readings | 06/10/2025 | 06/10/2025 | Python (pandas, matplotlib) |
| 2 | - Learn AWS Lambda fundamentals: <br>  + Lambda execution model <br>  + Event-driven architecture <br>  + Cold start vs warm start <br>  + Memory and timeout configuration <br> - Study Node.js for Lambda development | 07/10/2025 | 07/10/2025 | [AWS Lambda Documentation](https://docs.aws.amazon.com/lambda/) |
| 3 | - Implement Lambda.sh component script: <br>  + Create IAM roles for Lambda <br>  + Package Lambda deployment artifacts <br>  + Deploy ingestion Lambda function <br>  + Deploy query Lambda function <br> - Test Lambda functions locally | 08/10/2025 | 08/10/2025 | AWS Lambda best practices |
| 4 | - Implement Ingestion Lambda (ingestion.js): <br>  + Parse IoT Core messages <br>  + Validate sensor data <br>  + Write to DynamoDB <br>  + Upload raw data to S3 data lake <br> - Test with sample IoT messages | 09/10/2025 | 09/10/2025 | DynamoDB JavaScript SDK |
| 5 | - Implement Query Lambda (query.mjs): <br>  + Parse API Gateway requests <br>  + Query DynamoDB by device_id and time range <br>  + Return JSON response with CORS headers <br> - Implement error handling and logging | 10/10/2025 | 10/10/2025 | API Gateway integration |
| 6 | - Complete API Gateway setup (APIGateway.sh): <br>  + Create REST API <br>  + Configure x-api-key authentication <br>  + Set up rate limiting (10 req/s, 10k daily) <br>  + Deploy API stages <br> - Test API endpoints with Postman | 11/10/2025 | 12/10/2025 | [AWS API Gateway Documentation](https://docs.aws.amazon.com/apigateway/) |

### Week 5 Achievements:

- **Local Data Collection Analysis:**
  - Successfully collected 48 hours of continuous sensor data:
    - 172,800 data points (1 reading/second)
    - File size: ~450 MB CSV format
  - Performed statistical analysis using Python pandas:
    - MPU-6050 accelerometer (baseline): Mean Z-axis = 9.78 m/s² (expected ~9.81)
    - Temperature sensor: Range 22.1°C - 26.3°C (normal room variance)
    - Current sensor: Mean = 0.52A, Std = 0.03A (stable motor operation)
  - Visualized time-series data:
    - Created plots for acceleration, current, and temperature
    - Identified periodic patterns (fan vibration frequency ~60 Hz)
    - No significant anomalies detected (healthy "normal" dataset)
  - Cleaned dataset:
    - Removed 23 outliers (sensor read errors)
    - Interpolated 7 missing timestamps
    - Final dataset: 172,770 valid samples

- **AWS Lambda Fundamentals:**
  - Mastered Lambda execution model:
    - Event-driven serverless compute
    - Automatic scaling (0 to 1000s of concurrent executions)
    - Pay-per-invocation pricing (first 1M requests free)
  - Understood Lambda lifecycle:
    - INIT phase: Load code, initialize SDK clients
    - INVOKE phase: Execute handler function
    - Cold start: ~200-500ms for Node.js
    - Warm start: ~10-20ms (reused execution environment)
  - Learned Lambda configuration:
    - Memory: 128 MB - 10 GB (CPU scales proportionally)
    - Timeout: Default 3s, max 15 minutes
    - Environment variables for configuration
  - Studied best practices:
    - Initialize SDK clients outside handler (reuse)
    - Use async/await for better error handling
    - Enable X-Ray tracing for debugging
    - Use CloudWatch Logs for monitoring

- **Lambda Component Implementation (Lambda.sh):**
  - Created automated Lambda deployment script
  - Implemented IAM role creation with policies:
    - `AWSLambdaBasicExecutionRole` - CloudWatch Logs
    - DynamoDB PutItem/Query permissions
    - S3 PutObject for data lake
    - SNS Publish for alerts
  - Built Lambda packaging system:
    - Install dependencies: `npm install @aws-sdk/client-dynamodb @aws-sdk/client-s3`
    - Create deployment ZIP with code + node_modules
    - Upload to S3 for versioning
  - Deployed multiple Lambda functions:
    - `ingestion` - IoT data processing
    - `query` - API data retrieval
    - `retrain` - SageMaker training trigger
    - `deploy` - Greengrass deployment
    - `rotate` - API key rotation
  - Added Lambda layer for shared dependencies

- **Ingestion Lambda Function (ingestion.js):**
  - Implemented IoT Core message handler:
    ```javascript
    import { DynamoDBClient, PutItemCommand } from '@aws-sdk/client-dynamodb';
    import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3';
    
    const dynamodb = new DynamoDBClient({});
    const s3 = new S3Client({});
    
    export const handler = async (event) => {
        const sensorData = JSON.parse(event.payload);
        
        // Validate sensor data
        if (!sensorData.device_id || !sensorData.timestamp) {
            throw new Error('Invalid sensor data');
        }
        
        // Write to DynamoDB
        await dynamodb.send(new PutItemCommand({
            TableName: process.env.DYNAMODB_TABLE,
            Item: {
                device_id: { S: sensorData.device_id },
                timestamp: { N: sensorData.timestamp.toString() },
                data: { S: JSON.stringify(sensorData) }
            }
        }));
        
        // Upload to S3 data lake
        await s3.send(new PutObjectCommand({
            Bucket: process.env.DATA_LAKE_BUCKET,
            Key: `raw/${sensorData.device_id}/${Date.now()}.json`,
            Body: JSON.stringify(sensorData)
        }));
        
        return { statusCode: 200 };
    };
    ```
  - Added data validation logic
  - Implemented error handling and retry logic
  - Configured CloudWatch Logs for debugging
  - Tested with mock IoT Core events

- **Query Lambda Function (query.mjs):**
  - Implemented API Gateway request handler:
    ```javascript
    import { DynamoDBClient, QueryCommand } from '@aws-sdk/client-dynamodb';
    import { unmarshall } from '@aws-sdk/util-dynamodb';
    
    const dynamodb = new DynamoDBClient({});
    
    export const handler = async (event) => {
        const device_id = event.queryStringParameters.device_id;
        const start_time = parseInt(event.queryStringParameters.start_time);
        const end_time = parseInt(event.queryStringParameters.end_time);
        
        const result = await dynamodb.send(new QueryCommand({
            TableName: process.env.DYNAMODB_TABLE,
            KeyConditionExpression: 'device_id = :id AND #ts BETWEEN :start AND :end',
            ExpressionAttributeNames: { '#ts': 'timestamp' },
            ExpressionAttributeValues: {
                ':id': device_id,
                ':start': start_time,
                ':end': end_time
            }
        });
        
        return {
            statusCode: 200,
            headers: {
                'Access-Control-Allow-Origin': '*',
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(result.Items.map(item => unmarshall(item)))
        };
    };
    ```
  - Added CORS headers for web dashboard
  - Implemented pagination for large datasets
  - Optimized DynamoDB queries with GSI

- **API Gateway Setup (APIGateway.sh):**
  - Created REST API: `SIAM-API`
  - Configured resources and methods:
    - `GET /data` - Query sensor data (integrated with Query Lambda)
    - `GET /health` - Health check endpoint
  - Implemented x-api-key authentication:
    - Created API key: `siam-api-key-[timestamp]`
    - Associated with usage plan
    - Configured automatic rotation (monthly)
  - Set up rate limiting:
    - Throttle: 10 requests/second
    - Burst: 20 requests
    - Quota: 10,000 requests/day
  - Deployed API to `prod` stage:
    - Endpoint: `https://abc123xyz.execute-api.us-east-1.amazonaws.com/prod`
  - Enabled CloudWatch Logs for API Gateway
  - Configured CORS for cross-origin requests

- **API Testing with Postman:**
  - Created Postman collection for SIAM API
  - Tested endpoints:
    ```bash
    curl -X GET 'https://abc123xyz.execute-api.us-east-1.amazonaws.com/prod/data?device_id=RaspberryPi_5_Core&start_time=1728000000&end_time=1728100000' \
      -H 'x-api-key: your-api-key-here'
    ```
  - Verified rate limiting (429 Too Many Requests after threshold)
  - Tested CORS preflight requests
  - Validated error responses (400, 401, 500)

- **Dataset Preparation for ML:**
  - Exported cleaned sensor data from local logs
  - Converted to CSV format for SageMaker:
    - Columns: timestamp, accel_x, accel_y, accel_z, gyro_x, gyro_y, gyro_z, current, voltage, temperature
    - 172,770 rows × 10 columns
  - Uploaded training dataset to S3:
    - Bucket: `siam-demo-data-lake`
    - Key: `training/normal_baseline_v1.csv`
  - Split dataset:
    - Training: 80% (138,216 samples)
    - Validation: 20% (34,554 samples)
  - Calculated normalization parameters:
    - Mean and standard deviation for each feature
    - Stored in `normalization_params.json` for inference

### Sample API Response:

```json
{
  "statusCode": 200,
  "data": [
    {
      "device_id": "RaspberryPi_5_Core",
      "timestamp": 1728012345,
      "accel_x": 0.02,
      "accel_y": -0.03,
      "accel_z": 9.78,
      "gyro_x": 0.01,
      "gyro_y": 0.00,
      "gyro_z": -0.01,
      "current": 0.52,
      "voltage": 12.4,
      "temperature": 24.2
    }
  ],
  "count": 1
}
```

### Challenges Encountered:

- **Lambda Cold Starts:** Initial API requests slow (~500ms) - solved by using provisioned concurrency
- **DynamoDB Throttling:** Hit write capacity limits during bulk testing - switched to on-demand billing
- **CORS Issues:** Browser blocked API requests - added proper CORS headers in Lambda response
- **API Key Security:** Hardcoding key in frontend is insecure - implemented automatic rotation

### Key Learnings:

- Lambda is ideal for sporadic, event-driven workloads
- DynamoDB on-demand billing is cost-effective for unpredictable traffic
- API Gateway rate limiting prevents abuse and controls costs
- x-api-key authentication is simple but requires key rotation
- CloudWatch Logs are essential for serverless debugging

### Next Week Preview:

In Week 6, I will implement the SageMaker component script, prepare the training job configuration, and train the first version of the anomaly detection model using the "normal" baseline dataset. This marks the beginning of the ML pipeline development.
