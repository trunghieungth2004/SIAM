import { APIGatewayClient, GetRestApisCommand, GetUsagePlansCommand, GetUsagePlanKeysCommand, CreateApiKeyCommand, GetApiKeyCommand, CreateUsagePlanKeyCommand, DeleteUsagePlanKeyCommand, DeleteApiKeyCommand } from "@aws-sdk/client-api-gateway";
import { S3Client, GetObjectCommand, PutObjectCommand, ListBucketsCommand } from "@aws-sdk/client-s3";

const apigw = new APIGatewayClient({});
const s3 = new S3Client({});

export const handler = async (event) => {
    const projectName = process.env.PROJECT_NAME;
    const region = process.env.AWS_REGION;
    const apiName = `${projectName}-api`;
    const usagePlanName = `${projectName}-dashboard-plan`;
    
    console.log(`Starting API key rotation for project: ${projectName}`);
    
    // Discover frontend bucket
    let frontendBucket = null;
    try {
        const projectClean = projectName.toLowerCase().replace(/_/g, '-');
        const bucketsCmd = new ListBucketsCommand({});
        const bucketsResult = await s3.send(bucketsCmd);
        frontendBucket = bucketsResult.Buckets.find(b => 
            b.Name.includes(projectClean) && b.Name.includes('frontend')
        )?.Name;
        
        if (frontendBucket) {
            console.log(`Discovered frontend bucket: ${frontendBucket}`);
        } else {
            console.log('No frontend bucket found, will skip frontend update');
        }
    } catch (e) {
        console.log(`Frontend bucket discovery failed: ${e.message}`);
    }
    
    // Find API Gateway
    console.log('Finding API Gateway...');
    const apisCmd = new GetRestApisCommand({});
    const apis = await apigw.send(apisCmd);
    const api = apis.items.find(a => a.name === apiName);
    if (!api) throw new Error(`API ${apiName} not found`);
    const apiUrl = `https://${api.id}.execute-api.${region}.amazonaws.com/prod/data`;
    console.log(`Found API: ${api.id}`);
    
    // Find usage plan
    const plansCmd = new GetUsagePlansCommand({});
    const plans = await apigw.send(plansCmd);
    const plan = plans.items.find(p => p.name === usagePlanName);
    if (!plan) throw new Error(`Usage plan ${usagePlanName} not found`);
    console.log(`Found usage plan: ${plan.id}`);
    
    // Get current API key
    const keysCmd = new GetUsagePlanKeysCommand({usagePlanId: plan.id});
    const keys = await apigw.send(keysCmd);
    const oldKeyId = keys.items?.[0]?.id;
    console.log(`Current key: ${oldKeyId || 'none'}`);
    
    // Create new API key
    const timestamp = Date.now();
    const createKeyCmd = new CreateApiKeyCommand({
        name: `${projectName}-dashboard-key-${timestamp}`,
        description: 'API key for SIAM dashboard (rotated)',
        enabled: true
    });
    const newKey = await apigw.send(createKeyCmd);
    const getKeyCmd = new GetApiKeyCommand({apiKey: newKey.id, includeValue: true});
    const keyDetails = await apigw.send(getKeyCmd);
    const newKeyValue = keyDetails.value;
    console.log(`Created new key: ${newKey.id}`);
    
    // Associate with usage plan
    const assocCmd = new CreateUsagePlanKeyCommand({
        usagePlanId: plan.id,
        keyId: newKey.id,
        keyType: 'API_KEY'
    });
    await apigw.send(assocCmd);
    console.log('New key associated with usage plan');
    
    // Update frontend if bucket exists
    if (frontendBucket) {
        try {
            const getCmd = new GetObjectCommand({Bucket: frontendBucket, Key: 'app.js'});
            const appjs = await s3.send(getCmd);
            let content = await appjs.Body.transformToString();
            content = content.replace(/const API_KEY = '[^']*'/, `const API_KEY = '${newKeyValue}'`);
            const putCmd = new PutObjectCommand({
                Bucket: frontendBucket, 
                Key: 'app.js', 
                Body: content, 
                ContentType: 'application/javascript'
            });
            await s3.send(putCmd);
            console.log('Frontend updated with new API key');
        } catch (e) {
            console.log(`Frontend update failed: ${e.message}`);
        }
    }
    
    // Remove old key
    if (oldKeyId) {
        try {
            const delPlanKeyCmd = new DeleteUsagePlanKeyCommand({usagePlanId: plan.id, keyId: oldKeyId});
            await apigw.send(delPlanKeyCmd);
            const delKeyCmd = new DeleteApiKeyCommand({apiKey: oldKeyId});
            await apigw.send(delKeyCmd);
            console.log(`Deleted old key: ${oldKeyId}`);
        } catch (e) {
            console.log(`Old key cleanup failed: ${e.message}`);
        }
    }
    
    return {
        statusCode: 200, 
        body: JSON.stringify({
            message: 'API key rotated successfully',
            apiId: api.id,
            apiUrl: apiUrl,
            oldKeyId: oldKeyId,
            newKeyId: newKey.id,
            frontendUpdated: !!frontendBucket
        })
    };
};
