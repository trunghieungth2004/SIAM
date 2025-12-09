// Import AWS SDK for JavaScript v3 clients
import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, PutCommand, QueryCommand } from "@aws-sdk/lib-dynamodb";
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
        
        // Check if this is an ML prediction or sensor data
        if (payload.prediction && payload.inference_type) {
            return await handleMLPrediction(payload);
        } else {
            return await handleSensorData(payload);
        }
    } catch (error) {
        console.error("Error processing data:", error);
        console.error("Error stack:", error.stack);
        
        return {
            statusCode: 500,
            body: JSON.stringify({
                error: error.message,
                event: event
            }),
        };
    }
};

async function handleMLPrediction(payload) {
    console.log(`Processing ML prediction: ${payload.prediction}`);
    
    const device_id = payload.device_id || 'unknown';
    const timestamp = payload.timestamp || Math.floor(Date.now() / 1000);
    
    // Store prediction in DynamoDB
    const predictionTable = TABLE_NAME.replace('sensor-readings', 'ml-predictions');
    console.log(`Writing prediction to DynamoDB table: ${predictionTable}`);
    
    const dynamoParams = {
        TableName: predictionTable,
        Item: {
            device_id: device_id,
            timestamp: timestamp,
            prediction: payload.prediction,
            confidence: Number(payload.confidence || 0.5),
            score: Number(payload.score || 0),
            reconstruction_error: Number(payload.reconstruction_error || 0),  // Autoencoder metric
            inference_type: payload.inference_type,
            inference_time_ms: Number(payload.inference_time_ms || 0),
            days_until_maintenance: Number(payload.days_until_maintenance || 0),
            threshold_warning: Number(payload.threshold_warning || 0),  // Anomaly threshold
            threshold_critical: Number(payload.threshold_critical || 0),  // Anomaly threshold
            ttl: timestamp + (86400 * 90) // 90 days retention
        }
    };
    
    await docClient.send(new PutCommand(dynamoParams));
    console.log("Successfully wrote ML prediction to DynamoDB.");
    
    // Store in S3 for analysis
    const date = new Date(timestamp * 1000);
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    const s3Key = `ml-predictions/${year}/${month}/${day}/${device_id}-${timestamp}.json`;
    
    const s3Params = {
        Bucket: BUCKET_NAME,
        Key: s3Key,
        Body: JSON.stringify(payload, null, 2),
        ContentType: "application/json"
    };
    await s3Client.send(new PutObjectCommand(s3Params));
    console.log("Successfully wrote ML prediction to S3.");
    
    // Anti-spike filtering: Check recent predictions to avoid alerting on single spikes
    // Query last 5 predictions from DynamoDB to check for sustained anomaly
    if (payload.score >= 50) {
        const queryParams = {
            TableName: predictionTable,
            KeyConditionExpression: 'device_id = :device_id',
            ExpressionAttributeValues: {
                ':device_id': device_id
            },
            ScanIndexForward: false,  // Descending order (newest first)
            Limit: 5
        };
        
        try {
            const recentData = await docClient.send(new QueryCommand(queryParams));
            const recentPredictions = recentData.Items || [];
            
            // Count how many recent predictions have score >= 50
            const highScoreCount = recentPredictions.filter(item => item.score >= 50).length;
            
            // Send warning if exactly 3/5, full alert if more than 3/5
            if (highScoreCount >= 3) {
                const isWarning = highScoreCount === 3;
                const alertType = isWarning ? 'WARNING' : 'SUSTAINED ANOMALY ALERT';
                const alertMessage = `${alertType} for Device ${device_id}:\n` +
                    `Status: ${payload.prediction}\n` +
                    `Confidence: ${(payload.confidence * 100).toFixed(1)}%\n` +
                    `Current Anomaly Score: ${payload.score.toFixed(1)}/100\n` +
                    `Recent High Scores: ${highScoreCount}/5 readings\n` +
                    `Reconstruction Error: ${payload.reconstruction_error?.toFixed(6) || 'N/A'}\n` +
                    `Days Until Maintenance: ${payload.days_until_maintenance || 'Unknown'}\n` +
                    `Timestamp: ${new Date(timestamp * 1000).toISOString()}`;
                
                const snsParams = {
                    TopicArn: SNS_TOPIC_ARN,
                    Message: alertMessage,
                    Subject: `${isWarning ? 'Warning' : 'Sustained Anomaly Alert'}: ${device_id} - ${payload.prediction}`
                };
                await snsClient.send(new PublishCommand(snsParams));
                console.log(`Sent ${isWarning ? 'warning' : 'sustained anomaly alert'} to SNS (${highScoreCount}/5 high scores).`);
            } else {
                console.log(`Anomaly detected but not sustained (${highScoreCount}/5 high scores). No alert sent to avoid false alarm.`);
            }
        } catch (error) {
            console.error("Error querying recent predictions:", error);
            // Fallback: send alert anyway if we can't check history
            const alertMessage = `ANOMALY ALERT for Device ${device_id}:\n` +
                `Status: ${payload.prediction}\n` +
                `Anomaly Score: ${payload.score.toFixed(1)}/100\n` +
                `Timestamp: ${new Date(timestamp * 1000).toISOString()}`;
            
            const snsParams = {
                TopicArn: SNS_TOPIC_ARN,
                Message: alertMessage,
                Subject: `Anomaly Alert: ${device_id} - ${payload.prediction}`
            };
            await snsClient.send(new PublishCommand(snsParams));
            console.log("Sent anomaly alert to SNS (fallback - couldn't check history).");
        }
    }
    
    return {
        statusCode: 200,
        body: JSON.stringify({
            message: 'ML prediction processed successfully',
            device_id: device_id,
            prediction: payload.prediction
        })
    };
}

