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
    if (!gpio_chip) return;
    
    struct gpiod_request_config *req_cfg = gpiod_request_config_new();
    gpiod_request_config_set_consumer(req_cfg, "datalogger");
    
    struct gpiod_line_settings *settings = gpiod_line_settings_new();
    gpiod_line_settings_set_direction(settings, GPIOD_LINE_DIRECTION_OUTPUT);
    gpiod_line_settings_set_output_value(settings, GPIOD_LINE_VALUE_INACTIVE);
    
    struct gpiod_line_config *line_cfg = gpiod_line_config_new();
    unsigned int offsets[3] = {LED_R_PIN, LED_G_PIN, LED_B_PIN};
    gpiod_line_config_add_line_settings(line_cfg, offsets, 3, settings);
    
    line_request = gpiod_chip_request_lines(gpio_chip, req_cfg, line_cfg);
    
    gpiod_line_settings_free(settings);
    gpiod_line_config_free(line_cfg);
    gpiod_request_config_free(req_cfg);
}

void set_led_status(int wifi_connected, int aws_connected) {
    if (!line_request) return;
    
    enum gpiod_line_value values[3];
    
    if (aws_connected) {
        // Green: AWS connected
        values[0] = GPIOD_LINE_VALUE_INACTIVE; // R off
        values[1] = GPIOD_LINE_VALUE_ACTIVE;   // G on
        values[2] = GPIOD_LINE_VALUE_INACTIVE; // B off
    } else if (wifi_connected) {
        // Blue: WiFi connected, AWS disconnected
        values[0] = GPIOD_LINE_VALUE_INACTIVE; // R off
        values[1] = GPIOD_LINE_VALUE_INACTIVE; // G off
        values[2] = GPIOD_LINE_VALUE_ACTIVE;   // B on
    } else {
        // Red: No connectivity
        values[0] = GPIOD_LINE_VALUE_ACTIVE;   // R on
        values[1] = GPIOD_LINE_VALUE_INACTIVE; // G off
        values[2] = GPIOD_LINE_VALUE_INACTIVE; // B off
    }
    
    gpiod_line_request_set_values(line_request, values);
}

void cleanup_leds() {
    if (line_request) gpiod_line_request_release(line_request);
    if (gpio_chip) gpiod_chip_close(gpio_chip);
}

float read_temperature() {
    DIR *dir;
    struct dirent *dirent;
    char dev_path[128];
    char buf[256];
    char *ptr;
    float temp_c = -999.0f;

    if ((dir = opendir(ONE_WIRE_BASE_DIR)) == NULL) return temp_c;

    while ((dirent = readdir(dir)) != NULL) {
        if (dirent->d_type == DT_LNK && strstr(dirent->d_name, "28-") != NULL) {
            sprintf(dev_path, "%s%s/w1_slave", ONE_WIRE_BASE_DIR, dirent->d_name);
            FILE *fp = fopen(dev_path, "r");
            if (fp && fread(buf, 1, sizeof(buf) - 1, fp) > 0) {
                ptr = strstr(buf, "t=");
                if (ptr != NULL) {
                    char *endptr;
                    long temp_raw = strtol(ptr + 2, &endptr, 10);
                    if (endptr != ptr + 2) temp_c = (float)temp_raw / 1000.0f;
                }
            }
            if(fp) fclose(fp);
            break;
        }
    }
    closedir(dir);
    return temp_c;
}

int16_t read_i2c_register_16(int file, uint8_t reg) {
    char write_buf[1] = {reg};
    if (write(file, write_buf, 1) != 1) return 0;
    char read_buf[2];
    if (read(file, read_buf, 2) != 2) return 0;
    return (read_buf[0] << 8) | (uint8_t)read_buf[1];
}

void write_i2c_register_16(int file, uint8_t reg, uint16_t value) {
    uint8_t write_buf[3] = {reg, (value >> 8) & 0xFF, value & 0xFF};
    write(file, write_buf, 3);
}

int check_connectivity() {
    // Check WiFi
    FILE *fp = popen("iwgetid -r 2>/dev/null", "r");
    int wifi_connected = 0;
    if (fp) {
        char ssid[64];
        if (fgets(ssid, sizeof(ssid), fp)) wifi_connected = 1;
        pclose(fp);
    }
    
    // Check AWS connectivity (simplified)
    int aws_connected = 0;
    if (access("/greengrass/v2/logs/greengrass.log", R_OK) == 0) {
        aws_connected = 1; // Assume connected if Greengrass is running
    }
    
    return (wifi_connected << 1) | aws_connected;
}

int main() {
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    printf("=== Greengrass IoT Datalogger ===\n");
    init_leds();
    
    int i2c_file = open(I2C_BUS, O_RDWR);
    if (i2c_file < 0) {
        printf("Warning: Could not open I2C bus\n");
    }
    
    // Initialize MPU6050
    if (i2c_file >= 0 && ioctl(i2c_file, I2C_SLAVE, MPU6050_ADDR) >= 0) {
        uint8_t power_cmd[2] = {MPU6050_REG_PWR_MGMT_1, 0x00};
        write(i2c_file, power_cmd, 2);
        usleep(100000);
    }
    
    // Initialize INA219
    if (i2c_file >= 0 && ioctl(i2c_file, I2C_SLAVE, INA219_ADDR) >= 0) {
        write_i2c_register_16(i2c_file, 0x00, 0x399F);
        write_i2c_register_16(i2c_file, 0x05, 4096);
    }
    
    printf("Starting data collection...\n");
    
    while (running) {
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