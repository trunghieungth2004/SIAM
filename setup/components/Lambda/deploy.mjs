import { SageMakerClient, DescribeTrainingJobCommand } from "@aws-sdk/client-sagemaker";
import { GreengrassV2Client, CreateComponentVersionCommand, CreateDeploymentCommand } from "@aws-sdk/client-greengrassv2";
import { IoTClient, DescribeThingCommand } from "@aws-sdk/client-iot";
import { 
    EC2Client, 
    RunInstancesCommand, 
    DescribeImagesCommand,
    DescribeVpcsCommand,
    CreateVpcCommand,
    CreateSubnetCommand,
    CreateInternetGatewayCommand,
    AttachInternetGatewayCommand,
    CreateRouteTableCommand,
    CreateRouteCommand,
    AssociateRouteTableCommand,
    CreateSecurityGroupCommand,
    AuthorizeSecurityGroupEgressCommand,
    ModifyVpcAttributeCommand,
    ModifySubnetAttributeCommand,
    CreateTagsCommand
} from "@aws-sdk/client-ec2";
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
        // Get Ubuntu 22.04 AMI for current region
        const describeImagesCmd = new DescribeImagesCommand({
            Owners: ['099720109477'],
            Filters: [
                { Name: 'name', Values: ['ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*'] },
                { Name: 'state', Values: ['available'] }
            ]
        });
        const imagesResult = await ec2Client.send(describeImagesCmd);
        const sortedImages = imagesResult.Images.sort((a, b) => 
            new Date(b.CreationDate) - new Date(a.CreationDate)
        );
        const amiId = sortedImages[0].ImageId;
        console.log(`Using AMI: ${amiId}`);
        
        // Check for default VPC
        const describeVpcsCmd = new DescribeVpcsCommand({
            Filters: [{ Name: 'is-default', Values: ['true'] }]
        });
        const vpcsResult = await ec2Client.send(describeVpcsCmd);
        
        let useSubnet = null;
        let useSecurityGroup = null;
        let tempVpcCreated = false;
        let tempVpcId, tempSubnetId, tempIgwId, tempRtId, tempSgId;
        
        // Create temporary VPC if no default VPC exists
        if (!vpcsResult.Vpcs || vpcsResult.Vpcs.length === 0) {
            console.log('No default VPC found, creating temporary VPC...');
            
            // Create VPC
            const createVpcCmd = new CreateVpcCommand({ CidrBlock: '10.99.0.0/16' });
            const vpcResult = await ec2Client.send(createVpcCmd);
            tempVpcId = vpcResult.Vpc.VpcId;
            
            // Tag VPC
            await ec2Client.send(new CreateTagsCommand({
                Resources: [tempVpcId],
                Tags: [
                    { Key: 'Name', Value: `temp-compiler-${projectName}` },
                    { Key: 'Project', Value: projectName }
                ]
            }));
            
            // Enable DNS hostnames
            await ec2Client.send(new ModifyVpcAttributeCommand({
                VpcId: tempVpcId,
                EnableDnsHostnames: { Value: true }
            }));
            
            // Create subnet
            const createSubnetCmd = new CreateSubnetCommand({
                VpcId: tempVpcId,
                CidrBlock: '10.99.0.0/24'
            });
            const subnetResult = await ec2Client.send(createSubnetCmd);
            tempSubnetId = subnetResult.Subnet.SubnetId;
            
            // Enable auto-assign public IP
            await ec2Client.send(new ModifySubnetAttributeCommand({
                SubnetId: tempSubnetId,
                MapPublicIpOnLaunch: { Value: true }
            }));
            
            // Create Internet Gateway
            const createIgwCmd = new CreateInternetGatewayCommand({});
            const igwResult = await ec2Client.send(createIgwCmd);
            tempIgwId = igwResult.InternetGateway.InternetGatewayId;
            
            // Attach IGW to VPC
            await ec2Client.send(new AttachInternetGatewayCommand({
                InternetGatewayId: tempIgwId,
                VpcId: tempVpcId
            }));
            
            // Create route table
            const createRtCmd = new CreateRouteTableCommand({ VpcId: tempVpcId });
            const rtResult = await ec2Client.send(createRtCmd);
            tempRtId = rtResult.RouteTable.RouteTableId;
            
            // Create route to IGW
            await ec2Client.send(new CreateRouteCommand({
                RouteTableId: tempRtId,
                DestinationCidrBlock: '0.0.0.0/0',
                GatewayId: tempIgwId
            }));
            
            // Associate route table with subnet
            await ec2Client.send(new AssociateRouteTableCommand({
                SubnetId: tempSubnetId,
                RouteTableId: tempRtId
            }));
            
            // Create security group
            const createSgCmd = new CreateSecurityGroupCommand({
                GroupName: 'temp-compiler-sg',
                Description: 'Temp SG for compiler',
                VpcId: tempVpcId
            });
            const sgResult = await ec2Client.send(createSgCmd);
            tempSgId = sgResult.GroupId;
            
            // Allow all outbound traffic
            await ec2Client.send(new AuthorizeSecurityGroupEgressCommand({
                GroupId: tempSgId,
                IpPermissions: [{
                    IpProtocol: '-1',
                    IpRanges: [{ CidrIp: '0.0.0.0/0' }]
                }]
            }));
            
            useSubnet = tempSubnetId;
            useSecurityGroup = tempSgId;
            tempVpcCreated = true;
            
            console.log('Temporary VPC created successfully');
        }
        
        const iamRole = `EdgeTPUCompilerRole-${projectName}`;
        
        // Build VPC cleanup script if temporary VPC was created
        let vpcCleanupScript = '';
        if (tempVpcCreated) {
            vpcCleanupScript = `
echo "[cleanup] Deleting temporary VPC resources..."

# Delete security group
echo "[cleanup] Deleting security group ${tempSgId}..."
aws ec2 delete-security-group --group-id ${tempSgId} --region "\${AWS_REGION}" 2>/dev/null || echo "[warn] SG cleanup skipped"
while aws ec2 describe-security-groups --group-ids ${tempSgId} --region "\${AWS_REGION}" &>/dev/null; do
    echo "[wait] Waiting for security group to be deleted..."
    sleep 5
done
echo "[ok] Security group deleted"

# Detach and delete internet gateway
echo "[cleanup] Detaching internet gateway ${tempIgwId}..."
aws ec2 detach-internet-gateway --internet-gateway-id ${tempIgwId} --vpc-id ${tempVpcId} --region "\${AWS_REGION}" 2>/dev/null || echo "[warn] IGW detach skipped"
while aws ec2 describe-internet-gateways --internet-gateway-ids ${tempIgwId} --query 'InternetGateways[0].Attachments' --output text --region "\${AWS_REGION}" 2>/dev/null | grep -q .; do
    echo "[wait] Waiting for IGW to detach..."
    sleep 5
done
echo "[ok] Internet gateway detached"

echo "[cleanup] Deleting internet gateway ${tempIgwId}..."
aws ec2 delete-internet-gateway --internet-gateway-id ${tempIgwId} --region "\${AWS_REGION}" 2>/dev/null || echo "[warn] IGW cleanup skipped"
while aws ec2 describe-internet-gateways --internet-gateway-ids ${tempIgwId} --region "\${AWS_REGION}" &>/dev/null; do
    echo "[wait] Waiting for internet gateway to be deleted..."
    sleep 5
done
echo "[ok] Internet gateway deleted"

# Delete subnet
echo "[cleanup] Deleting subnet ${tempSubnetId}..."
aws ec2 delete-subnet --subnet-id ${tempSubnetId} --region "\${AWS_REGION}" 2>/dev/null || echo "[warn] Subnet cleanup skipped"
while aws ec2 describe-subnets --subnet-ids ${tempSubnetId} --region "\${AWS_REGION}" &>/dev/null; do
    echo "[wait] Waiting for subnet to be deleted..."
    sleep 5
done
echo "[ok] Subnet deleted"

# Delete route table
echo "[cleanup] Deleting route table ${tempRtId}..."
aws ec2 delete-route-table --route-table-id ${tempRtId} --region "\${AWS_REGION}" 2>/dev/null || echo "[warn] RT cleanup skipped"
while aws ec2 describe-route-tables --route-table-ids ${tempRtId} --region "\${AWS_REGION}" &>/dev/null; do
    echo "[wait] Waiting for route table to be deleted..."
    sleep 5
done
echo "[ok] Route table deleted"

# Delete VPC
echo "[cleanup] Deleting VPC ${tempVpcId}..."
aws ec2 delete-vpc --vpc-id ${tempVpcId} --region "\${AWS_REGION}" 2>/dev/null || echo "[warn] VPC cleanup skipped"
while aws ec2 describe-vpcs --vpc-ids ${tempVpcId} --region "\${AWS_REGION}" &>/dev/null; do
    echo "[wait] Waiting for VPC to be deleted..."
    sleep 5
done
echo "[ok] VPC deleted"

echo "[cleanup] Temporary VPC cleanup complete"
`;
        }
        
        const userData = Buffer.from(`#!/bin/bash
exec > >(tee /var/log/user-data.log)
exec 2>&1
set -e

MODEL_S3_URI="${modelS3Uri}"
S3_BUCKET="${bucket}"
AWS_REGION="${region}"
INSTANCE_ID=$(ec2-metadata --instance-id 2>/dev/null | cut -d' ' -f2)
[ -z "$INSTANCE_ID" ] && INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)

echo "[1/7] Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y curl gnupg awscli

echo "[2/7] Adding Coral repository..."
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | tee /usr/share/keyrings/coral-edgetpu.asc
echo "deb [signed-by=/usr/share/keyrings/coral-edgetpu.asc] https://packages.cloud.google.com/apt coral-edgetpu-stable main" > /etc/apt/sources.list.d/coral-edgetpu.list

echo "[3/7] Installing edgetpu-compiler..."
apt-get update -qq
apt-get install -y edgetpu-compiler

echo "[4/7] Downloading model from S3..."
mkdir -p /tmp/compile
cd /tmp/compile
if ! aws s3 cp "\${MODEL_S3_URI}" model.tar.gz --region "\${AWS_REGION}"; then
    echo "[ERROR] Failed to download model from S3"
    ${vpcCleanupScript}
    aws ec2 terminate-instances --instance-ids "\${INSTANCE_ID}" --region "\${AWS_REGION}"
    exit 1
fi
tar -xzf model.tar.gz

if [ ! -f "model.tflite" ]; then
    echo "[ERROR] model.tflite not found in archive"
    ls -la
    ${vpcCleanupScript}
    aws ec2 terminate-instances --instance-ids "\${INSTANCE_ID}" --region "\${AWS_REGION}"
    exit 1
fi

if [ ! -f "thresholds.json" ]; then
    echo "[ERROR] thresholds.json not found in archive"
    ls -la
    ${vpcCleanupScript}
    aws ec2 terminate-instances --instance-ids "\${INSTANCE_ID}" --region "\${AWS_REGION}"
    exit 1
fi

echo "[5/7] Compiling model for Edge TPU..."
if ! edgetpu_compiler model.tflite; then
    echo "[ERROR] edgetpu_compiler failed"
    ${vpcCleanupScript}
    aws ec2 terminate-instances --instance-ids "\${INSTANCE_ID}" --region "\${AWS_REGION}"
    exit 1
fi

if [ ! -f "model_edgetpu.tflite" ]; then
    echo "[ERROR] Compilation failed - model_edgetpu.tflite not created"
    ${vpcCleanupScript}
    aws ec2 terminate-instances --instance-ids "\${INSTANCE_ID}" --region "\${AWS_REGION}"
    exit 1
fi

echo "[6/7] Uploading compiled model..."
cp model_edgetpu.tflite model.tflite
tar -czf model_compiled.tar.gz model.tflite scaler.pkl thresholds.json features.txt
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
COMPILED_S3="s3://\${S3_BUCKET}/models/model_edgetpu_\${TIMESTAMP}.tar.gz"
LATEST_S3="s3://\${S3_BUCKET}/models/model_edgetpu_latest.tar.gz"
aws s3 cp model_compiled.tar.gz "\${COMPILED_S3}" --region "\${AWS_REGION}"
aws s3 cp model_compiled.tar.gz "\${LATEST_S3}" --region "\${AWS_REGION}"

echo "[7/7] Cleanup and termination..."
${vpcCleanupScript}
aws ec2 terminate-instances --instance-ids "\${INSTANCE_ID}" --region "\${AWS_REGION}"
`).toString('base64');
        
        const runInstancesParams = {
            ImageId: amiId,
            InstanceType: 't3.micro',
            MinCount: 1,
            MaxCount: 1,
            IamInstanceProfile: { Name: iamRole },
            UserData: userData,
            TagSpecifications: [{
                ResourceType: 'instance',
                Tags: [
                    { Key: 'Name', Value: 'EdgeTPU-Compiler' },
                    { Key: 'Project', Value: projectName }
                ]
            }]
        };
        
        // Add VPC configuration if temporary VPC was created
        if (tempVpcCreated) {
            runInstancesParams.SubnetId = useSubnet;
            runInstancesParams.SecurityGroupIds = [useSecurityGroup];
            runInstancesParams.TagSpecifications[0].Tags.push({ Key: 'TempVPC', Value: 'true' });
        } else {
            runInstancesParams.NetworkInterfaces = [{
                DeviceIndex: 0,
                AssociatePublicIpAddress: true
            }];
        }
        
        const runInstancesCmd = new RunInstancesCommand(runInstancesParams);
        const instanceResult = await ec2Client.send(runInstancesCmd);
        const instanceId = instanceResult.Instances[0].InstanceId;
        
        console.log(`Edge TPU compiler EC2 instance launched: ${instanceId}`);
        console.log('Instance will self-terminate after compilation (~3-5 minutes)');
        
        // Return compiled model URI (compilation happens asynchronously)
        return compiledModelUri;
        
    } catch (error) {
        console.error('Edge TPU compilation trigger failed:', error);
        throw new Error(`Edge TPU compilation failed: ${error.message}`);
    }
}