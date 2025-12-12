// API Client - Centralized API communication
// Handles all API requests to the backend

class APIClient {
    constructor() {
        this.endpoint = 'API_GATEWAY_ENDPOINT_PLACEHOLDER';
        this.apiKey = 'API_KEY_PLACEHOLDER';
    }

    /**
     * Fetch device data with flexible parameters
     * @param {string} deviceId - Device ID or 'all' for all devices
     * @param {string} type - Data type: 'sensor', 'predictions', or 'both'
     * @param {number} hours - Number of hours to retrieve (default: 1)
     * @param {number} limit - Maximum number of records (default: 50)
     * @returns {Promise<Object>} API response data
     */
    async fetchDeviceData(deviceId, type = 'both', hours = 1, limit = 50) {
        try {
            const url = `${this.endpoint}?device_id=${deviceId}&type=${type}&hours=${hours}&limit=${limit}`;
            const response = await fetch(url, {
                headers: {
                    'x-api-key': this.apiKey
                }
            });

            if (!response.ok) {
                const errorText = await response.text();
                throw new Error(`HTTP ${response.status}: ${errorText}`);
            }

            return await response.json();
        } catch (error) {
            console.error(`API Error fetching data for ${deviceId}:`, error);
            throw error;
        }
    }

    /**
     * Discover all unique devices
     * @param {number} hours - Time range in hours (default: 1)
     * @param {number} limit - Maximum records per device (default: 50)
     * @returns {Promise<Map>} Map of deviceId -> deviceData
     */
    async discoverDevices(hours = 1, limit = 50) {
        try {
            const data = await this.fetchDeviceData('all', 'both', hours, limit);
            
            const deviceDataMap = new Map();
            
            // Check if we got the all-devices response format
            if (data.devices) {
                for (const [deviceId, deviceData] of Object.entries(data.devices)) {
                    deviceDataMap.set(deviceId, deviceData);
                }
            } else {
                // Fallback: try default device
                const fallbackData = await this.fetchDeviceData('esp32-device', 'both', hours, limit);
                if (fallbackData && (fallbackData.sensor_count > 0 || fallbackData.prediction_count > 0)) {
                    deviceDataMap.set('esp32-device', fallbackData);
                }
            }
            
            return deviceDataMap;
        } catch (error) {
            console.error('API Error discovering devices:', error);
            throw error;
        }
    }

    /**
     * Fetch historical data for a specific device
     * @param {string} deviceId - Device ID
     * @param {number} days - Number of days (converted to hours)
     * @param {number} limit - Maximum records
     * @returns {Promise<Object>} Historical data
     */
    async fetchHistoricalData(deviceId, days = 30, limit = 5000) {
        const hours = days * 24;
        return await this.fetchDeviceData(deviceId, 'both', hours, limit);
    }

    /**
     * Check if API is configured
     * @returns {boolean} True if API endpoint and key are set
     */
    isConfigured() {
        return this.endpoint !== 'API_GATEWAY_ENDPOINT_PLACEHOLDER' && 
               this.apiKey !== 'API_KEY_PLACEHOLDER';
    }

    /**
     * Get current API configuration (for debugging)
     * @returns {Object} Configuration object
     */
    getConfig() {
        return {
            endpoint: this.endpoint,
            hasApiKey: this.apiKey !== 'API_KEY_PLACEHOLDER',
            isConfigured: this.isConfigured()
        };
    }
}

// Create singleton instance
const apiClient = new APIClient();

// Export for use in other modules
window.apiClient = apiClient;
