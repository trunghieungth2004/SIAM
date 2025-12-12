// Dashboard Main Script
const REFRESH_INTERVAL = 3000; // 3 seconds for more real-time updates
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
        return await window.apiClient.fetchDeviceData(deviceId, 'both', 1, 50);
    } catch (error) {
        console.error(`Error fetching data for ${deviceId}:`, error);
        return null;
    }
}

// Discover all unique devices
async function discoverDevices() {
    try {
        const deviceDataMap = await window.apiClient.discoverDevices(1, 50);
        console.log('=== REAL-TIME DATA FETCH ===');
        console.log('Timestamp:', new Date().toISOString());
        console.log('Device Count:', deviceDataMap.size);
        console.log('API Response:', deviceDataMap);
        
        // Log each device's data in detail
        for (const [deviceId, data] of deviceDataMap) {
            console.log(`\n[Device: ${deviceId}]`);
            console.log('  Sensor Data Points:', data.sensor_data?.length || 0);
            console.log('  Prediction Data Points:', data.prediction_data?.length || 0);
            
            if (data.sensor_data?.length > 0) {
                const latest = data.sensor_data[0];
                console.log('  Latest Sensor Reading:');
                console.log('    Timestamp:', new Date(latest.timestamp * 1000).toISOString());
                console.log('    Temp:', latest.temp_c, '°C');
                console.log('    Current:', latest.current_a, 'A');
                console.log('    Accel:', { x: latest.ax, y: latest.ay, z: latest.az });
            }
            
            if (data.prediction_data?.length > 0) {
                const latest = data.prediction_data[0];
                console.log('  Latest ML Prediction:');
                console.log('    Timestamp:', new Date(latest.timestamp * 1000).toISOString());
                console.log('    Prediction:', latest.prediction);
                console.log('    Score:', latest.score);
                console.log('    Confidence:', latest.confidence);
            }
        }
        console.log('============================\n');
        
        lastApiResponse = { devices: Object.fromEntries(deviceDataMap) }; // Store for debugging
        return deviceDataMap;
    } catch (error) {
        console.error('Error discovering devices:', error);
        showError('Failed to load devices: ' + error.message);
        return new Map();
    }
}

// Calculate trend direction using linear regression
function calculateTrend(values) {
    if (!values || values.length < 3) return { slope: 0, trend: 'stable' };
    
    const n = values.length;
    const indices = Array.from({length: n}, (_, i) => i);
    const sumX = indices.reduce((a, b) => a + b, 0);
    const sumY = values.reduce((a, b) => a + b, 0);
    const sumXY = indices.reduce((sum, x, i) => sum + x * values[i], 0);
    const sumX2 = indices.reduce((sum, x) => sum + x * x, 0);
    
    const slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
    const avgValue = sumY / n;
    const relativeSlope = Math.abs(slope) / (avgValue || 1);
    
    // Classify trend based on relative slope
    let trend = 'stable';
    if (relativeSlope > 0.05) {
        trend = slope > 0 ? 'increasing' : 'decreasing';
    }
    
    return { slope, trend, relativeSlope };
}