async function handleSensorData(payload) {
    console.log(`Processing sensor data`);

        // 1. Get data from the event payload - handle both deviceId and device_id
        const device_id = payload.deviceId || payload.device_id || 'esp32-device';
        const temp_c = payload.temp_c;
        const ax = payload.ax; const ay = payload.ay; const az = payload.az;
        const gx = payload.gx; const gy = payload.gy; const gz = payload.gz;
        const current_a = payload.current_a;
        
        // Calculate derived values for compatibility
        const temperature = temp_c;
        const vibration = Math.sqrt((ax*ax + ay*ay + az*az)) / 1000; // Convert to reasonable scale
        
        console.log(`Processing data: device=${device_id}, temp=${temp_c}°C, vibration=${vibration.toFixed(2)}`);
        
        // Ensure required fields are present
        if (!device_id || temp_c === undefined || ax === undefined) {
            const errorMsg = `Missing required fields. Got: deviceId=${device_id}, temp_c=${temp_c}, ax=${ax}`;
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
                temp_c: Number(temp_c),
                ax: Number(ax), ay: Number(ay), az: Number(az),
                gx: Number(gx), gy: Number(gy), gz: Number(gz),
                current_a: Number(current_a),
                // Keep derived fields for compatibility
                temperature: Number(temperature),
                vibration: Number(vibration),
                ttl: timestamp + (86400 * 30) // Set TTL to expire in 30 days
            },
        };
        await docClient.send(new PutCommand(dynamoParams));
        console.log("Successfully wrote to DynamoDB.");

        // 3. Write raw data to S3 for backup/data lake (partitioned for ML training)
        const date = new Date();
        const year = date.getFullYear();
        const month = String(date.getMonth() + 1).padStart(2, '0');
        const day = String(date.getDate()).padStart(2, '0');
        const s3Key = `sensor-data/${year}/${month}/${day}/${device_id}-${timestamp}.json`;
        console.log(`Writing to S3 bucket: ${BUCKET_NAME}/${s3Key}`);
        const s3Data = {
            device_id: device_id,
            timestamp: timestamp,
            temp_c: Number(temp_c),
            ax: Number(ax), ay: Number(ay), az: Number(az),
            gx: Number(gx), gy: Number(gy), gz: Number(gz),
            current_a: Number(current_a),
            // Keep derived fields for compatibility
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

        // Note: Alerts are now handled exclusively by ML-based anomaly detection
        // Sensor data is stored for ML inference, no hardcoded threshold alerts

        return {
            statusCode: 200,
            body: JSON.stringify({
                message: 'Sensor data processed successfully',
                device_id: device_id,
                timestamp: timestamp,
                alerts_triggered: false // Alerts only from ML predictions
            }),
        };
}