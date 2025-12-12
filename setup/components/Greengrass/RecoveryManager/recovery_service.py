#!/usr/bin/env python3
"""
StreamManager Recovery Service for Greengrass
Monitors StreamManager streams and republishes unpublished messages to IoT Core
Provides offline resilience with automatic catch-up when connectivity is restored
"""

import os
import sys
import json
import time
import logging
from pathlib import Path
import awsiot.greengrasscoreipc
from awsiot.greengrasscoreipc.model import QOS, PublishToIoTCoreRequest
from stream_manager import (
    StreamManagerClient,
    ReadMessagesOptions,
    StreamManagerException
)

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Configuration
RECOVERY_INTERVAL_SECONDS = 60  # Check every 60 seconds
STATE_FILE_DIR = "/tmp/greengrass-recovery"
STREAMS_CONFIG = [
    {
        "stream_name": "sensor-data-stream",
        "iot_topic": "iot/data",
        "state_file": "sensor-data-recovery.json"
    },
    {
        "stream_name": "ml-predictions-stream",
        "iot_topic": "ml/predictions",
        "state_file": "ml-predictions-recovery.json"
    }
]

class RecoveryService:
    def __init__(self):
        self.sm_client = None
        self.ipc_client = None
        self.state_dir = Path(STATE_FILE_DIR)
        self.state_dir.mkdir(parents=True, exist_ok=True)
        
    def connect_streammanager(self):
        """Connect to StreamManager"""
        try:
            self.sm_client = StreamManagerClient()
            logger.info("[ok] Connected to StreamManager")
            return True
        except Exception as e:
            logger.error(f"[error] Failed to connect to StreamManager: {e}")
            return False
    
    def connect_ipc(self):
        """Connect to Greengrass IPC"""
        try:
            self.ipc_client = awsiot.greengrasscoreipc.connect()
            logger.info("[ok] Connected to Greengrass IPC")
            return True
        except Exception as e:
            logger.error(f"[error] Failed to connect to Greengrass IPC: {e}")
            return False
    
    def load_state(self, state_file):
        """Load last published sequence number from state file"""
        state_path = self.state_dir / state_file
        try:
            if state_path.exists():
                with open(state_path, 'r') as f:
                    state = json.load(f)
                    return state.get('last_published_sequence', 0)
        except Exception as e:
            logger.warning(f"[warn] Failed to load state from {state_file}: {e}")
        return 0
    
    def save_state(self, state_file, sequence_number):
        """Save last published sequence number to state file"""
        state_path = self.state_dir / state_file
        try:
            with open(state_path, 'w') as f:
                json.dump({
                    'last_published_sequence': sequence_number,
                    'last_update_time': int(time.time())
                }, f)
            logger.debug(f"[state] Saved sequence {sequence_number} to {state_file}")
        except Exception as e:
            logger.warning(f"[warn] Failed to save state to {state_file}: {e}")
    
    def test_connectivity(self):
        """Test connectivity to IoT Core by attempting a lightweight publish"""
        try:
            test_payload = json.dumps({"type": "connectivity_test", "timestamp": int(time.time())}).encode()
            request = PublishToIoTCoreRequest(
                topic_name="test/connectivity",
                qos=QOS.AT_MOST_ONCE,  # Faster, no ACK required
                payload=test_payload
            )
            operation = self.ipc_client.new_publish_to_iot_core()
            operation.activate(request)
            future = operation.get_response()
            future.result(timeout=3)
            return True
        except Exception as e:
            logger.debug(f"[connectivity] IoT Core unreachable: {e}")
            return False
    
    def publish_to_iot_core(self, topic, payload):
        """Publish message to IoT Core via IPC"""
        try:
            request = PublishToIoTCoreRequest(
                topic_name=topic,
                qos=QOS.AT_LEAST_ONCE,
                payload=payload
            )
            operation = self.ipc_client.new_publish_to_iot_core()
            operation.activate(request)
            future = operation.get_response()
            future.result(timeout=5)
            return True
        except Exception as e:
            logger.debug(f"[ipc-error] Failed to publish to {topic}: {e}")
            return False
    
    def get_stream_info(self, stream_name):
        """Get stream information including newest sequence number"""
        try:
            info = self.sm_client.describe_message_stream(stream_name)
            storage_status = info.storage_status
            return {
                'newest_sequence': storage_status.newest_sequence_number,
                'oldest_sequence': storage_status.oldest_sequence_number
            }
        except Exception as e:
            logger.debug(f"[skip] Stream {stream_name} does not exist: {e}")
            return None
    
    def recover_stream(self, stream_config):
        """Recover unpublished messages from a stream"""
        stream_name = stream_config['stream_name']
        iot_topic = stream_config['iot_topic']
        state_file = stream_config['state_file']
        
        # Load last published sequence
        last_published = self.load_state(state_file)
        
        # Get stream info
        stream_info = self.get_stream_info(stream_name)
        if not stream_info:
            logger.debug(f"[skip] Stream {stream_name} not available")
            return
        
        newest_sequence = stream_info['newest_sequence']
        oldest_sequence = stream_info['oldest_sequence']
        
        # Check if there are unpublished messages
        start_sequence = last_published + 1
        
        if start_sequence > newest_sequence:
            logger.debug(f"[ok] {stream_name}: All messages published (last={last_published}, newest={newest_sequence})")
            return
        
        # Adjust start if older messages were overwritten
        if start_sequence < oldest_sequence:
            logger.warning(f"[warn] {stream_name}: Gap detected - oldest={oldest_sequence}, last_published={last_published}")
            start_sequence = oldest_sequence
        
        messages_to_recover = newest_sequence - start_sequence + 1
        logger.info(f"[recovery] {stream_name}: Attempting to recover {messages_to_recover} messages (seq {start_sequence} to {newest_sequence})")
        
        # Read and republish messages
        recovered_count = 0
        failed_count = 0
        current_sequence = start_sequence
        
        try:
            while current_sequence <= newest_sequence:
                try:
                    # Read batch of messages
                    messages = self.sm_client.read_messages(
                        stream_name,
                        ReadMessagesOptions(
                            desired_start_sequence_number=current_sequence,
                            min_message_count=1,
                            max_message_count=10,  # Process in batches
                            read_timeout_millis=2000
                        )
                    )
                    
                    if not messages:
                        break
                    
                    for message in messages:
                        # Attempt to publish
                        if self.publish_to_iot_core(iot_topic, message.payload):
                            recovered_count += 1
                            current_sequence = message.sequence_number + 1
                            # Save progress periodically
                            if recovered_count % 10 == 0:
                                self.save_state(state_file, message.sequence_number)
                        else:
                            failed_count += 1
                            # Stop recovery if publish fails (likely still offline)
                            logger.warning(f"[recovery] {stream_name}: Publish failed at seq {message.sequence_number}, stopping recovery")
                            if recovered_count > 0:
                                self.save_state(state_file, message.sequence_number - 1)
                            return
                    
                except StreamManagerException as e:
                    logger.warning(f"[recovery] {stream_name}: Read error at seq {current_sequence}: {e}")
                    break
                
        except Exception as e:
            logger.error(f"[error] {stream_name}: Recovery error: {e}")
        
        # Save final state
        if recovered_count > 0:
            self.save_state(state_file, current_sequence - 1)
            logger.info(f"[recovery] {stream_name}: Recovered {recovered_count} messages (failed: {failed_count})")
    
    def run(self):
        """Main recovery loop"""
        logger.info("[start] Recovery Service starting...")
        
        # Connect to StreamManager
        if not self.connect_streammanager():
            logger.error("[error] Cannot start without StreamManager")
            sys.exit(1)
        
        # Connect to IPC
        if not self.connect_ipc():
            logger.error("[error] Cannot start without Greengrass IPC")
            sys.exit(1)
        
        logger.info(f"[info] Recovery interval: {RECOVERY_INTERVAL_SECONDS} seconds")
        logger.info(f"[info] Monitoring {len(STREAMS_CONFIG)} streams")
        
        try:
            while True:
                logger.debug("[check] Starting recovery check...")
                
                # Test connectivity first
                is_online = self.test_connectivity()
                if is_online:
                    logger.debug("[online] IoT Core reachable - syncing state to current position")
                    # When online, sync state to newest sequence to avoid re-publishing old data
                    for stream_config in STREAMS_CONFIG:
                        try:
                            stream_info = self.get_stream_info(stream_config['stream_name'])
                            if stream_info:
                                newest = stream_info['newest_sequence']
                                last_published = self.load_state(stream_config['state_file'])
                                # Only sync forward if we're significantly behind (more than 100 messages)
                                if newest - last_published > 100:
                                    logger.info(f"[sync] {stream_config['stream_name']}: Syncing state from {last_published} to {newest} (system online, DataLogger handling real-time)")
                                    self.save_state(stream_config['state_file'], newest)
                        except Exception as e:
                            logger.error(f"[error] State sync failed for {stream_config['stream_name']}: {e}")
                else:
                    logger.info("[offline] IoT Core unreachable - recovering buffered messages")
                    for stream_config in STREAMS_CONFIG:
                        try:
                            self.recover_stream(stream_config)
                        except Exception as e:
                            logger.error(f"[error] Recovery failed for {stream_config['stream_name']}: {e}")
                
                logger.debug(f"[sleep] Waiting {RECOVERY_INTERVAL_SECONDS} seconds until next check")
                time.sleep(RECOVERY_INTERVAL_SECONDS)
                
        except KeyboardInterrupt:
            logger.info("[info] Recovery service stopping...")
        except Exception as e:
            logger.error(f"[error] Unexpected error in recovery loop: {e}")
        finally:
            self.cleanup()
    
    def cleanup(self):
        """Cleanup resources"""
        if self.sm_client:
            try:
                self.sm_client.close()
                logger.info("[cleanup] StreamManager client closed")
            except Exception as e:
                logger.warning(f"[warn] Failed to close StreamManager client: {e}")
        
        if self.ipc_client:
            try:
                self.ipc_client.close()
                logger.info("[cleanup] IPC client closed")
            except Exception as e:
                logger.warning(f"[warn] Failed to close IPC client: {e}")
        
        logger.info("[stop] Recovery service stopped")

def main():
    service = RecoveryService()
    service.run()

if __name__ == "__main__":
    main()
