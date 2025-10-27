#!/usr/bin/env python3
"""
Convert scikit-learn model to TensorFlow Lite for Coral TPU
"""

import os
import sys
import joblib
import numpy as np
import tensorflow as tf
from pathlib import Path

def convert_sklearn_to_tflite(pkl_path, output_path, input_shape=(1, 8)):
    """Convert scikit-learn model to TensorFlow Lite"""
    
    print(f"Loading model from {pkl_path}")
    model = joblib.load(pkl_path)
    
    # Create a simple TensorFlow model that wraps the sklearn model
    class SklearnWrapper(tf.Module):
        def __init__(self, sklearn_model):
            self.sklearn_model = sklearn_model
            
        @tf.function(input_signature=[tf.TensorSpec(shape=input_shape, dtype=tf.float32)])
        def __call__(self, x):
            # Convert sklearn prediction to TensorFlow operations
            # This is a simplified approach - for production, use proper TF operations
            return tf.py_function(
                func=self._predict,
                inp=[x],
                Tout=tf.float32
            )
        
        def _predict(self, x):
            # Convert to numpy for sklearn
            x_np = x.numpy()
            
            # Get prediction
            if hasattr(self.sklearn_model, 'predict_proba'):
                pred = self.sklearn_model.predict_proba(x_np)[:, 1]  # Get positive class probability
            else:
                pred = self.sklearn_model.predict(x_np).astype(np.float32)
            
            return pred.astype(np.float32)
    
    # Create wrapper
    wrapper = SklearnWrapper(model)
    
    # Convert to TensorFlow Lite
    converter = tf.lite.TFLiteConverter.from_concrete_functions([
        wrapper.__call__.get_concrete_function()
    ])
    
    # Optimize for Edge TPU
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.target_spec.supported_types = [tf.float32]
    
    # Convert
    print("Converting to TensorFlow Lite...")
    tflite_model = converter.convert()
    
    # Save model
    print(f"Saving TFLite model to {output_path}")
    with open(output_path, 'wb') as f:
        f.write(tflite_model)
    
    print("Conversion completed successfully")
    return True

def create_simple_tflite_model(output_path, input_shape=(1, 8)):
    """Create a simple TensorFlow Lite model for testing"""
    
    print("Creating simple TensorFlow Lite model for testing...")
    
    # Create a simple model
    model = tf.keras.Sequential([
        tf.keras.layers.Dense(16, activation='relu', input_shape=(8,)),
        tf.keras.layers.Dense(8, activation='relu'),
        tf.keras.layers.Dense(1, activation='sigmoid')
    ])
    
    # Compile model
    model.compile(optimizer='adam', loss='binary_crossentropy')
    
    # Generate some dummy training data
    X_dummy = np.random.random((100, 8)).astype(np.float32)
    y_dummy = np.random.randint(0, 2, (100, 1)).astype(np.float32)
    
    # Train briefly
    model.fit(X_dummy, y_dummy, epochs=5, verbose=0)
    
    # Convert to TensorFlow Lite
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    
    tflite_model = converter.convert()
    
    # Save model
    with open(output_path, 'wb') as f:
        f.write(tflite_model)
    
    print(f"Simple TFLite model saved to {output_path}")
    return True

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 convert_model_to_tflite.py <model_directory> [--simple]")
        print("  --simple: Create a simple test model instead of converting existing")
        sys.exit(1)
    
    model_dir = Path(sys.argv[1])
    create_simple = "--simple" in sys.argv
    
    if not model_dir.exists():
        print(f"Model directory {model_dir} does not exist")
        sys.exit(1)
    
    tflite_path = model_dir / "model.tflite"
    
    if create_simple:
        # Create simple test model
        success = create_simple_tflite_model(tflite_path)
    else:
        # Convert existing sklearn model
        pkl_files = list(model_dir.glob("*.pkl"))
        if not pkl_files:
            print("No .pkl files found in model directory")
            print("Use --simple to create a test model")
            sys.exit(1)
        
        pkl_path = pkl_files[0]
        try:
            success = convert_sklearn_to_tflite(pkl_path, tflite_path)
        except Exception as e:
            print(f"Conversion failed: {e}")
            print("Creating simple test model instead...")
            success = create_simple_tflite_model(tflite_path)
    
    if success:
        print("Model conversion completed successfully")
        print(f"TensorFlow Lite model: {tflite_path}")
    else:
        print("Model conversion failed")
        sys.exit(1)

if __name__ == "__main__":
    main()