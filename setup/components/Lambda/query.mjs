import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand } from "@aws-sdk/lib-dynamodb";

const dynamoClient = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(dynamoClient);

const SENSOR_TABLE = process.env.DYNAMODB_TABLE_NAME;
const ML_TABLE = SENSOR_TABLE.replace('sensor-readings', 'ml-predictions');

export const handler = async (event) => {
    console.log(`Received event: ${JSON.stringify(event)}`);

    try {
        const queryParams = event.queryStringParameters || {};
        const device_id = queryParams.device_id || 'esp32-device';
        const limit = parseInt(queryParams.limit) || 50;
        const hours = parseInt(queryParams.hours) || 24;
        const type = queryParams.type || 'sensor'; // 'sensor', 'predictions', or 'both'
        
        // Calculate timestamp for time range (last N hours)
        const now = Math.floor(Date.now() / 1000);
        const startTime = now - (hours * 3600);
        
        console.log(`Querying ${type} data for device: ${device_id}, last ${hours} hours, limit: ${limit}`);
        
        let sensorData = [];
        let predictionData = [];
        
        // Query sensor data
        if (type === 'sensor' || type === 'both') {
            const sensorParams = {
                TableName: SENSOR_TABLE,
                KeyConditionExpression: 'device_id = :device_id AND #ts >= :start_time',
                ExpressionAttributeNames: { '#ts': 'timestamp' },
                ExpressionAttributeValues: {
                    ':device_id': device_id,
                    ':start_time': startTime
                },
                ScanIndexForward: false,
                Limit: limit
            };
            
            const sensorResult = await docClient.send(new QueryCommand(sensorParams));
            sensorData = sensorResult.Items.map(item => ({
                timestamp: item.timestamp,
                temp_c: item.temp_c,
                ax: item.ax, ay: item.ay, az: item.az,
                gx: item.gx, gy: item.gy, gz: item.gz,
                current_a: item.current_a,
                vibration: item.vibration,
                datetime: new Date(item.timestamp * 1000).toISOString()
            }));
        }
        
        // Query ML predictions
        if (type === 'predictions' || type === 'both') {
            const mlParams = {
                TableName: ML_TABLE,
                KeyConditionExpression: 'device_id = :device_id AND #ts >= :start_time',
                ExpressionAttributeNames: { '#ts': 'timestamp' },
                ExpressionAttributeValues: {
                    ':device_id': device_id,
                    ':start_time': startTime
                },
                ScanIndexForward: false,
                Limit: limit
            };
            
            const mlResult = await docClient.send(new QueryCommand(mlParams));
            predictionData = mlResult.Items.map(item => ({
                timestamp: item.timestamp,
                prediction: item.prediction,
                confidence: item.confidence,
                score: item.score,
                inference_type: item.inference_type,
                inference_time_ms: item.inference_time_ms,
                days_until_maintenance: item.days_until_maintenance,
                estimated_days_to_failure: item.estimated_days_to_failure,
                datetime: new Date(item.timestamp * 1000).toISOString()
            }));
        }
        
        const response = {
            device_id: device_id,
            hours: hours,
            type: type
        };
        
        if (type === 'sensor') {
            response.count = sensorData.length;
            response.data = sensorData;
        } else if (type === 'predictions') {
            response.count = predictionData.length;
            response.data = predictionData;
        } else {
            response.sensor_count = sensorData.length;
            response.prediction_count = predictionData.length;
            response.sensor_data = sensorData;
            response.prediction_data = predictionData;
        }
        
        return {
            statusCode: 200,
            headers: {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Headers': 'Content-Type',
                'Access-Control-Allow-Methods': 'GET, OPTIONS'
            },
            body: JSON.stringify(response)
        };
        
    } catch (error) {
        console.error("Error querying data:", error);
        
        return {
            statusCode: 500,
            headers: {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            body: JSON.stringify({
                error: error.message,
                message: 'Failed to query sensor data'
            })
        };
    }
};