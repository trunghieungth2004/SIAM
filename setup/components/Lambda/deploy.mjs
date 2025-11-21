import { SageMakerClient, DescribeTrainingJobCommand } from "@aws-sdk/client-sagemaker";
import { GreengrassV2Client, CreateComponentVersionCommand, CreateDeploymentCommand } from "@aws-sdk/client-greengrassv2";
import { IoTClient, DescribeThingCommand } from "@aws-sdk/client-iot";
import { EC2Client, RunInstancesCommand } from "@aws-sdk/client-ec2";
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";

const sagemaker = new SageMakerClient({});
const greengrass = new GreengrassV2Client({});
const iot = new IoTClient({});
const ec2 = new EC2Client({});
const s3 = new S3Client({});

export const handler = async (event, context) => {
    console.log('Deploy Lambda triggered:', JSON.stringify(event, null, 2));
    
    // Get region from Lambda context
    const region = context.invokedFunctionArn.split(':')[3];
    
    try {
        const trainingJobName = event.detail.TrainingJobName;
        const projectName = process.env.PROJECT_NAME;
        
        if (!trainingJobName || !projectName) {
            throw new Error('Missing required parameters: trainingJobName or PROJECT_NAME');
        }
        
        console.log(`Processing deployment for training job: ${trainingJobName}`);
        
        const describeJobCommand = new DescribeTrainingJobCommand({
            TrainingJobName: trainingJobName
        });
        
        const trainingJobResult = await sagemaker.send(describeJobCommand);
        const modelS3Uri = trainingJobResult.ModelArtifacts.S3ModelArtifacts;
        
        console.log(`Model artifacts location: ${modelS3Uri}`);
        
         // Trigger Edge TPU compilation and wait for completion
        console.log('Triggering Edge TPU compilation...');
        const compiledModelUri = await triggerEdgeTPUCompilation(modelS3Uri, projectName, region);
        console.log(`Edge TPU compilation complete: ${compiledModelUri}`);
        
        const componentName = `com.${projectName}.MLInference`;
        const componentVersion = generateVersion();
        
        const componentRecipe = {
            RecipeFormatVersion: "2020-01-25",
            ComponentName: componentName,
            ComponentVersion: componentVersion,
            ComponentDescription: "ML inference with Edge TPU compiled model",
            ComponentPublisher: projectName,
            ComponentDependencies: {
                "aws.greengrass.StreamManager": {
                    VersionRequirement: ">=2.0.0"
                }
            },
            Manifests: [{
                Platform: { os: "linux" },
                Lifecycle: {
                    Install: {
                        RequiresPrivilege: true,
                        Script: `mkdir -p /tmp/greengrass_ml && aws s3 cp ${compiledModelUri} /tmp/model.tar.gz && tar -xzf /tmp/model.tar.gz -C /tmp/greengrass_ml/ && echo 'Edge TPU model extracted'`
                    },
                    Run: {
                        RequiresPrivilege: true,
                        Script: "docker run --rm --device=/dev/bus/usb --privileged -v /tmp/greengrass_ml:/app/models -v {artifacts:path}:/app/artifacts coral-tpu:latest python3 /app/artifacts/inference_service.py"
                    }
                },
                Artifacts: [{
                    Uri: `s3://${process.env.S3_DATA_BUCKET}/greengrass/artifacts/inference_service.py`
                }]
            }]
        };
        
        const createComponentCommand = new CreateComponentVersionCommand({
            inlineRecipe: Buffer.from(JSON.stringify(componentRecipe))
        });
        
        const componentResult = await greengrass.send(createComponentCommand);
        console.log(`Created component version: ${componentName} v${componentVersion}`);
        
        const coreDeviceThingName = `GreengrassCore_${projectName}`;
        
        try {
            await iot.send(new DescribeThingCommand({ thingName: coreDeviceThingName }));
        } catch (error) {
            throw new Error(`Greengrass core device not found: ${coreDeviceThingName}`);
        }
        
        const deploymentName = `${projectName}-auto-deploy-${Date.now()}`;
        const createDeploymentCommand = new CreateDeploymentCommand({
            targetArn: `arn:aws:iot:${region}:${process.env.ACCOUNT_ID}:thing/${coreDeviceThingName}`,
            deploymentName: deploymentName,
            components: {
                [componentName]: {
                    componentVersion: componentVersion
                }
            }
        });
        
        const deploymentResult = await greengrass.send(createDeploymentCommand);
        console.log(`Created deployment: ${deploymentResult.deploymentId}`);
        
        return {
            statusCode: 200,
            body: JSON.stringify({
                message: 'Model deployment initiated successfully',
                trainingJobName: trainingJobName,
                componentName: componentName,
                componentVersion: componentVersion,
                deploymentId: deploymentResult.deploymentId,
                modelS3Uri: modelS3Uri
            })
        };
        
    } catch (error) {
        console.error('Deployment failed:', error);
        
        return {
            statusCode: 500,
            body: JSON.stringify({
                error: 'Deployment failed',
                message: error.message
            })
        };
    }
};

