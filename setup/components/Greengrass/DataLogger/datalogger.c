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
#include <gpiod.h>
#include <math.h>
#include <signal.h>
#include <sys/stat.h>

const char *I2C_BUS = "/dev/i2c-1";
const int MPU6050_ADDR = 0x68;
const int INA219_ADDR = 0x40;
const uint8_t MPU6050_REG_PWR_MGMT_1 = 0x6B;
const uint8_t MPU6050_REG_ACCEL_XOUT_H = 0x3B;
const uint8_t INA219_REG_CURRENT = 0x04;
const char *ONE_WIRE_BASE_DIR = "/sys/bus/w1/devices/";
const int LOG_INTERVAL_S = 3;
const int LED_R_PIN = 17;
const int LED_G_PIN = 27;
const int LED_B_PIN = 22;

struct gpiod_chip *gpio_chip;
struct gpiod_line_request *line_request;
volatile sig_atomic_t running = 1;

void signal_handler(int sig) {
    running = 0;
}

void init_leds() {
    gpio_chip = gpiod_chip_open("/dev/gpiochip0");
    if (!gpio_chip) {
        fprintf(stderr, "Error: Could not open GPIO chip /dev/gpiochip0. Ensure it is enabled and permissions are correct.\n");
        exit(1);
    }
    
    struct gpiod_request_config *req_cfg = gpiod_request_config_new();
    gpiod_request_config_set_consumer(req_cfg, "datalogger");
    
    struct gpiod_line_settings *settings = gpiod_line_settings_new();
    gpiod_line_settings_set_direction(settings, GPIOD_LINE_DIRECTION_OUTPUT);
    gpiod_line_settings_set_output_value(settings, GPIOD_LINE_VALUE_INACTIVE);
    
    struct gpiod_line_config *line_cfg = gpiod_line_config_new();
    unsigned int offsets[3] = {LED_R_PIN, LED_G_PIN, LED_B_PIN};
    gpiod_line_config_add_line_settings(line_cfg, offsets, 3, settings);
    
    line_request = gpiod_chip_request_lines(gpio_chip, req_cfg, line_cfg);
    if (!line_request) {
        fprintf(stderr, "Error: Could not request GPIO lines for LEDs.\n");
        gpiod_line_settings_free(settings);
        gpiod_line_config_free(line_cfg);
        gpiod_request_config_free(req_cfg);
        gpiod_chip_close(gpio_chip);
        exit(1);
    }
    
    gpiod_line_settings_free(settings);
    gpiod_line_config_free(line_cfg);
    gpiod_request_config_free(req_cfg);
}

// ... (rest of the code remains the same until main function)

int main() {
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    printf("=== Greengrass IoT Datalogger ===\n");
    init_leds();
    
    int i2c_file = open(I2C_BUS, O_RDWR);
    if (i2c_file < 0) {
        fprintf(stderr, "Error: Could not open I2C bus %s. Ensure it is enabled and permissions are correct.\n", I2C_BUS);
        cleanup_leds();
        return 1; // Exit on critical error
    }
    
    // Initialize MPU6050
    if (i2c_file >= 0 && ioctl(i2c_file, I2C_SLAVE, MPU6050_ADDR) >= 0) {
        uint8_t power_cmd[2] = {MPU6050_REG_PWR_MGMT_1, 0x00};
        if (write(i2c_file, power_cmd, 2) != 2) {
            fprintf(stderr, "Error: Could not initialize MPU6050 power management.\n");
            close(i2c_file);
            cleanup_leds();
            return 1;
        }
        usleep(100000);
    } else {
        fprintf(stderr, "Error: Could not initialize MPU6050. Ensure it is connected and I2C address is correct.\n");
        close(i2c_file);
        cleanup_leds();
        return 1;
    }
    
    // Initialize INA219
    if (i2c_file >= 0 && ioctl(i2c_file, I2C_SLAVE, INA219_ADDR) >= 0) {
        write_i2c_register_16(i2c_file, 0x00, 0x399F);
        write_i2c_register_16(i2c_file, 0x05, 4096);
    } else {
        fprintf(stderr, "Error: Could not initialize INA219. Ensure it is connected and I2C address is correct.\n");
        close(i2c_file);
        cleanup_leds();
        return 1;
    }
    
    printf("Starting data collection...\n");
    
    while (running) {
        // ... (rest of the main loop remains the same)
        int connectivity = check_connectivity();
        int wifi_connected = (connectivity >> 1) & 1;
        int aws_connected = connectivity & 1;
        
        set_led_status(wifi_connected, aws_connected);
        
        time_t timestamp = time(NULL);
        float temp_c = read_temperature();
        
        int16_t ax = 0, ay = 0, az = 0, gx = 0, gy = 0, gz = 0;
        float current_a = 0.0f;
        
        // Read MPU6050
        if (i2c_file >= 0 && ioctl(i2c_file, I2C_SLAVE, MPU6050_ADDR) >= 0) {
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
        if (i2c_file >= 0 && ioctl(i2c_file, I2C_SLAVE, INA219_ADDR) >= 0) {
            int16_t current_raw = read_i2c_register_16(i2c_file, INA219_REG_CURRENT);
            current_a = (float)current_raw * 0.0001f;
            if (fabs(current_a) < 0.001f) current_a = 0.0f;
        }
        
        // Output JSON for Greengrass StreamManager
        printf("{\"timestamp\":%ld,\"device_id\":\"greengrass-pi\",\"temp_c\":%.2f,\"ax\":%d,\"ay\":%d,\"az\":%d,\"gx\":%d,\"gy\":%d,\"gz\":%d,\"current_a\":%.3f}\n",
               timestamp, temp_c, ax, ay, az, gx, gy, gz, current_a);
        fflush(stdout);
        
        sleep(LOG_INTERVAL_S);
    }
    
    if (i2c_file >= 0) close(i2c_file);
    cleanup_leds();
    printf("Datalogger stopped\n");
    return 0;
}
