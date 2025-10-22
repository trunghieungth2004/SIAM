// Import AWS SDK for JavaScript v3 clients
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand } from "@aws-sdk/lib-dynamodb";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";

// Initialize AWS clients outside the handler for best practices
const dynamoClient = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(dynamoClient);
const s3Client = new S3Client({});
const snsClient = new SNSClient({});

// Get resource names from environment variables
const TABLE_NAME = process.env.DYNAMODB_TABLE_NAME;
const BUCKET_NAME = process.env.S3_BUCKET_NAME;
const SNS_TOPIC_ARN = process.env.SNS_TOPIC_ARN;

export const handler = async (event) => {
    console.log(`Received event: ${JSON.stringify(event)}`);

    try {
        // Handle IoT Core message format - extract payload if needed
        let payload = event;
        if (event.Records && event.Records[0] && event.Records[0].Sns) {
            // SNS trigger
            payload = JSON.parse(event.Records[0].Sns.Message);
        } else if (typeof event === 'string') {
            // String payload
            payload = JSON.parse(event);
        }

        // 1. Get data from the event payload - handle both deviceId and device_id
        const device_id = payload.deviceId || payload.device_id;
        const temperature = payload.temperature;
        const vibration = payload.vibration;
        
        console.log(`Processing data: device=${device_id}, temp=${temperature}, vib=${vibration}`);
        
        // Ensure required fields are present
        if (!device_id || temperature === undefined || vibration === undefined) {
            const errorMsg = `Missing required fields. Got: deviceId=${device_id}, temperature=${temperature}, vibration=${vibration}`;
            console.error(errorMsg);
            throw new Error(errorMsg);
        }
        
        // Get current timestamp as a number (Unix epoch seconds)
        const timestamp = Math.floor(Date.now() / 1000);

        // 2. Write to DynamoDB
        console.log(`Writing to DynamoDB table: ${TABLE_NAME}`);
        const dynamoParams = {
            TableName: TABLE_NAME,
            Item: {
                device_id: device_id,
                timestamp: timestamp,
                temperature: Number(temperature),
                vibration: Number(vibration),
                ttl: timestamp + (86400 * 30) // Set TTL to expire in 30 days
            },
        };
        await docClient.send(new PutCommand(dynamoParams));
        console.log("Successfully wrote to DynamoDB.");

        // 3. Write raw data to S3 for backup/data lake
        const s3Key = `raw-data/${device_id}/${new Date().toISOString().split('T')[0]}/${timestamp}.json`;
        console.log(`Writing to S3 bucket: ${BUCKET_NAME}/${s3Key}`);
        const s3Data = {
            device_id: device_id,
            timestamp: timestamp,
            temperature: Number(temperature),
            vibration: Number(vibration),
            raw_event: payload
        };
        const s3Params = {
            Bucket: BUCKET_NAME,
            Key: s3Key,
            Body: JSON.stringify(s3Data, null, 2),
            ContentType: "application/json",
        };
        await s3Client.send(new PutObjectCommand(s3Params));
        console.log("Successfully wrote to S3.");

        // 4. Check for alert conditions and publish to SNS
        const tempAlert = Number(temperature) > 35; // Lowered threshold for testing
        const vibAlert = Number(vibration) > 10;    // Example vibration threshold
        
        if (tempAlert || vibAlert) {
            let alertMessage = `ALERT for Device ${device_id}:\n`;
            if (tempAlert) alertMessage += `- High temperature: ${temperature}°C\n`;
            if (vibAlert) alertMessage += `- High vibration: ${vibration}\n`;
            alertMessage += `Timestamp: ${new Date(timestamp * 1000).toISOString()}`;
            
            console.log(`Sending alert: ${alertMessage}`);
            const snsParams = {
                TopicArn: SNS_TOPIC_ARN,
                Message: alertMessage,
                Subject: `IoT Alert for ${device_id}`,
            };
            await snsClient.send(new PublishCommand(snsParams));
            console.log("Successfully published to SNS.");
        }

        return {
            statusCode: 200,
            body: JSON.stringify({
                message: 'Data processed successfully!',
                device_id: device_id,
                timestamp: timestamp,
                alerts_triggered: tempAlert || vibAlert
            }),
        };

    } catch (error) {
        console.error("Error processing data:", error);
        console.error("Error stack:", error.stack);
        
        // Return error response for better debugging
        return {
            statusCode: 500,
            body: JSON.stringify({
                error: error.message,
                event: event
            }),
        };
    }
};