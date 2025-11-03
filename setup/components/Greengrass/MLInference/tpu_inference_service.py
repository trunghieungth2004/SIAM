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
        """Load TensorFlow Lite model for TPU"""
        try:
            import tflite_runtime.interpreter as tflite
            from pycoral.utils import edgetpu
            import pickle
            
            # Look for .tflite model file
            tflite_files = list(self.model_path.glob("*.tflite"))
            if not tflite_files:
                logger.error("No .tflite model found - TPU model required")
                return False
            
            model_file = tflite_files[0]
            logger.info(f"Loading TPU model: {model_file}")
            
            # Create Edge TPU interpreter
            self.tpu_interpreter = tflite.Interpreter(
                model_path=str(model_file),
                experimental_delegates=[tflite.load_delegate('libedgetpu.so.1')]
            )
            self.tpu_interpreter.allocate_tensors()
            
            # Get input/output details
            self.input_details = self.tpu_interpreter.get_input_details()
            self.output_details = self.tpu_interpreter.get_output_details()
            
            # Load scaler (required from SageMaker)
            scaler_file = self.model_path / "scaler.pkl"
            if scaler_file.exists():
                with open(scaler_file, 'rb') as f:
                    self.scaler = pickle.load(f)
                logger.info("Loaded scaler for TPU model")
            else:
                logger.error("No scaler.pkl found - SageMaker scaler required")
                return False
            
            logger.info("TPU model loaded successfully")
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
        """Run inference on TPU"""
        try:
            # Scale features with SageMaker scaler
            features_scaled = self.scaler.transform(features).astype(np.float32)
            
            # Set input tensor
            self.tpu_interpreter.set_tensor(
                self.input_details[0]['index'], 
                features_scaled
            )
            
            # Run inference
            self.tpu_interpreter.invoke()
            
            # Get output
            output = self.tpu_interpreter.get_tensor(self.output_details[0]['index'])
            prediction = float(output[0][0])
            
            # Convert SageMaker maintenance score to status
            if prediction < 30:
                status = "Good"
                confidence = 0.9
            elif prediction < 60:
                status = "Monitor" 
                confidence = 0.7
            else:
                status = "Maintenance Required"
                confidence = 0.8
            
            return {
                'prediction': status,
                'confidence': confidence,
                'score': prediction,
                'inference_type': 'tpu'
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
    
    logger.info("Inference service ready, waiting for sensor data...")
    
    # Process sensor data from stdin
    try:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            
            try:
                # Parse sensor data
                sensor_data = json.loads(line)
                
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
                
                # Output prediction
                print(json.dumps(result))
                sys.stdout.flush()
                
            except json.JSONDecodeError:
                logger.warning(f"Invalid JSON: {line}")
            except Exception as e:
                logger.error(f"Processing error: {e}")
                
    except KeyboardInterrupt:
        logger.info("Inference service stopped")
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()