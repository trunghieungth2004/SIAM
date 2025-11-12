#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>
#include <unistd.h>
#include <stdint.h>
#include <time.h>
#include <dirent.h>
#include <math.h>
#include <signal.h>

const char *I2C_BUS = "/dev/i2c-1";
const int MPU6050_ADDR = 0x68;
const int INA219_ADDR = 0x40;
const uint8_t MPU6050_REG_PWR_MGMT_1 = 0x6B;
const uint8_t MPU6050_REG_ACCEL_XOUT_H = 0x3B;
const uint8_t INA219_REG_CURRENT = 0x04;
const char *ONE_WIRE_BASE_DIR = "/sys/bus/w1/devices/";
const int LOG_INTERVAL_S = 3;

volatile sig_atomic_t running = 1;

// Global variable to store the 1-Wire device path
char one_wire_device_path[256] = {0};

// Function to discover the 1-Wire device path
void discover_one_wire_device() {
    DIR *dir = opendir(ONE_WIRE_BASE_DIR);
    if (!dir) {
        fprintf(stderr, "Error: Could not open 1-Wire base directory %s\n", ONE_WIRE_BASE_DIR);
        return;
    }
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, "28-", 3) == 0) {
            snprintf(one_wire_device_path, sizeof(one_wire_device_path), "%s%s/w1_slave", ONE_WIRE_BASE_DIR, entry->d_name);
            break; // Found it, no need to search further
        }
    }
    closedir(dir);
    if (one_wire_device_path[0] == 0) {
        fprintf(stderr, "Warning: No 1-Wire temperature sensor found in %s\n", ONE_WIRE_BASE_DIR);
    }
}

void signal_handler(int sig) {
    running = 0;
}

int16_t read_i2c_register_16(int file, uint8_t reg) {
    if (write(file, &reg, 1) != 1) return 0;
    unsigned char data[2];
    if (read(file, data, 2) != 2) return 0;
    return (int16_t)((data[0] << 8) | data[1]);
}

void write_i2c_register_16(int file, uint8_t reg, uint16_t value) {
    unsigned char data[3] = {reg, (value >> 8) & 0xFF, value & 0xFF};
    write(file, data, 3);
}

float read_temperature() {
    if (one_wire_device_path[0] == 0) { // If device not found or not initialized
        return -999.0f;
    }

    FILE *f = fopen(one_wire_device_path, "r");
    if (!f) return -999.0f;

    char line[128];
    fgets(line, sizeof(line), f);
    if (strstr(line, "YES")) {
        fgets(line, sizeof(line), f);
        char *t = strstr(line, "t=");
        if (t) {
            fclose(f);
            return atoi(t + 2) / 1000.0f;
        }
    }
    fclose(f);
    return -999.0f;
}

int main(int argc, char *argv[]) {
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    discover_one_wire_device();
    
    int i2c_file = open(I2C_BUS, O_RDWR);
    if (i2c_file < 0) {
        fprintf(stderr, "Error: Could not open I2C bus %s. Ensure it is enabled and permissions are correct.\n", I2C_BUS);
        return 1;
    }
    
    // Initialize MPU6050
    if (ioctl(i2c_file, I2C_SLAVE, MPU6050_ADDR) >= 0) {
        uint8_t power_cmd[2] = {MPU6050_REG_PWR_MGMT_1, 0x00};
        if (write(i2c_file, power_cmd, 2) != 2) {
            fprintf(stderr, "Error: Could not initialize MPU6050 power management.\n");
            close(i2c_file);
            return 1;
        }
        usleep(100000);
    } else {
        fprintf(stderr, "Error: Could not initialize MPU6050. Ensure it is connected and I2C address is correct.\n");
        close(i2c_file);
        return 1;
    }
    
    // Initialize INA219
    if (ioctl(i2c_file, I2C_SLAVE, INA219_ADDR) >= 0) {
        write_i2c_register_16(i2c_file, 0x00, 0x399F);
        write_i2c_register_16(i2c_file, 0x05, 4096);
    } else {
        fprintf(stderr, "Error: Could not initialize INA219. Ensure it is connected and I2C address is correct.\n");
        close(i2c_file);
        return 1;
    }
    
    // Print CSV header
    printf("timestamp,temp_c,ax,ay,az,gx,gy,gz,current_a\n");
    fflush(stdout);
    
    while (running) {
        time_t timestamp = time(NULL);
        float temp_c = read_temperature();
        
        int16_t ax = 0, ay = 0, az = 0, gx = 0, gy = 0, gz = 0;
        float current_a = 0.0f;
        
        // Read MPU6050
        if (ioctl(i2c_file, I2C_SLAVE, MPU6050_ADDR) >= 0) {
            char start_reg = MPU6050_REG_ACCEL_XOUT_H;
            if (write(i2c_file, &start_reg, 1) == 1) {
                unsigned char data[14];
                if (read(i2c_file, data, 14) == 14) {
                    ax = (int16_t)((data[0] << 8) | data[1]);
                    ay = (int16_t)((data[2] << 8) | data[3]);
                    az = (int16_t)((data[4] << 8) | data[5]);
                    gx = (int16_t)((data[8] << 8) | data[9]);
                    gy = (int16_t)((data[10] << 8) | data[11]);
                    gz = (int16_t)((data[12] << 8) | data[13]);
                }
            }
        }
        
        // Read INA219
        if (ioctl(i2c_file, I2C_SLAVE, INA219_ADDR) >= 0) {
            int16_t current_raw = read_i2c_register_16(i2c_file, INA219_REG_CURRENT);
            current_a = (float)current_raw * 0.0001f;
            if (fabs(current_a) < 0.001f) current_a = 0.0f;
        }
        
        // Output CSV format (without device_id to match SageMaker training format)
        printf("%ld,%.2f,%d,%d,%d,%d,%d,%d,%.3f\n",
               timestamp, temp_c, ax, ay, az, gx, gy, gz, current_a);
        fflush(stdout);
        
        sleep(LOG_INTERVAL_S);
    }
    
    close(i2c_file);
    return 0;
}