// Analyze anomaly pattern to distinguish false alarms from real issues
function analyzeAnomalyPattern(sensorData, predictionData) {
    if (!predictionData || predictionData.length < 3) {
        return {
            confidence: 'low',
            diagnosis: 'Insufficient data for trend analysis',
            isRealAnomaly: false
        };
    }
    
    // Get reconstruction errors over time (most recent first, so reverse for trend)
    const reconErrors = [...predictionData].reverse().map(p => p.reconstruction_error || 0);
    const scores = [...predictionData].reverse().map(p => p.score || 0);
    
    // Calculate trends
    const errorTrend = calculateTrend(reconErrors);
    const scoreTrend = calculateTrend(scores);
    
    // Get sensor value trends
    let tempTrend = { trend: 'stable' };
    let vibTrend = { trend: 'stable' };
    let currentTrend = { trend: 'stable' };
    
    if (sensorData && sensorData.length >= 3) {
        const temps = [...sensorData].reverse().map(s => s.temp_c || 0);
        const vibs = [...sensorData].reverse().map(s => Math.sqrt((s.ax||0)**2 + (s.ay||0)**2 + (s.az||0)**2));
        const currents = [...sensorData].reverse().map(s => s.current_a || 0);
        
        tempTrend = calculateTrend(temps);
        vibTrend = calculateTrend(vibs);
        currentTrend = calculateTrend(currents);
    }
    
    // Count how many metrics are trending up
    const increasingCount = [tempTrend, vibTrend, currentTrend, errorTrend]
        .filter(t => t.trend === 'increasing').length;
    
    // Diagnosis logic
    let diagnosis = '';
    let isRealAnomaly = false;
    let confidence = 'medium';
    
    if (errorTrend.trend === 'increasing' && increasingCount >= 2) {
        diagnosis = 'REAL FAILURE: Multiple sensors showing degradation trend';
        isRealAnomaly = true;
        confidence = 'high';
    } else if (errorTrend.trend === 'increasing' && increasingCount === 1) {
        diagnosis = 'Possible Issue: Reconstruction error trending up';
        isRealAnomaly = true;
        confidence = 'medium';
    } else if (errorTrend.trend === 'stable' && reconErrors[reconErrors.length - 1] > reconErrors[0] * 1.5) {
        diagnosis = 'Possible False Alarm: Random spike without sustained trend';
        isRealAnomaly = false;
        confidence = 'medium';
    } else {
        diagnosis = 'Likely Normal: No concerning trends detected';
        isRealAnomaly = false;
        confidence = 'high';
    }
    
    return {
        confidence,
        diagnosis,
        isRealAnomaly,
        trends: {
            temperature: tempTrend.trend,
            vibration: vibTrend.trend,
            current: currentTrend.trend,
            reconError: errorTrend.trend,
            score: scoreTrend.trend
        }
    };
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
    
    // Prediction badge - Apply same 3/5 sustained pattern logic as SNS alerts
    let predictionHtml = '';
    if (latestPrediction) {
        // Check last 5 predictions for sustained anomaly pattern (EXACT match to ingestion.js lines 108-126)
        const recentPredictions = predictionData.slice(0, 5);
        const highScoreCount = recentPredictions.filter(p => p.score >= 50).length;
        
        let displayPrediction = latestPrediction.prediction;
        let badgeClass = 'healthy';
        
        // Override prediction based on sustained pattern (MATCHES ingestion.js)
        if (highScoreCount > 3) {
            // More than 3 out of 5: Sustained anomaly - matches SNS "SUSTAINED_ANOMALY" (line 118)
            displayPrediction = 'Sustained Anomaly';
            badgeClass = 'maintenance';
        } else if (highScoreCount === 3) {
            // Exactly 3 out of 5: Warning - matches SNS "WARNING" (line 117)
            displayPrediction = 'Warning';
            badgeClass = 'monitor';
        } else {
            // Less than 3 out of 5: Suppressed - matches ingestion.js line 174 (no alert sent)
            displayPrediction = 'Normal';
            badgeClass = 'healthy';
        }
        
        const reconError = latestPrediction.reconstruction_error ? 
            `Recon Error: ${latestPrediction.reconstruction_error.toFixed(6)}` : '';
        
        // Analyze anomaly pattern
        const analysis = analyzeAnomalyPattern(sensorData, predictionData);
        const trendSymbols = {
            increasing: '↑',
            decreasing: '↓',
            stable: '→'
        };
        
        // Determine diagnosis color
        let diagnosisColor = '#4CAF50'; // green for normal
        if (analysis.isRealAnomaly && analysis.confidence === 'high') {
            diagnosisColor = '#f44336'; // red for real failure
        } else if (analysis.isRealAnomaly) {
            diagnosisColor = '#ff9800'; // orange for possible issue
        }
        
        predictionHtml = `
            <div class="ml-prediction">
                <span class="prediction-badge ${badgeClass}">${displayPrediction}</span>
                <span class="prediction-details">
                    ML Score: ${latestPrediction.score.toFixed(1)} | 
                    Sustained Pattern: ${highScoreCount}/5 high scores | 
                    ${reconError ? reconError + ' | ' : ''}
                    Days to Maintenance: ${latestPrediction.days_until_maintenance || 'N/A'}
                </span>
                <div class="trend-analysis" style="margin-top: 8px; padding: 8px; background: rgba(0,0,0,0.1); border-radius: 4px;">
                    <div style="font-weight: bold; margin-bottom: 4px; color: ${diagnosisColor};">${analysis.diagnosis}</div>
                    <div style="font-size: 0.9em; display: flex; gap: 12px; flex-wrap: wrap;">
                        <span>Temp: ${trendSymbols[analysis.trends.temperature]} ${analysis.trends.temperature}</span>
                        <span>Vib: ${trendSymbols[analysis.trends.vibration]} ${analysis.trends.vibration}</span>
                        <span>Current: ${trendSymbols[analysis.trends.current]} ${analysis.trends.current}</span>
                        <span>Error: ${trendSymbols[analysis.trends.reconError]} ${analysis.trends.reconError}</span>
                    </div>
                </div>
            </div>
        `;
    }
    
    const deviceRow = document.createElement('div');
    deviceRow.className = 'device-row';
    deviceRow.style.cursor = 'pointer';
    deviceRow.setAttribute('data-device-id', deviceId);
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
        </div>
        
        <div class="charts-header" style="display: flex; justify-content: space-between; align-items: center; margin: 20px 0 10px 0; padding: 10px; background: rgba(0,0,0,0.05); border-radius: 8px;">
            <h3 style="margin: 0; font-size: 1.1em;">Historical Data</h3>
            <button class="chart-toggle-all" data-device-id="${deviceId}" style="padding: 8px 16px; background: #4da6ff; color: white; border: none; border-radius: 6px; cursor: pointer; font-size: 0.9em; font-weight: 500; transition: background 0.3s ease; display: flex; align-items: center; gap: 6px;" onmouseover="this.style.background='#3d96ef'" onmouseout="this.style.background='#4da6ff'">
                <span class="toggle-icon">▼</span> Toggle All Charts
            </button>
        </div>
        <div class="charts-container" data-device-id="${deviceId}">
            <div class="chart-card">
                <div class="chart-header">
                    <div class="chart-title">Temperature History</div>
                </div>
                <div class="chart-wrapper" data-chart-id="temp-chart-${deviceId}">
                    <canvas id="temp-chart-${deviceId}"></canvas>
                </div>
            </div>
            <div class="chart-card">
                <div class="chart-header">
                    <div class="chart-title">Vibration (Accelerometer)</div>
                </div>
                <div class="chart-wrapper" data-chart-id="vibration-chart-${deviceId}">
                    <canvas id="vibration-chart-${deviceId}"></canvas>
                </div>
            </div>
            <div class="chart-card">
                <div class="chart-header">
                    <div class="chart-title">Current Draw</div>
                </div>
                <div class="chart-wrapper" data-chart-id="current-chart-${deviceId}">
                    <canvas id="current-chart-${deviceId}"></canvas>
                </div>
            </div>
            <div class="chart-card">
                <div class="chart-header">
                    <div class="chart-title">Anomaly Detection Score</div>
                </div>
                <div class="chart-wrapper" data-chart-id="ml-chart-${deviceId}">
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
                        label: 'Anomaly Score',
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
        
        // Add click handler for device row to open details modal
        setTimeout(() => {
            const row = container.querySelector(`[data-device-id="${deviceId}"]`);
            if (row) {
                row.addEventListener('click', (e) => {
                    // Don't trigger if clicking on charts or toggle buttons
                    if (!e.target.closest('.chart-wrapper') && 
                        !e.target.closest('.chart-toggle-all') &&
                        !e.target.closest('.chart-card')) {
                        window.openDeviceDetails(deviceId, data);
                    }
                });
            }
        }, 150);
        
        // Add toggle-all chart handlers
        setTimeout(() => {
            const toggleButtons = container.querySelectorAll('.chart-toggle-all');
            toggleButtons.forEach(button => {
                button.addEventListener('click', (e) => {
                    e.stopPropagation(); // Prevent device row click
                    const deviceId = button.getAttribute('data-device-id');
                    const chartsContainer = container.querySelector(`.charts-container[data-device-id="${deviceId}"]`);
                    const icon = button.querySelector('.toggle-icon');
                    
                    if (chartsContainer) {
                        const wrappers = chartsContainer.querySelectorAll('.chart-wrapper');
                        const isCollapsed = chartsContainer.classList.contains('collapsed');
                        
                        chartsContainer.classList.toggle('collapsed');
                        wrappers.forEach(wrapper => {
                            wrapper.classList.toggle('collapsed');
                        });
                        
                        icon.textContent = chartsContainer.classList.contains('collapsed') ? '▶' : '▼';
                    }
                });
            });
        }, 150);
    }
    
    updateLastUpdateTime();
}