function generateVersion() {
    const now = new Date();
    const timestamp = now.toISOString().replace(/[-:]/g, '').replace(/\..+/, '');
    return `1.0.${timestamp.slice(-8)}`;
}

async function triggerEdgeTPUCompilation(modelS3Uri, projectName, region) {
    const bucket = process.env.S3_DATA_BUCKET;
    const timestamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+/, '').slice(0, 15);
    const compiledModelKey = `models/model_edgetpu_${timestamp}.tar.gz`;
    const latestModelKey = 'models/model_edgetpu_latest.tar.gz';
    const compiledModelUri = `s3://${bucket}/${latestModelKey}`;
    
    const ec2Client = new EC2Client({ region });
    
    try {
        const iamRole = `EdgeTPUCompilerRole-${projectName}`;
        
    const userData = Buffer.from(`#!/bin/bash
set -e
export MODEL_S3_URI="${modelS3Uri}"
export S3_BUCKET="${bucket}"
export PROJECT_NAME="${projectName}"
export TIMESTAMP="${timestamp}"
curl -s https://raw.githubusercontent.com/google-coral/edgetpu/master/scripts/runtime/install.sh | bash
apt-get update && apt-get install -y edgetpu-compiler
aws s3 cp \${MODEL_S3_URI} /tmp/model.tar.gz
tar -xzf /tmp/model.tar.gz -C /tmp/
if [ -f /tmp/model.tflite ]; then
  edgetpu_compiler /tmp/model.tflite -o /tmp/
  cp /tmp/model_edgetpu.tflite /tmp/model.tflite
  tar -czf /tmp/model_compiled.tar.gz -C /tmp model.tflite scaler.pkl features.txt
  aws s3 cp /tmp/model_compiled.tar.gz s3://\${S3_BUCKET}/${compiledModelKey}
  aws s3 cp /tmp/model_compiled.tar.gz s3://\${S3_BUCKET}/${latestModelKey}
  echo "Edge TPU compilation complete"
fi
INSTANCE_ID=$(ec2-metadata --instance-id | cut -d' ' -f2)
aws ec2 terminate-instances --instance-ids \$INSTANCE_ID --region ${region}
`).toString('base64');
    
        const runInstancesCmd = new RunInstancesCommand({
            ImageId: 'ami-0c55b159cbfafe1f0',
            InstanceType: 't3.micro',
            MinCount: 1,
            MaxCount: 1,
            IamInstanceProfile: { Name: iamRole },
            UserData: userData,
            TagSpecifications: [{
                ResourceType: 'instance',
                Tags: [{ Key: 'Name', Value: `edgetpu-compiler-${projectName}` }, { Key: 'Project', Value: projectName }]
            }]
        });
        
        await ec2Client.send(runInstancesCmd);
        console.log('Edge TPU compiler EC2 instance launched - compilation will complete asynchronously');
        
        // Return immediately - don't wait for compilation
        return compiledModelUri;
        
    } catch (error) {
        console.error('Edge TPU compilation trigger failed:', error);
        throw new Error(`Edge TPU compilation failed: ${error.message}`);
    }
}