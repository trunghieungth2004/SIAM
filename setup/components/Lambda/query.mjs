import { DynamoDBClient } from "@aws-sdk/client-dynamodb";
import { DynamoDBDocumentClient, QueryCommand, ScanCommand } from "@aws-sdk/lib-dynamodb";

const dynamoClient = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(dynamoClient);

const SENSOR_TABLE = process.env.DYNAMODB_TABLE_NAME;
const ML_TABLE = SENSOR_TABLE.replace('sensor-readings', 'ml-predictions');

// Helper function to query specific device (FAST - uses Query with pagination)
async function queryDeviceData(deviceId, type, limit) {
    const deviceData = { sensor_data: [], prediction_data: [] };
    
    if (type === 'sensor' || type === 'both') {
        try {
            let lastKey = null;
            let totalFetched = 0;
            
            do {
                const sensorParams = {
                    TableName: SENSOR_TABLE,
                    KeyConditionExpression: 'device_id = :did',
                    ExpressionAttributeValues: { ':did': deviceId },
                    ScanIndexForward: false, // DESC order (newest first)
                    Limit: Math.min(1000, limit - totalFetched) // Max 1000 per page
                };
                
                if (lastKey) {
                    sensorParams.ExclusiveStartKey = lastKey;
                }
                
                const sensorResult = await docClient.send(new QueryCommand(sensorParams));
                
                for (const item of sensorResult.Items || []) {
                    deviceData.sensor_data.push({
                        timestamp: item.timestamp,
                        temp_c: item.temp_c,
                        ax: item.ax, ay: item.ay, az: item.az,
                        gx: item.gx, gy: item.gy, gz: item.gz,
                        current_a: item.current_a,
                        vibration: item.vibration,
                        datetime: new Date(item.timestamp * 1000).toISOString()
                    });
                }
                
                totalFetched += sensorResult.Items?.length || 0;
                lastKey = sensorResult.LastEvaluatedKey;
                
            } while (lastKey && totalFetched < limit);
            
            console.log(`Queried ${totalFetched} sensor items for ${deviceId}`);
        } catch (error) {
            console.error(`Error querying sensor data for ${deviceId}:`, error);
        }
    }
    
    if (type === 'predictions' || type === 'both') {
        try {
            let lastKey = null;
            let totalFetched = 0;
            
            do {
                const mlParams = {
                    TableName: ML_TABLE,
                    KeyConditionExpression: 'device_id = :did',
                    ExpressionAttributeValues: { ':did': deviceId },
                    ScanIndexForward: false,
                    Limit: Math.min(1000, limit - totalFetched)
                };
                
                if (lastKey) {
                    mlParams.ExclusiveStartKey = lastKey;
                }
                
                const mlResult = await docClient.send(new QueryCommand(mlParams));
                
                for (const item of mlResult.Items || []) {
                    deviceData.prediction_data.push({
                        timestamp: item.timestamp,
                        prediction: item.prediction,
                        confidence: item.confidence,
                        score: item.score,
                        reconstruction_error: item.reconstruction_error,
                        threshold_warning: item.threshold_warning,
                        threshold_critical: item.threshold_critical,
                        inference_type: item.inference_type,
                        inference_time_ms: item.inference_time_ms,
                        days_until_maintenance: item.days_until_maintenance,
                        datetime: new Date(item.timestamp * 1000).toISOString()
                    });
                }
                
                totalFetched += mlResult.Items?.length || 0;
                lastKey = mlResult.LastEvaluatedKey;
                
            } while (lastKey && totalFetched < limit);
            
            console.log(`Queried ${totalFetched} ML items for ${deviceId}`);
        } catch (error) {
            console.error(`Error querying ML data for ${deviceId}:`, error);
        }
    }
    
    return deviceData;
}

// Helper function to query all devices (SLOW - uses Scan to discover devices)
async function queryAllDevices(type, startTime, limit, hours) {
    const devicesMap = new Map();
    
    // First, discover all unique device_ids with a minimal scan
    console.log('Discovering devices...');
    try {
        const discoverParams = {
            TableName: SENSOR_TABLE,
            ProjectionExpression: 'device_id',
            Limit: 100 // Just need to find unique devices
        };
        const discoverResult = await docClient.send(new ScanCommand(discoverParams));
        const deviceIds = [...new Set(discoverResult.Items?.map(item => item.device_id).filter(Boolean))];
        console.log(`Found devices: ${deviceIds.join(', ')}`);
        
        // Now query each device properly (newest first)
        for (const deviceId of deviceIds) {
            const deviceData = await queryDeviceData(deviceId, type, limit);
            devicesMap.set(deviceId, deviceData);
        }
    } catch (error) {
        console.error("Error discovering devices:", error);
        throw new Error(`Device discovery failed: ${error.message}`);
    }
    
    return devicesMap;
}

// Helper function to format response
function formatResponse(devicesMap, type, hours, limit) {
    const devices = {};
    for (const [deviceId, data] of devicesMap) {
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
        
        console.log(`Current time: ${now}, Start time: ${startTime}, Time range: ${hours} hours`);
        
        // If device_id is not specified or is 'all', query all devices
        if (!device_id || device_id === 'all') {
            console.log(`Querying ${type} data for all devices`);
            const devicesMap = await queryAllDevices(type, startTime, limit, hours);
            return formatResponse(devicesMap, type, hours, limit);
        }
        
        console.log(`Querying ${type} data for device: ${device_id}, limit: ${limit}`);
        
        const deviceData = await queryDeviceData(device_id, type, limit);
        const devicesMap = new Map([[device_id, deviceData]]);
        return formatResponse(devicesMap, type, hours, limit);
        
    } catch (error) {
        console.error("Error processing request:", error);
        return {
            statusCode: 500,
            headers: {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Headers': 'Content-Type',
                'Access-Control-Allow-Methods': 'GET, OPTIONS'
            },
            body: JSON.stringify({
                error: error.message || 'Internal server error',
                details: error.stack
            })
        };
    }
};