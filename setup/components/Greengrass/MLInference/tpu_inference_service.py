#!/usr/bin/env python3
"""
TPU-accelerated ML inference service for Greengrass
Supports both Coral TPU and CPU fallback for predictive maintenance
"""

import os
import sys
import json
import time
import logging
import numpy as np
from pathlib import Path
import awsiot.greengrasscoreipc
from awsiot.greengrasscoreipc.model import QOS, PublishToIoTCoreRequest

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class TPUInferenceService:
    def __init__(self, model_path="/app/models"):
        self.model_path = Path(model_path)
        self.tpu_interpreter = None
        self.scaler = None
        self.model_loaded = False
        
        # Load TPU model
        self.load_model()
    
    def detect_tpu(self):
        """Detect if Coral TPU is available"""
        try:
            from pycoral.utils import edgetpu
            devices = edgetpu.list_edge_tpus()
            if devices:
                logger.info(f"Detected {len(devices)} Edge TPU device(s)")
                return True
            else:
                logger.error("No Edge TPU devices detected - TPU required")
                return False
        except ImportError:
            logger.error("pycoral not available - TPU required")
            return False
        except Exception as e:
            logger.error(f"TPU detection failed: {e} - TPU required")
            return False
    
    def load_tpu_model(self):
        """Load TensorFlow Lite autoencoder model for TPU"""
        try:
            import tflite_runtime.interpreter as tflite
            from pycoral.utils import edgetpu
            import pickle
            import json
            
            # Look for .tflite model file
            tflite_files = list(self.model_path.glob("*.tflite"))
            if not tflite_files:
                logger.error("No .tflite model found - TPU model required")
                return False
            
            model_file = tflite_files[0]
            logger.info(f"Loading TPU autoencoder model: {model_file}")
            
            # Create Edge TPU interpreter
            self.tpu_interpreter = tflite.Interpreter(
                model_path=str(model_file),
                experimental_delegates=[tflite.load_delegate('libedgetpu.so.1')]
            )
            self.tpu_interpreter.allocate_tensors()
            
            # Get input/output details
            self.input_details = self.tpu_interpreter.get_input_details()
            self.output_details = self.tpu_interpreter.get_output_details()
            
            # Load scaler and thresholds (required from SageMaker)
            scaler_file = self.model_path / "scaler.pkl"
            thresholds_file = self.model_path / "thresholds.json"
            
            if scaler_file.exists():
                with open(scaler_file, 'rb') as f:
                    self.scaler = pickle.load(f)
                logger.info("Loaded feature scaler for TPU model")
            else:
                logger.error("No scaler.pkl found - SageMaker scaler required")
                return False
            
            if thresholds_file.exists():
                with open(thresholds_file, 'r') as f:
                    self.thresholds = json.load(f)
                logger.info(f"Loaded anomaly thresholds: warning={self.thresholds['threshold_warning']:.6f}, critical={self.thresholds['threshold_critical']:.6f}")
            else:
                logger.error("No thresholds.json found - SageMaker thresholds required")
                return False
            
            logger.info("TPU autoencoder model loaded successfully")
            return True
            
        except Exception as e:
            logger.error(f"Failed to load TPU model: {e}")
            return False
    

    
    def load_model(self):
        """Load TPU model"""
        if not self.detect_tpu():
            logger.error("TPU not available - cannot continue")
            return False
            
        if self.load_tpu_model():
            logger.info("TPU model loaded successfully")
            self.model_loaded = True
            return True
        else:
            logger.error("Failed to load TPU model")
            return False
    
    def preprocess_data(self, sensor_data):
        """Preprocess sensor data for inference - matches SageMaker feature engineering"""
        try:
            # Extract raw sensor values
            temp_c = sensor_data.get('temp_c', 25.0)
            ax = sensor_data.get('ax', 0)
            ay = sensor_data.get('ay', 0) 
            az = sensor_data.get('az', 16384)
            gx = sensor_data.get('gx', 0)
            gy = sensor_data.get('gy', 0)
            gz = sensor_data.get('gz', 0)
            current_a = sensor_data.get('current_a', 0.1)
            
            # Feature engineering - matches SageMaker training script
            vibration_magnitude = np.sqrt(ax**2 + ay**2 + az**2)
            gyro_magnitude = np.sqrt(gx**2 + gy**2 + gz**2)
            temp_deviation = abs(temp_c - 25.0)
            power_indicator = current_a * 12.0
            
            # Features in same order as SageMaker training
            features = [
                temp_c,
                vibration_magnitude,
                gyro_magnitude, 
                temp_deviation,
                power_indicator,
                current_a
            ]
            
            return np.array(features, dtype=np.float32).reshape(1, -1)
            
        except Exception as e:
            logger.error(f"Data preprocessing failed: {e}")
            return None
    
    def predict_tpu(self, features):
        """Run anomaly detection on TPU using autoencoder reconstruction error"""
        try:
            # Scale features with SageMaker scaler
            features_scaled = self.scaler.transform(features).astype(np.float32)
            
            # Quantize input if model uses INT8
            if self.input_details[0]['dtype'] == np.uint8:
                input_scale, input_zero_point = self.input_details[0]['quantization']
                features_quantized = (features_scaled / input_scale + input_zero_point).astype(np.uint8)
                self.tpu_interpreter.set_tensor(self.input_details[0]['index'], features_quantized)
            else:
                self.tpu_interpreter.set_tensor(self.input_details[0]['index'], features_scaled)
            
            # Run autoencoder inference (reconstruct input)
            self.tpu_interpreter.invoke()
            
            # Get reconstructed output
            reconstructed_data = self.tpu_interpreter.get_tensor(self.output_details[0]['index'])
            
            # Dequantize output if model uses INT8
            if self.output_details[0]['dtype'] == np.uint8:
                output_scale, output_zero_point = self.output_details[0]['quantization']
                reconstructed = (reconstructed_data.astype(np.float32) - output_zero_point) * output_scale
            else:
                reconstructed = reconstructed_data.astype(np.float32)
            
            # Calculate reconstruction error (MSE)
            reconstruction_error = float(np.mean(np.square(features_scaled - reconstructed)))
            
            # Anomaly detection based on reconstruction error thresholds
            threshold_warning = self.thresholds['threshold_warning']
            threshold_critical = self.thresholds['threshold_critical']
            
            if reconstruction_error < threshold_warning:
                status = "Normal"
                anomaly_score = (reconstruction_error / threshold_warning) * 30  # 0-30 range
                confidence = 0.95
                days_until_maintenance = 90
            elif reconstruction_error < threshold_critical:
                status = "Warning"
                anomaly_score = 30 + ((reconstruction_error - threshold_warning) / (threshold_critical - threshold_warning)) * 40  # 30-70 range
                confidence = 0.80
                days_until_maintenance = 30
            else:
                status = "Anomaly Detected"
                anomaly_score = min(100, 70 + ((reconstruction_error - threshold_critical) / threshold_critical) * 30)  # 70-100 range
                confidence = 0.90
                days_until_maintenance = 7
            
            return {
                'prediction': status,
                'confidence': confidence,
                'score': anomaly_score,
                'reconstruction_error': reconstruction_error,
                'days_until_maintenance': days_until_maintenance,
                'threshold_warning': threshold_warning,
                'threshold_critical': threshold_critical,
                'inference_type': 'tpu-autoencoder'
            }
            
        except Exception as e:
            logger.error(f"TPU inference failed: {e}")
            return None
    

    
    def predict(self, sensor_data):
        """Run inference on sensor data"""
        if not self.model_loaded:
            return {
                'prediction': 'error',
                'confidence': 0.0,
                'error': 'TPU model not loaded',
                'inference_type': 'none'
            }
        
        # Preprocess data
        features = self.preprocess_data(sensor_data)
        if features is None:
            return {
                'prediction': 'error',
                'confidence': 0.0,
                'error': 'Data preprocessing failed',
                'inference_type': 'none'
            }
        
        # Run TPU inference
        result = self.predict_tpu(features)
        
        if result is None:
            return {
                'prediction': 'error',
                'confidence': 0.0,
                'error': 'TPU inference failed',
                'inference_type': 'none'
            }
        
        return result