// Update existing dashboard
async function updateDashboard() {
    try {
        const deviceDataMap = await discoverDevices();
        
        for (const [deviceId, data] of deviceDataMap) {
            const deviceRow = document.querySelector(`[data-device-id="${deviceId}"]`);
            if (!deviceRow) continue;
            
            // Update sensor metrics if present
            const sensorData = data.sensor_data || [];
            if (sensorData.length > 0) {
                const metrics = calculateMetrics(sensorData);
                const tempElement = deviceRow.querySelector('.metric-value.temp');
                if (tempElement) {
                    tempElement.innerHTML = `${metrics.avgTemp} <span class="metric-unit">°C</span>`;
                }
            }
            
            // Update ML prediction badge if present
            const predictionData = data.prediction_data || [];
            if (predictionData.length > 0) {
                const latestPrediction = predictionData[0];
                const mlPrediction = deviceRow.querySelector('.ml-prediction');
                
                if (mlPrediction) {
                    // Apply same 3/5 sustained pattern logic as SNS alerts (MATCHES ingestion.js)
                    const recentPredictions = predictionData.slice(0, 5);
                    const highScoreCount = recentPredictions.filter(p => p.score >= 50).length;
                    
                    let displayPrediction = latestPrediction.prediction;
                    let badgeClass = 'healthy';
                    
                    // Override prediction based on sustained pattern
                    if (highScoreCount > 3) {
                        // More than 3 out of 5: Sustained anomaly
                        displayPrediction = 'Sustained Anomaly';
                        badgeClass = 'maintenance';
                    } else if (highScoreCount === 3) {
                        // Exactly 3 out of 5: Warning
                        displayPrediction = 'Warning';
                        badgeClass = 'monitor';
                    } else {
                        // Less than 3 out of 5: Suppressed - no alert
                        displayPrediction = 'Normal';
                        badgeClass = 'healthy';
                    }
                    
                    mlPrediction.innerHTML = `
                        <span class="prediction-badge ${badgeClass}">${displayPrediction}</span>
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
    const apiConfig = window.apiClient.getConfig();
    const debugData = {
        timestamp: new Date().toISOString(),
        apiEndpoint: apiConfig.endpoint,
        hasApiKey: apiConfig.hasApiKey,
        isConfigured: apiConfig.isConfigured,
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
    console.log('API Configured:', debugData.isConfigured);
    console.log('---');
    console.log('Full Debug Data:', JSON.stringify(debugData, null, 2));
    console.log('---');
    console.log('Last API Response:', lastApiResponse);
    console.log('========================');
    
    // Download debug data
    const blob = new Blob([JSON.stringify(debugData, null, 2)], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `siam-debug-${Date.now()}.json`;
    a.click();
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
