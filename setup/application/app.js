const API_ENDPOINT = 'API_GATEWAY_ENDPOINT_PLACEHOLDER';
const API_KEY = 'API_KEY_PLACEHOLDER';
const REFRESH_INTERVAL = 5000; // 5 seconds
let charts = {};
let refreshTimer = null;
let lastApiResponse = null; // Store last API response for debugging

// Theme management
function initTheme() {
    const savedTheme = localStorage.getItem('theme') || 'light';
    document.documentElement.setAttribute('data-theme', savedTheme);
}

document.getElementById('theme-toggle').addEventListener('click', () => {
    const current = document.documentElement.getAttribute('data-theme');
    const newTheme = current === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', newTheme);
    localStorage.setItem('theme', newTheme);
    
    // Update all charts to match new theme
    Object.values(charts).forEach(chart => {
        updateChartTheme(chart);
        chart.update();
    });
});

function updateChartTheme(chart) {
    const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
    const textColor = isDark ? '#e6e6e6' : '#1a1a1a';
    const gridColor = isDark ? '#30363d' : '#d9d9d9';
    
    chart.options.scales.x.ticks.color = textColor;
    chart.options.scales.x.grid.color = gridColor;
    chart.options.scales.y.ticks.color = textColor;
    chart.options.scales.y.grid.color = gridColor;
    chart.options.plugins.legend.labels.color = textColor;
}

// Show error message to user
function showError(message) {
    const container = document.getElementById('devices-container');
    const errorDiv = document.createElement('div');
    errorDiv.className = 'error-message';
    errorDiv.textContent = message;
    container.innerHTML = '';
    container.appendChild(errorDiv);
}

// Fetch data for all devices
async function fetchDeviceData(deviceId) {
    try {
        const response = await fetch(`${API_ENDPOINT}?device_id=${deviceId}&type=both&hours=1&limit=50`, {
            headers: {
                'x-api-key': API_KEY
            }
        });
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        return await response.json();
    } catch (error) {
        console.error(`Error fetching data for ${deviceId}:`, error);
        return null;
    }
}

