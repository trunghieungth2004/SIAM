#!/usr/bin/env python3
"""
StreamManager-based datalogger for Greengrass
Provides offline resilience by using StreamManager for data buffering
"""

import sys
import json
import time
import subprocess
from stream_manager import (
    StreamManagerClient,
    MessageStreamDefinition,
    StrategyOnFull,
    Persistence,
    ExportDefinition,
    IoTCoreMessage,
    StreamManagerException
)

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
            print(f"[warn] StreamManager connection attempt {attempt + 1}/{max_retries} failed: {e}")
            if attempt < max_retries - 1:
                time.sleep(2)
            else:
                raise

def setup_stream(client):
    """Setup the sensor data stream with IoT Core destination"""
    try:
        # Define the stream with IoT Core export
        exports = ExportDefinition(
            iot_core=[IoTCoreMessage(
                topic_name="sensor/data",
                qos=1
            )]
        )
        
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
        print(f"[ok] Stream '{STREAM_NAME}' created/updated successfully")
        
    except StreamManagerException as e:
        if "ResourceAlreadyExistsException" in str(e):
            print(f"[info] Stream '{STREAM_NAME}' already exists")
        else:
            raise

def send_to_stream(client, data):
    """Send data to StreamManager stream"""
    try:
        client.append_message(STREAM_NAME, data.encode('utf-8'))
        return True
    except Exception as e:
        print(f"[error] Failed to send data to stream: {e}")
        return False

def read_sensor_data():
    """Read sensor data from stdin (piped from Docker container)"""
    print("[info] Reading sensor data from stdin...")
    return sys.stdin

def main():
    """Main function"""
    print("[start] StreamManager Datalogger starting...")
    
    # Create StreamManager client
    try:
        client = create_stream_manager_client()
        print("[ok] Connected to StreamManager")
    except Exception as e:
        print(f"[error] Failed to connect to StreamManager: {e}")
        sys.exit(1)
    
    # Setup the stream
    try:
        setup_stream(client)
    except Exception as e:
        print(f"[error] Failed to setup stream: {e}")
        sys.exit(1)
    
    # Read sensor data from stdin
    sensor_input = read_sensor_data()
    
    print("[info] Processing sensor data...")
    
    # Process sensor data from stdin
    try:
        for line in sensor_input:
            line = line.strip()
            if not line:
                continue
            
            # Validate JSON
            try:
                json.loads(line)
            except json.JSONDecodeError:
                print(f"[warn] Invalid JSON: {line}")
                continue
            
            # Send to StreamManager
            if send_to_stream(client, line):
                print(f"[stream] {line}")
            else:
                print(f"[failed] {line}")
                
    except KeyboardInterrupt:
        print("[info] Shutting down...")
    except Exception as e:
        print(f"[error] Unexpected error: {e}")
    finally:
        # Cleanup
        if client:
            try:
                client.close()
            except:
                pass
    
    print("[stop] StreamManager Datalogger stopped")

if __name__ == "__main__":
    main()