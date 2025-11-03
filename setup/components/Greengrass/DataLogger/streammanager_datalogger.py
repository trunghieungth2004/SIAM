import sys
import json
import time
import logging
import awsiot.greengrasscoreipc
import awsiot.greengrasscoreipc.client as ipc_client
from awsiot.greengrasscoreipc.model import (
    QOS,
    PublishToIoTCoreRequest
)
from stream_manager import (
    StreamManagerClient,
    MessageStreamDefinition,
    StrategyOnFull,
    Persistence,
    ExportDefinition,
    StreamManagerException
)
from awsiot.greengrasscoreipc.model import IoTCoreMessage

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

STREAM_NAME = "sensor-data-stream"
STREAMMANAGER_PORT = 8088

def create_stream_manager_client():
    """Create StreamManager client with retry logic"""
    max_retries = 5
    for attempt in range(max_retries):
        try:
            client = StreamManagerClient(port=STREAMMANAGER_PORT)
            return client
        except Exception as e:
            logger.warning(f"[warn] StreamManager connection attempt {attempt + 1}/{max_retries} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(2)
            else:
                raise

def setup_stream(client):
    """Setup the sensor data stream with IoT Core destination"""
    try:
        # Define the stream with IoT Core export
        exports = ExportDefinition()
        
        stream_definition = MessageStreamDefinition(
            name=STREAM_NAME,
            strategy_on_full=StrategyOnFull.OverwriteOldestData,
            persistence=Persistence.File,
            max_size=268435456,  # 256 MB
            stream_segment_size=16777216,  # 16 MB
            time_to_live_millis=604800000,  # 7 days
            export_definition=exports
        )
        
        # Create or update the stream
        client.create_message_stream(stream_definition)
        logger.info(f"[ok] Stream '{STREAM_NAME}' created/updated successfully")
        
    except StreamManagerException as e:
        if "ResourceAlreadyExistsException" in str(e):
            logger.info(f"[info] Stream '{STREAM_NAME}' already exists")
        else:
            raise

def send_to_stream(client, data):
    """Send data to StreamManager stream"""
    try:
        client.append_message(STREAM_NAME, data.encode('utf-8'))
        return True
    except Exception as e:
        logger.error(f"[error] Failed to send data to stream: {e}")
        return False

def read_sensor_data():
    """Read sensor data from stdin (piped from Docker container)"""
    logger.info("[info] Reading sensor data from stdin...")
    return sys.stdin

def publish_to_iot_core(ipc_client_instance, topic, qos, payload):
    """Publish message to IoT Core via Greengrass IPC"""
    try:
        request = PublishToIoTCoreRequest(
            topic_name=topic,
            qos=qos,
            payload=payload
        )
        future = ipc_client_instance.publish_to_iot_core(request=request)
        future.result(timeout=5) # Wait for the publish operation to complete
        logger.info(f"[ipc] Published to IoT Core topic '{topic}' with QoS {qos.name}")
        return True
    except Exception as e:
        logger.error(f"[ipc-error] Failed to publish to IoT Core: {e}")
        return False

def main():
    """Main function"""
    time.sleep(5) # Add a delay to allow datalogger.c to start producing output
    logger.info("[start] StreamManager Datalogger starting...")
    
    # Initialize StreamManager client
    sm_client = None
    try:
        sm_client = create_stream_manager_client()
        logger.info("[ok] Connected to StreamManager")
    except Exception as e:
        logger.error(f"[error] Failed to connect to StreamManager: {e}")
        sys.exit(1)
    
    # Setup the stream
    try:
        setup_stream(sm_client)
    except Exception as e:
        logger.error(f"[error] Failed to setup stream: {e}")
        sys.exit(1)

    # Initialize Greengrass IPC client
    ipc_client_instance = None
    try:
        ipc_client_instance = awsiot.greengrasscoreipc.connect()
        logger.info("[ok] Connected to Greengrass IPC")
    except Exception as e:
        logger.error(f"[error] Failed to connect to Greengrass IPC: {e}")
        sys.exit(1)
    
    # Read sensor data from stdin
    sensor_input = read_sensor_data()
    
    logger.info("[info] Processing sensor data...")
    
    # Process sensor data from stdin
    try:
        for line in sensor_input:
            line = line.strip()
            if not line:
                continue
            
            logger.debug(f"[debug] Received raw line: {line}") # Log raw input
            
            # Validate JSON
            try:
                json_data = json.loads(line)
            except json.JSONDecodeError:
                logger.warning(f"[warn] Invalid JSON: {line}")
                continue
            
            # Append to StreamManager
            if sm_client and sm_client.append_message(STREAM_NAME, line.encode('utf-8')):
                logger.info(f"[stream] Appended to StreamManager: {line}")
            else:
                logger.error(f"[stream-failed] Failed to append to StreamManager: {line}")
            
            # Publish to IoT Core via IPC
            iot_topic = f"sensor/data/{json_data.get('device_id', 'unknown')}"
            if ipc_client_instance and publish_to_iot_core(ipc_client_instance, iot_topic, QOS.AT_LEAST_ONCE, line.encode('utf-8')):
                logger.info(f"[ipc] Published to IoT Core: {line}")
            else:
                logger.error(f"[ipc-failed] Failed to publish to IoT Core: {line}")
                
    except KeyboardInterrupt:
        logger.info("[info] Shutting down...")
    except Exception as e:
        logger.error(f"[error] Unexpected error: {e}")
    finally:
        # Cleanup StreamManager client
        if sm_client:
            try:
                sm_client.close()
            except Exception as e:
                logger.warning(f"[warn] Failed to close StreamManager client: {e}")
        # Cleanup IPC client
        if ipc_client_instance:
            try:
                ipc_client_instance.close()
            except Exception as e:
                logger.warning(f"[warn] Failed to close Greengrass IPC client: {e}")
    
    logger.info("[stop] StreamManager Datalogger stopped")