import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand, ScanCommand } from "@aws-sdk/lib-dynamodb";

const dynamoClient = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(dynamoClient);

const SENSOR_TABLE = process.env.DYNAMODB_TABLE_NAME;
const ML_TABLE = SENSOR_TABLE.replace('sensor-readings', 'ml-predictions');

// Helper function to query all devices
async function queryAllDevices(type, startTime, limit, hours) {
    const devicesMap = new Map();
    
    // Scan sensor table to discover all devices
    if (type === 'sensor' || type === 'both') {
        const sensorScanParams = {
            TableName: SENSOR_TABLE,
            FilterExpression: '#ts >= :start_time',
            ExpressionAttributeNames: { '#ts': 'timestamp' },
            ExpressionAttributeValues: { ':start_time': startTime },
            Limit: 1000
        };
        
        const sensorResult = await docClient.send(new ScanCommand(sensorScanParams));
        
        // Group by device_id
        for (const item of sensorResult.Items) {
            if (!devicesMap.has(item.device_id)) {
                devicesMap.set(item.device_id, { sensor_data: [], prediction_data: [] });
            }
            devicesMap.get(item.device_id).sensor_data.push({
                timestamp: item.timestamp,
                temp_c: item.temp_c,
                ax: item.ax, ay: item.ay, az: item.az,
                gx: item.gx, gy: item.gy, gz: item.gz,
                current_a: item.current_a,
                vibration: item.vibration,
                datetime: new Date(item.timestamp * 1000).toISOString()
            });
        }
    }
    
    // Scan ML predictions table
    if (type === 'predictions' || type === 'both') {
        const mlScanParams = {
            TableName: ML_TABLE,
            FilterExpression: '#ts >= :start_time',
            ExpressionAttributeNames: { '#ts': 'timestamp' },
            ExpressionAttributeValues: { ':start_time': startTime },
            Limit: 1000
        };
        
        const mlResult = await docClient.send(new ScanCommand(mlScanParams));
        
        for (const item of mlResult.Items) {
            if (!devicesMap.has(item.device_id)) {
                devicesMap.set(item.device_id, { sensor_data: [], prediction_data: [] });
            }
            devicesMap.get(item.device_id).prediction_data.push({
                timestamp: item.timestamp,
                prediction: item.prediction,
                confidence: item.confidence,
                score: item.score,
                inference_type: item.inference_type,
                inference_time_ms: item.inference_time_ms,
                days_until_maintenance: item.days_until_maintenance,
                estimated_days_to_failure: item.estimated_days_to_failure,
                datetime: new Date(item.timestamp * 1000).toISOString()
            });
        }
    }
    
    // Sort and limit data for each device
    const devices = {};
    for (const [deviceId, data] of devicesMap) {
        data.sensor_data.sort((a, b) => b.timestamp - a.timestamp);
        data.prediction_data.sort((a, b) => b.timestamp - a.timestamp);
        
        devices[deviceId] = {
            device_id: deviceId,
            sensor_count: data.sensor_data.length,
            prediction_count: data.prediction_data.length,
            sensor_data: data.sensor_data.slice(0, limit),
            prediction_data: data.prediction_data.slice(0, limit)
        };
    }
    
    return {
        statusCode: 200,
        headers: {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type',
            'Access-Control-Allow-Methods': 'GET, OPTIONS'
        },
        body: JSON.stringify({
            type: type,
            hours: hours,
            device_count: devicesMap.size,
            devices: devices
        })
    };
}

export const handler = async (event) => {
    console.log(`Received event: ${JSON.stringify(event)}`);

    try {
        const queryParams = event.queryStringParameters || {};
        const device_id = queryParams.device_id;
        const limit = parseInt(queryParams.limit) || 50;
        const hours = parseInt(queryParams.hours) || 24;
        const type = queryParams.type || 'sensor'; // 'sensor', 'predictions', or 'both'
        
        // Calculate timestamp for time range (last N hours)
        const now = Math.floor(Date.now() / 1000);
        const startTime = now - (hours * 3600);
        
        // If device_id is not specified or is 'all', query all devices
        if (!device_id || device_id === 'all') {
            console.log(`Querying ${type} data for all devices, last ${hours} hours`);
            return await queryAllDevices(type, startTime, limit, hours);
        }
        
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