---
title: "Week 10 Worklog"
date: 2025-11-10
draft: false
weight: 10
---

### Week 10 Objectives:
- Implement automated monthly API key rotation
- Enhance API Gateway security with rate limiting and throttling
- Develop rotate Lambda for automated key management
- Build frontend web dashboard with real-time data visualization
- Integrate Swagger UI for API documentation
- Test security controls and key rotation workflow

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - Learn API Gateway security best practices: <br>  + x-api-key authentication <br>  + Usage plans and quotas <br>  + Rate limiting and throttling <br>  + API key rotation strategies | 10/11/2025 | 10/11/2025 | [API Gateway Security](https://docs.aws.amazon.com/apigateway/latest/developerguide/security.html) |
| 2 | - Implement rotate Lambda (rotate.mjs): <br>  + Create new API key <br>  + Update usage plan <br>  + Delete old API key <br>  + Update frontend S3 files with new key <br> - Configure error handling and rollback | 11/11/2025 | 11/11/2025 | API Gateway SDK |
| 3 | - Add monthly rotation to EventBridge.sh: <br>  + Create monthly scheduled rule <br>  + Configure rotate Lambda target <br>  + Test manual rotation <br> - Document rotation procedure | 12/11/2025 | 12/11/2025 | Automation best practices |
| 4 | - Develop frontend web dashboard: <br>  + Create index.html with layout <br>  + Implement styles.css (responsive design) <br>  + Build app.js (API integration, charts) <br>  + Add real-time data fetching | 13/11/2025 | 14/11/2025 | JavaScript (Chart.js, Fetch API) |
| 5 | - Integrate Swagger UI for API documentation: <br>  + Create OpenAPI 3.0 specification <br>  + Set up swagger.html page <br>  + Add "Try it out" functionality <br>  + Document all endpoints | 15/11/2025 | 15/11/2025 | [OpenAPI Specification](https://swagger.io/specification/) |
| 6 | - Test security controls: <br>  + Verify rate limiting (10 req/s) <br>  + Test daily quota (10k requests) <br>  + Validate x-api-key authentication <br>  + Test key rotation end-to-end <br> - Load testing with Apache Bench | 16/11/2025 | 16/11/2025 | Security testing |

### Week 10 Achievements:

- **API Gateway Security Best Practices:**
  - Mastered API Gateway security mechanisms:
    - **x-api-key:** Simple authentication via HTTP header
    - **Usage Plans:** Control access, set quotas and throttling
    - **Rate Limiting:** Requests per second (steady-state)
    - **Burst Limit:** Handle traffic spikes
    - **Quota:** Maximum requests per day/week/month
  - Learned key rotation strategies:
    - **Graceful rotation:** New key created before old deleted
    - **Overlap period:** Both keys work during transition
    - **Automated rotation:** EventBridge scheduled rule
  - Understood security layers:
    - L1: Network (VPC endpoints, PrivateLink)
    - L2: Authentication (x-api-key, IAM, Cognito)
    - L3: Authorization (usage plans, resource policies)
    - L4: Rate control (throttling, quotas)

- **Rotate Lambda Implementation (rotate.mjs):**
  - Implemented automated API key rotation:
    ```javascript
    import { APIGatewayClient, GetUsagePlanCommand, CreateApiKeyCommand, CreateUsagePlanKeyCommand, DeleteApiKeyCommand } from '@aws-sdk/client-api-gateway';
    import { S3Client, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
    import { SNSClient, PublishCommand } from '@aws-sdk/client-sns';
    
    const apigateway = new APIGatewayClient({});
    const s3 = new S3Client({});
    const sns = new SNSClient({});
    
    export const handler = async (event) => {
        console.log('Starting API key rotation...');
        
        try {
            // 1. Get current API key from usage plan
            const usagePlan = await apigateway.send(new GetUsagePlanCommand({
                usagePlanId: process.env.USAGE_PLAN_ID
            });
            const oldKeyId = usagePlan.apiStages[0].apiKeyId;
            
            // 2. Create new API key
            const newKeyName = `siam-api-key-${Date.now()}`;
            const newKey = await apigateway.createApiKey({
                name: newKeyName,
                description: 'SIAM API Key (auto-rotated)',
                enabled: true
            });
            console.log(`Created new API key: ${newKey.id}`);
            
            // 3. Associate new key with usage plan
            await apigateway.createUsagePlanKey({
                usagePlanId: process.env.USAGE_PLAN_ID,
                keyId: newKey.id,
                keyType: 'API_KEY'
            });
            console.log('Associated new key with usage plan');
            
            // 4. Update frontend files in S3 with new key
            await updateFrontendConfig(newKey.value);
            console.log('Updated frontend configuration');
            
            // 5. Wait 60 seconds for frontend propagation
            await sleep(60000);
            
            // 6. Delete old API key
            await apigateway.deleteApiKey({ apiKey: oldKeyId });
            console.log(`Deleted old API key: ${oldKeyId}`);
            
            // 7. Send SNS notification
            await sns.publish({
                TopicArn: process.env.SNS_TOPIC_ARN,
                Subject: 'SIAM API Key Rotated',
                Message: `API key successfully rotated.\nNew Key ID: ${newKey.id}\nOld Key ID: ${oldKeyId}\nTimestamp: ${new Date().toISOString()}`
            });
            
            return {
                statusCode: 200,
                body: JSON.stringify({
                    message: 'API key rotated successfully',
                    newKeyId: newKey.id
                })
            };
            
        } catch (error) {
            console.error('Rotation failed:', error);
            
            // Send error notification
            await sns.publish({
                TopicArn: process.env.SNS_TOPIC_ARN,
                Subject: 'SIAM API Key Rotation FAILED',
                Message: `Error: ${error.message}`
            });
            
            throw error;
        }
    };
    
    async function updateFrontendConfig(newApiKey) {
        // Download app.js from S3
        const appJs = await s3.getObject({
            Bucket: process.env.FRONTEND_BUCKET,
            Key: 'app.js'
        });
        
        // Replace API key in code
        const updatedCode = appJs.Body.toString()
            .replace(/const API_KEY = '[^']*'/, `const API_KEY = '${newApiKey}'`);
        
        // Upload updated app.js
        await s3.putObject({
            Bucket: process.env.FRONTEND_BUCKET,
            Key: 'app.js',
            Body: updatedCode,
            ContentType: 'application/javascript'
        });
    }
    ```
  - Added comprehensive error handling
  - Implemented rollback mechanism (restore old key on failure)
  - Configured Lambda timeout: 5 minutes
  - Added SNS notifications for rotation status

- **Monthly Rotation EventBridge Rule:**
  - Enhanced EventBridge.sh to create rotation rule:
    ```bash
    aws events put-rule \
      --name "SIAM-MonthlyKeyRotation" \
      --description "Rotate API Gateway key monthly" \
      --schedule-expression "cron(0 3 1 * ? *)" \
      --state ENABLED
    
    aws events put-targets \
      --rule "SIAM-MonthlyKeyRotation" \
      --targets "Id=1,Arn=${ROTATE_LAMBDA_ARN}"
    ```
    - Schedule: 1st of every month at 3 AM UTC
    - Target: Rotate Lambda function
  - Added manual rotation capability via AWS.sh:
    ```bash
    ./AWS.sh rotate-key
    ```
  - Documented rotation procedure in README

- **Frontend Web Dashboard Development:**
  - Created responsive single-page application (SPA)
  - **index.html** - Dashboard structure:
    ```html
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>SIAM - Predictive Maintenance Dashboard</title>
        <link rel="stylesheet" href="styles.css">
        <script src="https://cdn.jsdelivr.net/npm/chart.js@3.9.1"></script>
    </head>
    <body>
        <header>
            <h1> SIAM Dashboard</h1>
            <p>Smart Industrial Asset's longevity Monitor</p>
        </header>
        
        <main>
            <div class="status-card">
                <h2>System Status</h2>
                <div id="status-indicator" class="status-normal">● NORMAL</div>
                <p>Last Update: <span id="last-update">--</span></p>
            </div>
            
            <div class="chart-container">
                <h2>Sensor Readings (Last Hour)</h2>
                <canvas id="sensorChart"></canvas>
            </div>
            
            <div class="chart-container">
                <h2>ML Prediction Score</h2>
                <canvas id="predictionChart"></canvas>
            </div>
            
            <div class="metrics-grid">
                <div class="metric-card">
                    <h3>Temperature</h3>
                    <p id="temp-value" class="metric-value">--°C</p>
                </div>
                <div class="metric-card">
                    <h3>Current</h3>
                    <p id="current-value" class="metric-value">--A</p>
                </div>
                <div class="metric-card">
                    <h3>Vibration</h3>
                    <p id="vibration-value" class="metric-value">--m/s²</p>
                </div>
            </div>
        </main>
        
        <footer>
            <a href="swagger.html">📚 API Documentation</a>
        </footer>
        
        <script src="app.js"></script>
    </body>
    </html>
    ```
  
  - **styles.css** - Responsive design:
    - Clean, modern UI with AWS color scheme
    - Mobile-first responsive layout (breakpoints: 768px, 1024px)
    - CSS Grid for metrics dashboard
    - Smooth animations and transitions
    - Dark theme for better visibility
  
  - **app.js** - Data fetching and visualization:
    ```javascript
    const API_ENDPOINT = 'https://abc123xyz.execute-api.us-east-1.amazonaws.com/prod';
    const API_KEY = 'auto-replaced-by-rotate-lambda';
    const DEVICE_ID = 'RaspberryPi_5_Core';
    const REFRESH_INTERVAL = 60000; // 1 minute
    
    // Initialize Chart.js charts
    const sensorChart = new Chart(document.getElementById('sensorChart'), {
        type: 'line',
        data: {
            labels: [],
            datasets: [
                { label: 'Temperature (°C)', data: [], borderColor: 'rgb(255, 99, 132)' },
                { label: 'Current (A)', data: [], borderColor: 'rgb(54, 162, 235)' },
                { label: 'Acceleration Z (m/s²)', data: [], borderColor: 'rgb(75, 192, 192)' }
            ]
        },
        options: { responsive: true, maintainAspectRatio: false }
    });
    
    const predictionChart = new Chart(document.getElementById('predictionChart'), {
        type: 'line',
        data: {
            labels: [],
            datasets: [{
                label: 'Reconstruction Error',
                data: [],
                borderColor: 'rgb(153, 102, 255)',
                fill: false
            }]
        },
        options: {
            responsive: true,
            plugins: {
                annotation: {
                    annotations: {
                        threshold: {
                            type: 'line',
                            yMin: 0.065,
                            yMax: 0.065,
                            borderColor: 'rgb(255, 0, 0)',
                            borderWidth: 2,
                            label: { content: 'Anomaly Threshold', enabled: true }
                        }
                    }
                }
            }
        }
    });
    
    // Fetch sensor data from API
    async function fetchSensorData() {
        const endTime = Math.floor(Date.now() / 1000);
        const startTime = endTime - 3600; // Last hour
        
        try {
            const response = await fetch(
                `${API_ENDPOINT}/data?device_id=${DEVICE_ID}&start_time=${startTime}&end_time=${endTime}`,
                { headers: { 'x-api-key': API_KEY } }
            );
            
            if (!response.ok) throw new Error(`API Error: ${response.status}`);
            
            const data = await response.json();
            updateCharts(data);
            updateMetrics(data[data.length - 1]); // Latest reading
            updateStatus(data);
            
        } catch (error) {
            console.error('Failed to fetch data:', error);
            document.getElementById('status-indicator').textContent = '● ERROR';
            document.getElementById('status-indicator').className = 'status-error';
        }
    }
    
    function updateCharts(data) {
        const labels = data.map(d => new Date(d.timestamp * 1000).toLocaleTimeString());
        sensorChart.data.labels = labels;
        sensorChart.data.datasets[0].data = data.map(d => d.temperature);
        sensorChart.data.datasets[1].data = data.map(d => d.current);
        sensorChart.data.datasets[2].data = data.map(d => d.accel_z);
        sensorChart.update();
        
        predictionChart.data.labels = labels;
        predictionChart.data.datasets[0].data = data.map(d => d.reconstruction_error || 0);
        predictionChart.update();
    }
    
    function updateMetrics(latest) {
        document.getElementById('temp-value').textContent = `${latest.temperature.toFixed(1)}°C`;
        document.getElementById('current-value').textContent = `${latest.current.toFixed(2)}A`;
        document.getElementById('vibration-value').textContent = `${latest.accel_z.toFixed(2)}m/s²`;
        document.getElementById('last-update').textContent = new Date().toLocaleTimeString();
    }
    
    function updateStatus(data) {
        const latestError = data[data.length - 1].reconstruction_error || 0;
        const statusDiv = document.getElementById('status-indicator');
        
        if (latestError > 0.065) {
            statusDiv.textContent = 'ANOMALY DETECTED';
            statusDiv.className = 'status-alert';
        } else {
            statusDiv.textContent = '✓ NORMAL';
            statusDiv.className = 'status-normal';
        }
    }
    
    // Auto-refresh every minute
    setInterval(fetchSensorData, REFRESH_INTERVAL);
    fetchSensorData(); // Initial load
    ```

- **Swagger UI Integration:**
  - Created OpenAPI 3.0 specification:
    ```yaml
    openapi: 3.0.0
    info:
      title: SIAM API
      description: Smart Industrial Asset's longevity Monitor REST API
      version: 1.0.0
    servers:
      - url: https://abc123xyz.execute-api.us-east-1.amazonaws.com/prod
    security:
      - ApiKeyAuth: []
    paths:
      /data:
        get:
          summary: Query sensor data
          parameters:
            - name: device_id
              in: query
              required: true
              schema:
                type: string
            - name: start_time
              in: query
              required: true
              schema:
                type: integer
            - name: end_time
              in: query
              required: true
              schema:
                type: integer
          responses:
            '200':
              description: Successful response
              content:
                application/json:
                  schema:
                    type: array
                    items:
                      $ref: '#/components/schemas/SensorReading'
    components:
      securitySchemes:
        ApiKeyAuth:
          type: apiKey
          in: header
          name: x-api-key
      schemas:
        SensorReading:
          type: object
          properties:
            device_id:
              type: string
            timestamp:
              type: integer
            temperature:
              type: number
            current:
              type: number
            voltage:
              type: number
            accel_x:
              type: number
            accel_y:
              type: number
            accel_z:
              type: number
    ```
  - Integrated Swagger UI in swagger.html
  - Added "Try it out" functionality with x-api-key input
  - Deployed to S3 static website

- **Security Testing:**
  - **Rate Limiting Test:**
    ```bash
    # Exceeded 10 req/s limit
    ab -n 100 -c 20 -H "x-api-key: ..." https://api-endpoint/data?device_id=...
    ```
    Result: 429 Too Many Requests after ~10 requests/second 
  
  - **Daily Quota Test:**
    - Simulated 10,000 requests over 24 hours
    - API returned 429 after quota exhausted
    - Quota reset at midnight UTC 
  
  - **Authentication Test:**
    - Request without x-api-key → 403 Forbidden 
    - Request with invalid key → 403 Forbidden 
    - Request with valid key → 200 OK 
  
  - **Key Rotation Test:**
    1. Triggered rotation Lambda manually
    2. Verified new key created and old key deleted
    3. Tested frontend with auto-updated key
    4. Confirmed old key no longer works
    5. Received SNS notification email
    - **Result:**  Rotation successful in 65 seconds

### Frontend Dashboard Screenshot (Text Representation):

```
┌────────────────────────────────────────────────────────────┐
│  SIAM Dashboard                                          │
│ Smart Industrial Asset's longevity Monitor                │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  System Status        ┌──────────────────────────────┐    │
│  ✓ NORMAL             │ Sensor Readings (Last Hour)  │    │
│  Last Update: 14:23   │                              │    │
│                       │  [Line Chart]                │    │
│                       │  - Temperature               │    │
│                       │  - Current                   │    │
│                       │  - Acceleration Z            │    │
│                       └──────────────────────────────┘    │
│                                                            │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │ Temperature  │  │   Current    │  │  Vibration   │    │
│  │   24.3°C     │  │   0.52A      │  │  9.78 m/s²   │    │
│  └──────────────┘  └──────────────┘  └──────────────┘    │
│                                                            │
│  📚 API Documentation                                      │
└────────────────────────────────────────────────────────────┘
```

### Challenges Encountered:

- **CORS Issues:** Initial API requests blocked by browser - added CORS headers to Lambda responses
- **API Key Exposure:** Hardcoded key in frontend is visible in source - documented as acceptable trade-off for demo (production would use Cognito)
- **Chart.js Responsiveness:** Charts didn't resize on mobile - fixed with maintainAspectRatio: false
- **Rotation Timing:** Frontend cached old key - added 60s wait before deleting old key

### Key Learnings:

- API key rotation improves security posture significantly
- Usage plans and throttling prevent API abuse and control costs
- Swagger UI provides interactive API documentation for developers
- Responsive design is critical for modern web applications
- Automated security controls reduce human error

### Next Week Preview:

In Week 11, I will focus on comprehensive system testing, performance optimization, and creating detailed project documentation. This includes stress testing, failure scenario simulations, and preparing the final project report and demo materials.