// Discover all unique devices
async function discoverDevices() {
    try {
        // Query for all devices
        const response = await fetch(`${API_ENDPOINT}?device_id=all&type=both&hours=1&limit=50`, {
            headers: {
                'x-api-key': API_KEY
            }
        });
        if (!response.ok) {
            const errorText = await response.text();
            console.error('API Error:', response.status, errorText);
            showError(`API Error (${response.status}): ${errorText}`);
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        const data = await response.json();
        console.log('API Response:', data);
        lastApiResponse = data; // Store for debugging
        
        // Check if we got the all-devices response format
        if (data.devices) {
            const deviceDataMap = new Map();
            for (const [deviceId, deviceData] of Object.entries(data.devices)) {
                deviceDataMap.set(deviceId, deviceData);
            }
            return deviceDataMap;
        }
        
        // Fallback: try default device
        const deviceDataMap = new Map();
        const fallbackData = await fetchDeviceData('esp32-device');
        if (fallbackData && (fallbackData.sensor_count > 0 || fallbackData.prediction_count > 0)) {
            deviceDataMap.set('esp32-device', fallbackData);
        }
        return deviceDataMap;
    } catch (error) {
        console.error('Error discovering devices:', error);
        showError('Failed to load devices: ' + error.message);
        return new Map();
    }
}

// Calculate derived metrics
function calculateMetrics(sensorData) {
    if (!sensorData || sensorData.length === 0) {
        return {
            avgTemp: 0,
            avgVibration: 0,
            avgCurrent: 0,
            vibrationMagnitude: 0
        };
    }
    
    const latest = sensorData[0];
    const avgTemp = sensorData.reduce((sum, d) => sum + (d.temp_c || 0), 0) / sensorData.length;
    const avgVibration = sensorData.reduce((sum, d) => sum + (d.vibration || 0), 0) / sensorData.length;
    const avgCurrent = sensorData.reduce((sum, d) => sum + (d.current_a || 0), 0) / sensorData.length;
    
    const vibrationMagnitude = Math.sqrt(
        Math.pow(latest.ax || 0, 2) + 
        Math.pow(latest.ay || 0, 2) + 
        Math.pow(latest.az || 0, 2)
    );
    
    return {
        avgTemp: avgTemp.toFixed(1),
        avgVibration: avgVibration.toFixed(2),
        avgCurrent: avgCurrent.toFixed(3),
        vibrationMagnitude: vibrationMagnitude.toFixed(2)
    };
}

// Create device row HTML
function createDeviceRow(deviceId, data) {
    const sensorData = data.sensor_data || [];
    const predictionData = data.prediction_data || [];
    
    const metrics = calculateMetrics(sensorData);
    const latestPrediction = predictionData.length > 0 ? predictionData[0] : null;
    
    // Determine status
    const isOnline = sensorData.length > 0 && 
                     (Date.now() / 1000 - sensorData[0].timestamp) < 60;
    
    // Prediction badge
    let predictionHtml = '';
    if (latestPrediction) {
        let badgeClass = 'healthy';
        const pred = latestPrediction.prediction;
        if (pred === 'Maintenance Required') {
            badgeClass = 'maintenance';
        } else if (pred === 'Monitor') {
            badgeClass = 'monitor';
        } else if (pred === 'Good') {
            badgeClass = 'healthy';
        }
        
        predictionHtml = `
            <div class="ml-prediction">
                <span class="prediction-badge ${badgeClass}">${latestPrediction.prediction}</span>
                <span class="prediction-details">
                    Confidence: ${(latestPrediction.confidence * 100).toFixed(1)}% | 
                    Score: ${latestPrediction.score.toFixed(1)} | 
                    Days to Maintenance: ${latestPrediction.days_until_maintenance || 'N/A'}
                </span>
            </div>
        `;
    }
    
    const deviceRow = document.createElement('div');
    deviceRow.className = 'device-row';
    deviceRow.innerHTML = `
        <div class="device-header">
            <div class="device-title">
                <h2 class="device-name">${deviceId}</h2>
                <div class="device-status">
                    <span class="status-indicator ${isOnline ? 'online' : 'offline'}"></span>
                    <span>${isOnline ? 'Online' : 'Offline'}</span>
                </div>
            </div>
            ${predictionHtml}
        </div>
        
        <div class="metrics-grid">
            <div class="metric-card">
                <div class="metric-label">Temperature</div>
                <div class="metric-value">
                    ${sensorData.length > 0 ? sensorData[0].temp_c.toFixed(1) : '0.0'}
                    <span class="metric-unit">°C</span>
                </div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Vibration</div>
                <div class="metric-value">
                    ${metrics.vibrationMagnitude}
                    <span class="metric-unit">m/s²</span>
                </div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Current Draw</div>
                <div class="metric-value">
                    ${sensorData.length > 0 ? sensorData[0].current_a.toFixed(3) : '0.000'}
                    <span class="metric-unit">A</span>
                </div>
            </div>
            <div class="metric-card">
                <div class="metric-label">Avg Temperature</div>
                <div class="metric-value">
                    ${metrics.avgTemp}
                    <span class="metric-unit">°C</span>
                </div>
            </div>
        </div>
        
        <div class="charts-container">
            <div class="chart-card">
                <div class="chart-title">Temperature History</div>
                <div class="chart-wrapper">
                    <canvas id="temp-chart-${deviceId}"></canvas>
                </div>
            </div>
            <div class="chart-card">
                <div class="chart-title">Vibration (Accelerometer)</div>
                <div class="chart-wrapper">
                    <canvas id="vibration-chart-${deviceId}"></canvas>
                </div>
            </div>
            <div class="chart-card">
                <div class="chart-title">Current Draw</div>
                <div class="chart-wrapper">
                    <canvas id="current-chart-${deviceId}"></canvas>
                </div>
            </div>
            <div class="chart-card">
                <div class="chart-title">ML Prediction Score</div>
                <div class="chart-wrapper">
                    <canvas id="ml-chart-${deviceId}"></canvas>
                </div>
            </div>
        </div>
    `;
    
    return deviceRow;
}

// Create charts
function createCharts(deviceId, data) {
    const sensorData = data.sensor_data || [];
    const predictionData = data.prediction_data || [];
    
    if (sensorData.length === 0) return;
    
    const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
    const textColor = isDark ? '#e6e6e6' : '#1a1a1a';
    const gridColor = isDark ? '#30363d' : '#d9d9d9';
    
    const chartOptions = {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
            legend: {
                labels: { color: textColor }
            }
        },
        scales: {
            x: {
                ticks: { color: textColor },
                grid: { color: gridColor }
            },
            y: {
                ticks: { color: textColor },
                grid: { color: gridColor }
            }
        }
    };
    
    // Reverse data for chronological order
    const reversedSensor = [...sensorData].reverse();
    const reversedPrediction = [...predictionData].reverse();
    
    const labels = reversedSensor.map(d => {
        const date = new Date(d.timestamp * 1000);
        return date.toLocaleTimeString();
    });
    
    // Temperature chart
    const tempCtx = document.getElementById(`temp-chart-${deviceId}`);
    if (tempCtx) {
        charts[`temp-${deviceId}`] = new Chart(tempCtx, {
            type: 'line',
            data: {
                labels: labels,
                datasets: [{
                    label: 'Temperature (°C)',
                    data: reversedSensor.map(d => d.temp_c),
                    borderColor: '#4da6ff',
                    backgroundColor: 'rgba(77, 166, 255, 0.1)',
                    tension: 0.4,
                    fill: true
                }]
            },
            options: chartOptions
        });
    }
    
    // Vibration chart
    const vibCtx = document.getElementById(`vibration-chart-${deviceId}`);
    if (vibCtx) {
        charts[`vib-${deviceId}`] = new Chart(vibCtx, {
            type: 'line',
            data: {
                labels: labels,
                datasets: [
                    {
                        label: 'Accel X',
                        data: reversedSensor.map(d => d.ax),
                        borderColor: '#ff6b6b',
                        tension: 0.4
                    },
                    {
                        label: 'Accel Y',
                        data: reversedSensor.map(d => d.ay),
                        borderColor: '#4ecdc4',
                        tension: 0.4
                    },
                    {
                        label: 'Accel Z',
                        data: reversedSensor.map(d => d.az),
                        borderColor: '#ffe66d',
                        tension: 0.4
                    }
                ]
            },
            options: chartOptions
        });
    }
    
    // Current chart
    const currentCtx = document.getElementById(`current-chart-${deviceId}`);
    if (currentCtx) {
        charts[`current-${deviceId}`] = new Chart(currentCtx, {
            type: 'line',
            data: {
                labels: labels,
                datasets: [{
                    label: 'Current (A)',
                    data: reversedSensor.map(d => d.current_a),
                    borderColor: '#ff9800',
                    backgroundColor: 'rgba(255, 152, 0, 0.1)',
                    tension: 0.4,
                    fill: true
                }]
            },
            options: chartOptions
        });
    }
    
    // ML Prediction chart
    if (predictionData.length > 0) {
        const mlLabels = reversedPrediction.map(d => {
            const date = new Date(d.timestamp * 1000);
            return date.toLocaleTimeString();
        });
        
        const mlCtx = document.getElementById(`ml-chart-${deviceId}`);
        if (mlCtx) {
            charts[`ml-${deviceId}`] = new Chart(mlCtx, {
                type: 'line',
                data: {
                    labels: mlLabels,
                    datasets: [{
                        label: 'Maintenance Score',
                        data: reversedPrediction.map(d => d.score),
                        borderColor: '#f44336',
                        backgroundColor: 'rgba(244, 67, 54, 0.1)',
                        tension: 0.4,
                        fill: true
                    }]
                },
                options: {
                    ...chartOptions,
                    scales: {
                        ...chartOptions.scales,
                        y: {
                            ...chartOptions.scales.y,
                            min: 0,
                            max: 100
                        }
                    }
                }
            });
        }
    }
}

