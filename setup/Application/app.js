// Configuration - API Gateway endpoint will be injected here
const API_ENDPOINT = 'API_GATEWAY_ENDPOINT_PLACEHOLDER';

// Chart instances
let tempChart, vibrationChart, currentChart, predictionChart;
let autoRefreshInterval;

// Initialize charts
function initCharts() {
    const chartConfig = {
        type: 'line',
        options: {
            responsive: true,
            maintainAspectRatio: false,
            scales: {
                x: {
                    type: 'linear',
                    position: 'bottom'
                },
                y: {
                    beginAtZero: true
                }
            },
            plugins: {
                legend: {
                    display: false
                }
            }
        }
    };

    tempChart = new Chart(document.getElementById('tempChart'), {
        ...chartConfig,
        data: {
            datasets: [{
                label: 'Temperature (°C)',
                borderColor: '#ff6384',
                backgroundColor: 'rgba(255, 99, 132, 0.1)',
                data: []
            }]
        }
    });

    vibrationChart = new Chart(document.getElementById('vibrationChart'), {
        ...chartConfig,
        data: {
            datasets: [{
                label: 'Vibration',
                borderColor: '#36a2eb',
                backgroundColor: 'rgba(54, 162, 235, 0.1)',
                data: []
            }]
        }
    });

    currentChart = new Chart(document.getElementById('currentChart'), {
        ...chartConfig,
        data: {
            datasets: [{
                label: 'Current (A)',
                borderColor: '#4bc0c0',
                backgroundColor: 'rgba(75, 192, 192, 0.1)',
                data: []
            }]
        }
    });

    predictionChart = new Chart(document.getElementById('predictionChart'), {
        type: 'doughnut',
        data: {
            labels: ['Normal', 'Warning', 'Maintenance Required'],
            datasets: [{
                data: [0, 0, 0],
                backgroundColor: ['#28a745', '#ffc107', '#dc3545']
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false
        }
    });
}

// Update status message
function updateStatus(message, type = 'info') {
    const status = document.getElementById('status');
    status.textContent = message;
    status.className = 'status ' + type;
}

// Load data from API
async function loadData() {
    const deviceId = document.getElementById('deviceId').value || 'esp32-device';
    const hours = document.getElementById('hours').value || 24;
    const dataType = document.getElementById('dataType').value || 'sensor';

    updateStatus('Loading data...', 'loading');

    try {
        const url = `${API_ENDPOINT}?device_id=${deviceId}&hours=${hours}&type=${dataType}&limit=100`;
        const response = await fetch(url);
        
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }

        const data = await response.json();
        updateCharts(data, dataType);
        updateTable(data, dataType);
        updateStatus(`Data loaded successfully (${new Date().toLocaleTimeString()})`, 'info');
    } catch (error) {
        console.error('Error loading data:', error);
        updateStatus(`Error: ${error.message}`, 'error');
    }
}

// Update charts with new data
function updateCharts(data, dataType) {
    if (dataType === 'sensor' || dataType === 'both') {
        const sensorData = dataType === 'both' ? data.sensor_data : data.data;
        
        if (sensorData && sensorData.length > 0) {
            // Temperature chart
            tempChart.data.datasets[0].data = sensorData.map((item, index) => ({
                x: index,
                y: item.temp_c
            }));
            tempChart.update();

            // Vibration chart
            vibrationChart.data.datasets[0].data = sensorData.map((item, index) => ({
                x: index,
                y: item.vibration
            }));
            vibrationChart.update();

            // Current chart
            currentChart.data.datasets[0].data = sensorData.map((item, index) => ({
                x: index,
                y: item.current_a
            }));
            currentChart.update();
        }
    }

    if (dataType === 'predictions' || dataType === 'both') {
        const predictionData = dataType === 'both' ? data.prediction_data : data.data;
        
        if (predictionData && predictionData.length > 0) {
            // Count predictions
            const counts = { Normal: 0, Warning: 0, 'Maintenance Required': 0 };
            predictionData.forEach(item => {
                if (counts.hasOwnProperty(item.prediction)) {
                    counts[item.prediction]++;
                }
            });

            predictionChart.data.datasets[0].data = [
                counts.Normal,
                counts.Warning,
                counts['Maintenance Required']
            ];
            predictionChart.update();
        }
    }
}

// Update data table
function updateTable(data, dataType) {
    const tableContainer = document.getElementById('dataTable');
    
    let tableHTML = '<div class="table-container"><table>';
    
    if (dataType === 'sensor' || dataType === 'both') {
        const sensorData = dataType === 'both' ? data.sensor_data : data.data;
        
        if (sensorData && sensorData.length > 0) {
            tableHTML += `
                <thead>
                    <tr>
                        <th>Time</th>
                        <th>Temp (°C)</th>
                        <th>Vibration</th>
                        <th>Current (A)</th>
                        <th>Accel (X,Y,Z)</th>
                    </tr>
                </thead>
                <tbody>
            `;
            
            sensorData.slice(0, 10).forEach(item => {
                tableHTML += `
                    <tr>
                        <td>${new Date(item.datetime).toLocaleString()}</td>
                        <td>${item.temp_c?.toFixed(1) || 'N/A'}</td>
                        <td>${item.vibration?.toFixed(2) || 'N/A'}</td>
                        <td>${item.current_a?.toFixed(3) || 'N/A'}</td>
                        <td>${item.ax || 0}, ${item.ay || 0}, ${item.az || 0}</td>
                    </tr>
                `;
            });
            tableHTML += '</tbody>';
        }
    }
    
    if (dataType === 'predictions' || dataType === 'both') {
        const predictionData = dataType === 'both' ? data.prediction_data : data.data;
        
        if (predictionData && predictionData.length > 0) {
            if (dataType === 'both') tableHTML += '<br><h4>ML Predictions</h4>';
            
            tableHTML += `
                <thead>
                    <tr>
                        <th>Time</th>
                        <th>Prediction</th>
                        <th>Confidence</th>
                        <th>Score</th>
                        <th>Days to Maintenance</th>
                    </tr>
                </thead>
                <tbody>
            `;
            
            predictionData.slice(0, 10).forEach(item => {
                const predictionClass = item.prediction === 'Normal' ? 'prediction-normal' :
                                      item.prediction === 'Warning' ? 'prediction-warning' :
                                      'prediction-maintenance';
                
                tableHTML += `
                    <tr>
                        <td>${new Date(item.datetime).toLocaleString()}</td>
                        <td class="${predictionClass}">${item.prediction}</td>
                        <td>${(item.confidence * 100).toFixed(1)}%</td>
                        <td>${item.score?.toFixed(2) || 'N/A'}</td>
                        <td>${item.days_until_maintenance || 'N/A'}</td>
                    </tr>
                `;
            });
            tableHTML += '</tbody>';
        }
    }
    
    tableHTML += '</table></div>';
    
    if (!data.data && !data.sensor_data && !data.prediction_data) {
        tableHTML = '<p>No data available</p>';
    }
    
    tableContainer.innerHTML = tableHTML;
}

// Auto refresh functionality
function autoRefresh() {
    if (autoRefreshInterval) {
        clearInterval(autoRefreshInterval);
        autoRefreshInterval = null;
        document.querySelector('button[onclick="autoRefresh()"]').textContent = 'Auto Refresh';
        updateStatus('Auto refresh stopped', 'info');
    } else {
        autoRefreshInterval = setInterval(loadData, 30000); // Refresh every 30 seconds
        document.querySelector('button[onclick="autoRefresh()"]').textContent = 'Stop Refresh';
        updateStatus('Auto refresh enabled (30s interval)', 'info');
        loadData(); // Load data immediately
    }
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', function() {
    initCharts();
    
    // Check if API endpoint is configured
    if (API_ENDPOINT === 'API_GATEWAY_ENDPOINT_PLACEHOLDER') {
        updateStatus('API endpoint not configured. Please deploy the infrastructure first.', 'error');
    } else {
        loadData(); // Load initial data
    }
});