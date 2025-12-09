---
title: "Week 9 Worklog"
date: 2025-11-03
draft: false
weight: 9
---

### Week 9 Objectives:
- Implement EventBridge scheduled rules for automation
- Develop retrain Lambda for automated model retraining
- Create deploy Lambda for Greengrass component deployment
- Build automated MLOps pipeline (retrain → deploy → edge)
- Test bi-weekly retraining workflow
- Validate model versioning and rollback capabilities

### Tasks to be carried out this week:

| Day | Task | Start Date | Completion Date | Reference Material |
|-----|------|------------|-----------------|-------------------|
| 1 | - Learn Amazon EventBridge fundamentals: <br>  + Event-driven architecture <br>  + Scheduled rules (cron expressions) <br>  + Event patterns and targets <br>  + EventBridge vs CloudWatch Events | 03/11/2025 | 03/11/2025 | [AWS EventBridge Documentation](https://docs.aws.amazon.com/eventbridge/) |
| 2 | - Implement retrain Lambda (retrain.mjs): <br>  + Query S3 data lake for latest data <br>  + Aggregate training samples <br>  + Start SageMaker Training Job <br>  + Store job metadata in DynamoDB | 04/11/2025 | 04/11/2025 | SageMaker SDK |
| 3 | - Implement deploy Lambda (deploy.mjs): <br>  + Triggered by SageMaker job completion <br>  + Download model artifacts from S3 <br>  + Convert to TensorFlow Lite + EdgeTPU <br>  + Create Greengrass deployment <br>  + Update component version | 05/11/2025 | 05/11/2025 | Greengrass deployment SDK |
| 4 | - Implement EventBridge.sh component script: <br>  + Create bi-weekly retrain rule (cron) <br>  + Create SageMaker completion rule (event pattern) <br>  + Configure Lambda targets <br>  + Set up IAM permissions | 06/11/2025 | 06/11/2025 | EventBridge rule configuration |
| 5 | - Test automated MLOps pipeline: <br>  + Manually trigger retrain Lambda <br>  + Monitor SageMaker training job <br>  + Verify deploy Lambda triggers on completion <br>  + Confirm edge deployment <br>  + Validate new model on Raspberry Pi | 07/11/2025 | 08/11/2025 | Integration testing |
| 6 | - Implement model versioning: <br>  + S3 versioning for model artifacts <br>  + DynamoDB model registry table <br>  + Greengrass component versioning <br>  + Rollback procedure documentation | 09/11/2025 | 09/11/2025 | Versioning best practices |

### Week 9 Achievements:

- **Amazon EventBridge Fundamentals:**
  - Mastered EventBridge architecture:
    - **Event Bus:** Central event routing mechanism
    - **Rules:** Match events and route to targets
    - **Scheduled Rules:** Cron-based automation (like cron jobs)
    - **Event Patterns:** Filter events by JSON structure
    - **Targets:** Services that receive events (Lambda, SNS, SQS, etc.)
  - Understood EventBridge vs CloudWatch Events:
    - EventBridge is the evolution of CloudWatch Events
    - Added custom event buses and schema registry
    - Better third-party integration (Datadog, Zendesk, etc.)
  - Learned cron expression syntax:
    - `cron(0 0 * * ? *)` - Daily at midnight UTC
    - `cron(0 2 ? * 1 *)` - Every Monday at 2 AM
    - `cron(0 0 1,15 * ? *)` - 1st and 15th of every month (bi-weekly)
  - Studied event-driven patterns:
    - Trigger workflows based on AWS service state changes
    - Decouple services with asynchronous events
    - Build reactive, scalable architectures

- **Retrain Lambda Implementation (retrain.mjs):**
  - Implemented automated retraining workflow:
    ```javascript
    export const handler = async (event) => {
        console.log('Starting automated model retraining...');
        
        // 1. Query S3 data lake for latest sensor data
        const latestData = await aggregateTrainingData({
            bucket: process.env.DATA_LAKE_BUCKET,
            prefix: 'raw/',
            maxSamples: 500000  // Last 500k samples (~5 days)
        });
        
        // 2. Upload aggregated dataset to S3
        const trainingDataKey = `training/retrain_${Date.now()}.csv`;
        await s3.putObject({
            Bucket: process.env.DATA_LAKE_BUCKET,
            Key: trainingDataKey,
            Body: latestData
        });
        
        // 3. Start SageMaker Training Job
        const jobName = `siam-retrain-${Date.now()}`;
        const trainingJob = await sagemaker.createTrainingJob({
            TrainingJobName: jobName,
            RoleArn: process.env.SAGEMAKER_ROLE_ARN,
            AlgorithmSpecification: {
                TrainingImage: process.env.TRAINING_IMAGE_URI,
                TrainingInputMode: 'File'
            },
            InputDataConfig: [{
                ChannelName: 'training',
                DataSource: {
                    S3DataSource: {
                        S3DataType: 'S3Prefix',
                        S3Uri: `s3://${process.env.DATA_LAKE_BUCKET}/${trainingDataKey}`
                    }
                }
            }],
            OutputDataConfig: {
                S3OutputPath: `s3://${process.env.DATA_LAKE_BUCKET}/models/`
            },
            ResourceConfig: {
                InstanceType: 'ml.m5.xlarge',
                InstanceCount: 1,
                VolumeSizeInGB: 10
            },
            StoppingCondition: {
                MaxRuntimeInSeconds: 3600
            }
        });
        
        // 4. Store training job metadata in DynamoDB
        await dynamodb.putItem({
            TableName: process.env.MODEL_REGISTRY_TABLE,
            Item: {
                model_id: jobName,
                status: 'Training',
                training_data_size: latestData.length,
                started_at: new Date().toISOString()
            }
        });
        
        console.log(`Training job started: ${jobName}`);
        return { statusCode: 200, jobName };
    };
    ```
  - Implemented data aggregation logic:
    - List all sensor data files in S3 data lake
    - Filter by timestamp (last 14 days)
    - Download and combine into single CSV
    - Sample randomly if exceeds 500k records (performance optimization)
  - Added error handling and CloudWatch Logging
  - Configured Lambda timeout: 15 minutes (max)
  - Allocated memory: 512 MB

- **Deploy Lambda Implementation (deploy.mjs):**
  - Implemented automated deployment workflow:
    ```javascript
    import { EC2Client, RunInstancesCommand } from '@aws-sdk/client-ec2';
    import { GreengrassV2Client, CreateDeploymentCommand } from '@aws-sdk/client-greengrassv2';
    
    export const handler = async (event) => {
        // Event triggered by SageMaker Training Job completion
        const trainingJobName = event.detail.TrainingJobName;
        const status = event.detail.TrainingJobStatus;
        
        if (status !== 'Completed') {
            console.log(`Training job ${status}, skipping deployment`);
            return;
        }
        
        console.log(`Deploying model from ${trainingJobName}...`);
        
        // 1. Trigger EdgeTPU compilation via EC2 (EdgeTPUCompiler.sh logic)
        //    Launches t3.micro Ubuntu instance with edgetpu-compiler
        //    Downloads SageMaker model, converts to TFLite + EdgeTPU
        //    Uploads to S3: model_edgetpu_latest.tar.gz
        //    Instance self-terminates after completion (~3-5 min)
        await triggerEdgeTPUCompilation(trainingJobName);
        
        // 2. Wait for compilation to complete (poll S3 for model_edgetpu_latest.tar.gz)
        await waitForCompiledModel();
        
        // 4. Upload to Greengrass component artifact S3 bucket
        const newVersion = generateVersion();  // e.g., "1.1.0"
        await s3.putObject({
            Bucket: process.env.GREENGRASS_ARTIFACTS_BUCKET,
            Key: `com.siam.MLInference/${newVersion}/model_edgetpu.tflite`,
            Body: edgetpuModel
        });
        
        // 5. Create new Greengrass component version
        await greengrass.createComponentVersion({
            InlineRecipe: JSON.stringify({
                RecipeFormatVersion: '2020-01-25',
                ComponentName: 'com.siam.MLInference',
                ComponentVersion: newVersion,
                // ... recipe configuration
            })
        });
        
        // 6. Create Greengrass deployment
        await greengrass.createDeployment({
            TargetArn: process.env.THING_GROUP_ARN,
            DeploymentName: `ModelUpdate-${newVersion}`,
            Components: {
                'com.siam.MLInference': {
                    ComponentVersion: newVersion
                }
            }
        });
        
        // 7. Update model registry
        await dynamodb.updateItem({
            TableName: process.env.MODEL_REGISTRY_TABLE,
            Key: { model_id: trainingJobName },
            UpdateExpression: 'SET #status = :deployed, deployed_at = :now, version = :ver',
            ExpressionAttributeNames: { '#status': 'status' },
            ExpressionAttributeValues: {
                ':deployed': 'Deployed',
                ':now': new Date().toISOString(),
                ':ver': newVersion
            }
        });
        
        console.log(`Model deployed successfully: ${newVersion}`);
        return { statusCode: 200, version: newVersion };
    };
    ```
  - Integrated EdgeTPU Compiler:
    - Triggers EdgeTPUCompiler.sh workflow (EC2 t3.micro instance)
    - Instance downloads model, compiles with `edgetpu_compiler`, uploads to S3
    - Self-terminating instance (~3-5 minutes total)
  - Implemented version generation:
    - Semantic versioning: MAJOR.MINOR.PATCH
    - Auto-increment MINOR version for automated retrains
  - Added deployment verification:
    - Query Greengrass deployment status
    - Retry logic for deployment failures

- **EventBridge Component Implementation (EventBridge.sh):**
  - Created bi-weekly retrain scheduled rule:
    ```bash
    aws events put-rule \
      --name "SIAM-BiweeklyRetrain" \
      --description "Trigger model retraining every 14 days" \
      --schedule-expression "rate(14 days)" \
      --state ENABLED
    
    aws events put-targets \
      --rule "SIAM-BiweeklyRetrain" \
      --targets "Id=1,Arn=${RETRAIN_LAMBDA_ARN}"
    ```
    - Schedule: Every 14 days (rate-based rule, not cron)
    - Target: Retrain Lambda function
  
  - Created SageMaker completion event rule:
    ```bash
    aws events put-rule \
      --name "SIAM-ModelTrainingCompleted" \
      --description "Trigger deployment when training completes" \
      --event-pattern '{
        "source": ["aws.sagemaker"],
        "detail-type": ["SageMaker Training Job State Change"],
        "detail": {
          "TrainingJobStatus": ["Completed", "Failed"]
        }
      }' \
      --state ENABLED
    
    aws events put-targets \
      --rule "SIAM-ModelTrainingCompleted" \
      --targets "Id=1,Arn=${DEPLOY_LAMBDA_ARN}"
    ```
    - Event pattern: SageMaker Training Job completion
    - Target: Deploy Lambda function
  
  - Configured Lambda permissions:
    - Added EventBridge as invocation source
    - Granted `lambda:InvokeFunction` permission

- **MLOps Pipeline End-to-End Testing:**
  - **Manual Trigger Test:**
    1. Invoked Retrain Lambda via AWS Console
    2. Verified S3 data aggregation (500k samples collected)
    3. Confirmed SageMaker Training Job started: `siam-retrain-1698768000`
    4. Monitored CloudWatch Logs (training progress)
    5. Training completed in 22 minutes
    6. EventBridge rule triggered Deploy Lambda automatically
    7. Deploy Lambda executed TFLite conversion and EdgeTPU compilation
    8. Greengrass deployment created: `ModelUpdate-1.1.0`
    9. Raspberry Pi downloaded new component version
    10. MLInference component restarted with new model
    11. Verified predictions using updated model
    - **Total pipeline duration:** 28 minutes (automated)
    - **Result:**  Full MLOps pipeline successful

  - **Bi-weekly Schedule Simulation:**
    - Temporarily changed cron to trigger in 5 minutes
    - Verified EventBridge rule invoked Retrain Lambda
    - Confirmed automated workflow without manual intervention
    - Reverted cron to production schedule

- **Model Versioning System:**
  - Created DynamoDB Model Registry Table:
    - Table name: `SIAM-ModelRegistry`
    - Schema:
      ```
      model_id (String, PK)  | version (String) | status (String) | training_data_size (Number)
      started_at (String)     | completed_at (String) | deployed_at (String) | metrics (Map)
      ```
  - Enabled S3 versioning for model artifacts:
    - Bucket: `siam-demo-data-lake`
    - Prefix: `models/`
    - Retention: All versions kept (for rollback)
  - Implemented Greengrass component versioning:
    - Each retrain creates new component version (1.0.0 → 1.1.0 → 1.2.0)
    - Component recipe references specific model artifact version
  - Documented rollback procedure:
    1. Identify previous model version in DynamoDB registry
    2. Create Greengrass deployment with previous component version
    3. Greengrass downloads and installs previous model
    4. Validate predictions with test data
    - **Rollback time:** ~2 minutes

- **Model Performance Comparison:**
  - **Original Model (v1.0.0):**
    - Training data: 172,770 samples (48 hours)
    - Validation loss: 0.0198
    - Anomaly detection accuracy: 96.9%
  
  - **Retrained Model (v1.1.0):**
    - Training data: 500,000 samples (5 days)
    - Validation loss: 0.0176 (11% improvement)
    - Anomaly detection accuracy: 98.2% (1.3% improvement)
    - Model learned subtle patterns from extended dataset

### MLOps Pipeline Diagram:

```
┌──────────────────────────────────────────────────────────────┐
│ Automated MLOps Pipeline                                     │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  EventBridge        Retrain          SageMaker              │
│  (Bi-weekly)  ────▶ Lambda    ────▶  Training   ────┐       │
│  Cron Rule          (retrain.mjs)    Job          │       │
│                         │                          │       │
│                         │                          ▼       │
│                         ▼                      EventBridge  │
│                    Aggregate Data              (Completion) │
│                    from S3 Lake                    │       │
│                                                    ▼       │
│                                               Deploy Lambda │
│                                               (deploy.mjs)  │
│                                                    │       │
│                          ┌─────────────────────────┘       │
│                          │                                 │
│                          ▼                                 │
│                   Convert to TFLite                        │
│                   Compile for EdgeTPU                      │
│                   Create Greengrass                        │
│                   Deployment                               │
│                          │                                 │
│                          ▼                                 │
│                   ┌──────────────┐                         │
│                   │ Raspberry Pi │ (OTA Update)            │
│                   │ Edge Device  │                         │
│                   └──────────────┘                         │
└──────────────────────────────────────────────────────────────┘
```

### Challenges Encountered:

- **Lambda Timeout:** Retrain Lambda exceeded 3min timeout during data aggregation - increased to 15min
- **EdgeTPU Compiler in Lambda:** Compiler binary not available in Lambda - created Lambda Layer
- **Event Rule Permissions:** Lambda invocation failed initially - added EventBridge as trusted service
- **S3 Versioning Costs:** Many model versions accumulated - implemented lifecycle policy (delete after 90 days)

### Key Learnings:

- EventBridge enables truly serverless automation at scale
- Automated MLOps eliminates manual model deployment toil
- Model versioning is critical for production ML systems
- Lambda is powerful for orchestration workflows
- Greengrass OTA updates enable seamless edge model updates

### Next Week Preview:

In Week 10, I will focus on API Gateway security enhancements, implementing the monthly API key rotation automation, and building the frontend web dashboard with real-time data visualization and Swagger API documentation.