// Update charts with new data
function updateCharts(deviceId, data) {
    const sensorData = data.sensor_data || [];
    const predictionData = data.prediction_data || [];
    
    if (sensorData.length === 0) return;
    
    const reversedSensor = [...sensorData].reverse();
    const reversedPrediction = [...predictionData].reverse();
    
    const labels = reversedSensor.map(d => {
        const date = new Date(d.timestamp * 1000);
        return date.toLocaleTimeString();
    });
    
    // Update temperature chart
    if (charts[`temp-${deviceId}`]) {
        charts[`temp-${deviceId}`].data.labels = labels;
        charts[`temp-${deviceId}`].data.datasets[0].data = reversedSensor.map(d => d.temp_c);
        charts[`temp-${deviceId}`].update('none');
    }
    
    // Update vibration chart
    if (charts[`vib-${deviceId}`]) {
        charts[`vib-${deviceId}`].data.labels = labels;
        charts[`vib-${deviceId}`].data.datasets[0].data = reversedSensor.map(d => d.ax);
        charts[`vib-${deviceId}`].data.datasets[1].data = reversedSensor.map(d => d.ay);
        charts[`vib-${deviceId}`].data.datasets[2].data = reversedSensor.map(d => d.az);
        charts[`vib-${deviceId}`].update('none');
    }
    
    // Update current chart
    if (charts[`current-${deviceId}`]) {
        charts[`current-${deviceId}`].data.labels = labels;
        charts[`current-${deviceId}`].data.datasets[0].data = reversedSensor.map(d => d.current_a);
        charts[`current-${deviceId}`].update('none');
    }
    
    // Update ML chart
    if (predictionData.length > 0 && charts[`ml-${deviceId}`]) {
        const mlLabels = reversedPrediction.map(d => {
            const date = new Date(d.timestamp * 1000);
            return date.toLocaleTimeString();
        });
        charts[`ml-${deviceId}`].data.labels = mlLabels;
        charts[`ml-${deviceId}`].data.datasets[0].data = reversedPrediction.map(d => d.score);
        charts[`ml-${deviceId}`].update('none');
    }
}

