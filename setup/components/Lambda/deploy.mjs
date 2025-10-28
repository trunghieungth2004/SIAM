import { SageMakerClient, DescribeTrainingJobCommand } from "@aws-sdk/client-sagemaker";
import { GreengrassV2Client, CreateComponentVersionCommand, CreateDeploymentCommand } from "@aws-sdk/client-greengrassv2";
import { IoTClient, DescribeThingCommand } from "@aws-sdk/client-iot";

const sagemaker = new SageMakerClient({});
const greengrass = new GreengrassV2Client({});
const iot = new IoTClient({});

export const handler = async (event) => {
    console.log('Deploy Lambda triggered:', JSON.stringify(event, null, 2));
    
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
        
        const componentName = `com.${projectName}.MLInference`;
        const componentVersion = generateVersion();
        
        const componentRecipe = {
            RecipeFormatVersion: "2020-01-25",
            ComponentName: componentName,
            ComponentVersion: componentVersion,
            ComponentDescription: "ML inference with updated model from SageMaker",
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
                        Script: `mkdir -p /tmp/greengrass_ml; tar -xzf {artifacts:path}/model.tar.gz -C /tmp/greengrass_ml/ && echo 'Updated model extracted successfully'`
                    },
                    Run: {
                        RequiresPrivilege: true,
                        Script: "docker run --rm --device=/dev/bus/usb --privileged -v /tmp/greengrass_ml:/app/models -v {artifacts:path}:/app/artifacts coral-tpu:latest python3 /app/artifacts/inference_service.py"
                    }
                },
                Artifacts: [{
                    Uri: modelS3Uri,
                    Unarchive: "NONE"
                }, {
                    Uri: `s3://${process.env.S3_DATA_BUCKET}/greengrass/artifacts/inference_service.py`
                }, {
                    Uri: `s3://${process.env.S3_DATA_BUCKET}/greengrass/artifacts/convert_model_to_tflite.py`
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
            targetArn: `arn:aws:iot:${process.env.AWS_REGION}:${process.env.ACCOUNT_ID}:thing/${coreDeviceThingName}`,
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