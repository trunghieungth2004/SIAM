import { SageMakerClient, CreateTrainingJobCommand } from "@aws-sdk/client-sagemaker";
import { S3Client, ListObjectsV2Command, GetObjectCommand, PutObjectCommand, ListBucketsCommand } from "@aws-sdk/client-s3";
import { IAMClient, GetRoleCommand } from "@aws-sdk/client-iam";

const sagemaker = new SageMakerClient({});
const s3 = new S3Client({});
const iam = new IAMClient({});

export const handler = async (event) => {
    const projectName = process.env.PROJECT_NAME;
    const region = process.env.AWS_REGION;
    const jobName = `${projectName}-maintenance-${Date.now()}`;
    
    console.log(`Starting retraining for project: ${projectName}`);
    
    // Discover S3 data bucket
    const projectClean = projectName.toLowerCase().replace(/_/g, '-');
    const bucketsCmd = new ListBucketsCommand({});
    const bucketsResult = await s3.send(bucketsCmd);
    const bucket = bucketsResult.Buckets.find(b => 
        b.Name.includes(projectClean) && b.Name.includes('iot-data')
    )?.Name;
    
    if (!bucket) {
        throw new Error(`S3 data bucket not found for project: ${projectName}`);
    }
    console.log(`Discovered S3 bucket: ${bucket}`);
    
    // Get SageMaker execution role
    const roleName = `SageMakerExecutionRole-${projectName}`;
    const getRoleCmd = new GetRoleCommand({RoleName: roleName});
    const roleResult = await iam.send(getRoleCmd);
    const roleArn = roleResult.Role.Arn;
    console.log(`Using SageMaker role: ${roleArn}`);
    
    // Aggregate new sensor data into training CSV
    console.log('Aggregating sensor data from S3...');
    const listCmd = new ListObjectsV2Command({
        Bucket: bucket, 
        Prefix: 'sensor-data/', 
        MaxKeys: 1000
    });
    const objects = await s3.send(listCmd);
    
    let csvData = 'timestamp,temp_c,ax,ay,az,gx,gy,gz,current_a\n';
    let count = 0;
    
    for (const obj of (objects.Contents || [])) {
        if (!obj.Key.endsWith('.json')) continue;
        try {
            const getCmd = new GetObjectCommand({Bucket: bucket, Key: obj.Key});
            const response = await s3.send(getCmd);
            const data = JSON.parse(await response.Body.transformToString());
            csvData += `${data.timestamp},${data.temp_c},${data.ax},${data.ay},${data.az},${data.gx},${data.gy},${data.gz},${data.current_a}\n`;
            count++;
            if (count >= 500) break; // Limit to 500 samples
        } catch (e) { 
            console.log(`Skip ${obj.Key}: ${e.message}`); 
        }
    }
    
    if (count < 10) {
        console.log('Not enough data for retraining');
        return {
            statusCode: 400, 
            body: JSON.stringify({
                error: 'Insufficient data for training', 
                count: count,
                message: 'At least 10 samples required'
            })
        };
    }
    
    // Upload aggregated training data
    const putCmd = new PutObjectCommand({
        Bucket: bucket, 
        Key: 'sagemaker/training-data/training.csv', 
        Body: csvData
    });
    await s3.send(putCmd);
    console.log(`Aggregated ${count} samples for training`);
    
    // Create training job
    const cmd = new CreateTrainingJobCommand({
        TrainingJobName: jobName,
        RoleArn: roleArn,
        AlgorithmSpecification: {
            TrainingImage: `763104351884.dkr.ecr.${region}.amazonaws.com/tensorflow-training:2.13-cpu-py310`,
            TrainingInputMode: "File"
        },
        InputDataConfig: [{
            ChannelName: "training", 
            DataSource: {
                S3DataSource: {
                    S3DataType: "S3Prefix", 
                    S3Uri: `s3://${bucket}/sagemaker/training-data/`, 
                    S3DataDistributionType: "FullyReplicated"
                }
            }
        }],
        OutputDataConfig: {
            S3OutputPath: `s3://${bucket}/sagemaker/output/`
        },
        ResourceConfig: {
            InstanceType: "ml.m5.large", 
            InstanceCount: 1, 
            VolumeSizeInGB: 10
        },
        StoppingCondition: {
            MaxRuntimeInSeconds: 3600
        },
        HyperParameters: {
            sagemaker_program: "train.py", 
            sagemaker_submit_directory: `s3://${bucket}/sagemaker/code/sourcedir.tar.gz`
        }
    });
    
    await sagemaker.send(cmd);
    console.log(`Training job started: ${jobName}`);
    
    return {
        statusCode: 200, 
        body: JSON.stringify({
            message: 'Training started successfully', 
            jobName: jobName, 
            samples: count,
            bucket: bucket
        })
    };
};
