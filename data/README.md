# Sensor Data Directory

Place your sensor CSV files here for SageMaker training.

## Expected Format

Files should be named: `sensor_log_YYYYMMDD_HHMMSS.csv`

Example: `sensor_log_20241022_004612.csv`

## CSV Structure

```csv
timestamp,temp_c,ax,ay,az,gx,gy,gz,current_a
1761068772,30.38,-1488,920,15372,-328,-143,-24,0.075
1761068775,30.44,-1416,1044,15456,-305,-205,0,0.064
```

## Sensors

- **DS18B20**: Temperature sensor (temp_c)
- **MPU-6050**: Accelerometer (ax,ay,az) and Gyroscope (gx,gy,gz)  
- **INA219**: Current sensor (current_a)

## Usage

1. Copy your sensor data CSV file to this directory
2. Run SageMaker component: `./AWS.sh setup` and select component 10
3. The model will train on your data for predictive maintenance