// Render all devices
async function renderDashboard() {
    const container = document.getElementById('devices-container');
    const deviceDataMap = await discoverDevices();
    
    console.log('Device map size:', deviceDataMap.size);
    console.log('Devices:', Array.from(deviceDataMap.keys()));
    
    if (deviceDataMap.size === 0) {
        container.innerHTML = '<div class="no-data">No devices found or no data available</div>';
        return;
    }
    
    container.innerHTML = '';
    
    for (const [deviceId, data] of deviceDataMap) {
        const deviceRow = createDeviceRow(deviceId, data);
        container.appendChild(deviceRow);
        
        // Create charts after DOM is ready
        setTimeout(() => createCharts(deviceId, data), 100);
    }
    
    updateLastUpdateTime();
}

// Update existing dashboard
async function updateDashboard() {
    try {
        const response = await fetch(`${API_ENDPOINT}?device_id=all&type=both&hours=1&limit=50`, {
            headers: {
                'x-api-key': API_KEY
            }
        });
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        const responseData = await response.json();
        
        let deviceDataMap = new Map();
        
        // Handle all-devices response
        if (responseData.devices) {
            for (const [deviceId, deviceData] of Object.entries(responseData.devices)) {
                deviceDataMap.set(deviceId, deviceData);
            }
        } else {
            // Fallback for single device
            const fallbackData = await fetchDeviceData('esp32-device');
            if (fallbackData && (fallbackData.sensor_count > 0 || fallbackData.prediction_count > 0)) {
                deviceDataMap.set('esp32-device', fallbackData);
            }
        }
        
        for (const [deviceId, data] of deviceDataMap) {
            // Update metrics
            const deviceRow = Array.from(document.querySelectorAll('.device-row')).find(
                row => row.querySelector('.device-name').textContent === deviceId
            );
            
            if (deviceRow) {
                // Update status
                const sensorData = data.sensor_data || [];
                const isOnline = sensorData.length > 0 && 
                               (Date.now() / 1000 - sensorData[0].timestamp) < 60;
                
                const statusIndicator = deviceRow.querySelector('.status-indicator');
                const statusText = deviceRow.querySelector('.device-status span:last-child');
                
                if (statusIndicator && statusText) {
                    statusIndicator.className = `status-indicator ${isOnline ? 'online' : 'offline'}`;
                    statusText.textContent = isOnline ? 'Online' : 'Offline';
                }
                
                // Update metric values
                const metrics = calculateMetrics(sensorData);
                const metricCards = deviceRow.querySelectorAll('.metric-value');
                
                if (metricCards.length >= 4 && sensorData.length > 0) {
                    metricCards[0].innerHTML = `${sensorData[0].temp_c.toFixed(1)} <span class="metric-unit">°C</span>`;
                    metricCards[1].innerHTML = `${metrics.vibrationMagnitude} <span class="metric-unit">m/s²</span>`;
                    metricCards[2].innerHTML = `${sensorData[0].current_a.toFixed(3)} <span class="metric-unit">A</span>`;
                    metricCards[3].innerHTML = `${metrics.avgTemp} <span class="metric-unit">°C</span>`;
                }
                
                // Update ML prediction badge if present
                const predictionData = data.prediction_data || [];
                if (predictionData.length > 0) {
                    const latestPrediction = predictionData[0];
                    const mlPrediction = deviceRow.querySelector('.ml-prediction');
                    
                    if (mlPrediction) {
                        let badgeClass = 'healthy';
                        const pred = latestPrediction.prediction;
                        if (pred === 'Maintenance Required') {
                            badgeClass = 'maintenance';
                        } else if (pred === 'Monitor' || pred === 'Monitor Closely') {
                            badgeClass = 'monitor';
                        } else if (pred === 'Good') {
                            badgeClass = 'healthy';
                        }
                        
                        mlPrediction.innerHTML = `
                            <span class="prediction-badge ${badgeClass}">${latestPrediction.prediction}</span>
                            <span class="prediction-details">
                                Confidence: ${(latestPrediction.confidence * 100).toFixed(1)}% | 
                                Score: ${latestPrediction.score.toFixed(1)} | 
                                Days to Maintenance: ${latestPrediction.days_until_maintenance || 'N/A'}
                            </span>
                        `;
                    }
                }
                
                // Update charts
                updateCharts(deviceId, data);
            }
        }
        
        updateLastUpdateTime();
    } catch (error) {
        console.error('Error updating dashboard:', error);
    }
}