def main():
    """Main inference service loop"""
    logger.info("Starting TPU Inference Service...")
    
    # Initialize inference service
    inference_service = TPUInferenceService()
    
    if not inference_service.model_loaded:
        logger.error("Failed to load model, exiting")
        sys.exit(1)
    
    if inference_service.tpu_interpreter is None:
        logger.error("TPU model not loaded - cannot continue")
        sys.exit(1)
    
    # Connect to Greengrass IPC
    try:
        ipc_client = awsiot.greengrasscoreipc.connect()
        logger.info("Connected to Greengrass IPC")
    except Exception as e:
        logger.error(f"Failed to connect to IPC: {e}")
        sys.exit(1)
    
    # Connect to StreamManager
    try:
        from stream_manager import (
            StreamManagerClient,
            ReadMessagesOptions,
            MessageStreamDefinition,
            StrategyOnFull,
            Persistence
        )
        sm_client = StreamManagerClient()
        logger.info("Connected to StreamManager")
        
        # Create predictions stream for local buffering
        try:
            predictions_stream = MessageStreamDefinition(
                name="ml-predictions-stream",
                strategy_on_full=StrategyOnFull.OverwriteOldestData,
                persistence=Persistence.File,
                max_size=268435456,  # 256 MB
                stream_segment_size=16777216,  # 16 MB
                time_to_live_millis=604800000  # 7 days
            )
            sm_client.create_message_stream(predictions_stream)
            logger.info("Created ml-predictions-stream for local buffering")
        except Exception as e:
            if "already exists" not in str(e).lower():
                logger.warning(f"Failed to create predictions stream: {e}")
            else:
                logger.info("ml-predictions-stream already exists")
    except Exception as e:
        logger.error(f"Failed to connect to StreamManager: {e}")
        sys.exit(1)
    
    logger.info("Inference service ready, reading from StreamManager...")
    
    STREAM_NAME = "sensor-data-stream"
    PREDICTIONS_STREAM = "ml-predictions-stream"
    sequence_number = 0
    
    try:
        while True:
            try:
                # Read from StreamManager
                messages = sm_client.read_messages(
                    STREAM_NAME,
                    ReadMessagesOptions(desired_start_sequence_number=sequence_number, min_message_count=1, read_timeout_millis=5000)
                )
                
                for message in messages:
                    try:
                        # Parse sensor data
                        sensor_data = json.loads(message.payload.decode('utf-8'))
                        
                        # Run inference
                        start_time = time.time()
                        result = inference_service.predict(sensor_data)
                        inference_time = (time.time() - start_time) * 1000  # ms
                        
                        # Add metadata
                        result.update({
                            'timestamp': sensor_data.get('timestamp', int(time.time())),
                            'device_id': sensor_data.get('device_id', 'unknown'),
                            'inference_time_ms': round(inference_time, 2)
                        })
                        
                        # Cache prediction in StreamManager
                        try:
                            sm_client.append_message(PREDICTIONS_STREAM, json.dumps(result).encode('utf-8'))
                            logger.info(f"Prediction cached: {result['prediction']} (score: {result['score']:.1f})")
                        except Exception as e:
                            logger.warning(f"Failed to cache prediction: {e}")
                        
                        # Publish to IoT Core via IPC
                        try:
                            request = PublishToIoTCoreRequest(
                                topic_name="ml/predictions",
                                qos=QOS.AT_LEAST_ONCE,
                                payload=json.dumps(result).encode('utf-8')
                            )
                            operation = ipc_client.new_publish_to_iot_core()
                            operation.activate(request)
                            future = operation.get_response()
                            future.result(timeout=5)
                            logger.info(f"Published prediction: {result['prediction']} (score: {result['score']:.1f})")
                        except Exception as e:
                            logger.error(f"Failed to publish to IoT Core: {e}")
                        
                        sequence_number = message.sequence_number + 1
                        
                    except json.JSONDecodeError as e:
                        logger.warning(f"Invalid JSON in message: {e}")
                    except Exception as e:
                        logger.error(f"Processing error: {e}")
                
                time.sleep(3)
                
            except Exception as e:
                logger.error(f"StreamManager read error: {e}")
                time.sleep(5)
                
    except KeyboardInterrupt:
        logger.info("Inference service stopped")
    finally:
        sm_client.close()

if __name__ == "__main__":
    main()