function updateLastUpdateTime() {
    const now = new Date();
    document.getElementById('last-update').textContent = 
        `Last update: ${now.toLocaleTimeString()}`;
}

// Auto-refresh
function startAutoRefresh() {
    if (refreshTimer) {
        clearInterval(refreshTimer);
    }
    refreshTimer = setInterval(updateDashboard, REFRESH_INTERVAL);
}

function stopAutoRefresh() {
    if (refreshTimer) {
        clearInterval(refreshTimer);
        refreshTimer = null;
    }
}

// Manual refresh
document.getElementById('refresh-btn').addEventListener('click', async () => {
    await updateDashboard();
});

// Debug export
document.getElementById('debug-btn').addEventListener('click', () => {
    const debugData = {
        timestamp: new Date().toISOString(),
        apiEndpoint: API_ENDPOINT,
        hasApiKey: API_KEY !== 'API_KEY_PLACEHOLDER',
        lastApiResponse: lastApiResponse,
        deviceMapSize: lastApiResponse?.devices ? Object.keys(lastApiResponse.devices).length : 0,
        devices: lastApiResponse?.devices ? Object.keys(lastApiResponse.devices) : [],
        theme: document.documentElement.getAttribute('data-theme'),
        chartsLoaded: Object.keys(charts).length,
        refreshInterval: REFRESH_INTERVAL
    };
    
    console.log('=== SIAM DEBUG EXPORT ===');
    console.log('Export Time:', debugData.timestamp);
    console.log('API Endpoint:', debugData.apiEndpoint);
    console.log('API Key Present:', debugData.hasApiKey);
    console.log('---');
    console.log('Full Debug Data:', JSON.stringify(debugData, null, 2));
    console.log('---');
    console.log('Last API Response:', lastApiResponse);
    console.log('========================');
    
    // Also create a downloadable JSON file
    const blob = new Blob([JSON.stringify(debugData, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `siam-debug-${Date.now()}.json`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    
    alert('Debug data exported to console and downloaded as JSON file');
});

// Visibility change handler
document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
        stopAutoRefresh();
    } else {
        updateDashboard();
        startAutoRefresh();
    }
});

// Initialize
initTheme();
renderDashboard().then(() => {
    startAutoRefresh();
});
