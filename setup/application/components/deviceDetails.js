// Device Details Modal - 30-day Prediction Analytics
// This module handles the device detail modal showing prediction breakdown over 30 days

class DeviceDetailsModal {
    constructor() {
        this.modal = null;
        this.currentDeviceId = null;
        this.currentData = null;
        this.fullPredictions = [];
        this.fullSensorData = [];
        this.pairedData = [];
        this.init();
    }

    init() {
        // Create modal HTML structure
        const modalHtml = `
            <div id="device-details-modal" class="modal-overlay" style="display: none;">
                <div class="modal-content">
                    <div class="modal-header">
                        <h2 id="modal-device-name">Device Details</h2>
                        <div class="modal-actions">
                            <button class="export-excel-btn" id="export-excel-btn">Export to Excel</button>
                            <button class="modal-close" aria-label="Close modal">&times;</button>
                        </div>
                    </div>
                    
                    <div class="modal-body">
                        <div class="modal-section">
                            <h3>30-Day Prediction Summary</h3>
                            <div class="prediction-stats-grid">
                                <div class="stat-card anomaly-stat">
                                    <div class="stat-icon">!</div>
                                    <div class="stat-content">
                                        <div class="stat-label">Anomaly Detected</div>
                                        <div class="stat-value" id="stat-anomaly">0</div>
                                        <div class="stat-percentage" id="stat-anomaly-pct">0%</div>
                                    </div>
                                </div>
                                <div class="stat-card warning-stat">
                                    <div class="stat-icon">~</div>
                                    <div class="stat-content">
                                        <div class="stat-label">Warning</div>
                                        <div class="stat-value" id="stat-warning">0</div>
                                        <div class="stat-percentage" id="stat-warning-pct">0%</div>
                                    </div>
                                </div>
                                <div class="stat-card normal-stat">
                                    <div class="stat-icon">✓</div>
                                    <div class="stat-content">
                                        <div class="stat-label">Normal</div>
                                        <div class="stat-value" id="stat-normal">0</div>
                                        <div class="stat-percentage" id="stat-normal-pct">0%</div>
                                    </div>
                                </div>
                                <div class="stat-card total-stat">
                                    <div class="stat-icon">#</div>
                                    <div class="stat-content">
                                        <div class="stat-label">Total Predictions</div>
                                        <div class="stat-value" id="stat-total">0</div>
                                        <div class="stat-percentage" id="stat-timespan">30 days</div>
                                    </div>
                                </div>
                            </div>
                        </div>

                        <div class="modal-section">
                            <h3>Prediction Trend (Last 30 Days)</h3>
                            <div class="chart-container">
                                <canvas id="modal-trend-chart"></canvas>
                            </div>
                        </div>

                        <div class="modal-section">
                            <h3>Score Distribution</h3>
                            <div class="chart-container">
                                <canvas id="modal-distribution-chart"></canvas>
                            </div>
                        </div>

                        <div class="modal-section">
                            <h3>Recent Predictions</h3>
                            <div class="recent-predictions-list" id="recent-predictions">
                                <!-- Populated dynamically -->
                            </div>
                        </div>

                        <div class="modal-section">
                            <h3>Complete Data History (30 Days)</h3>
                            <div class="table-controls">
                                <input type="text" id="table-search" placeholder="Search by timestamp, classification..." class="table-search-input">
                                <select id="classification-filter" class="classification-filter">
                                    <option value="all">All Classifications</option>
                                    <option value="anomaly">Anomaly Detected</option>
                                    <option value="warning">Warning</option>
                                    <option value="normal">Normal</option>
                                </select>
                            </div>
                            <div class="full-data-list" id="full-data-list">
                                <!-- Populated dynamically -->
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        `;

        // Inject modal into document
        document.body.insertAdjacentHTML('beforeend', modalHtml);
        this.modal = document.getElementById('device-details-modal');

        // Setup event listeners
        this.setupEventListeners();
    }

    setupEventListeners() {
        // Close button
        const closeBtn = this.modal.querySelector('.modal-close');
        closeBtn.addEventListener('click', () => this.close());

        // Export to Excel button
        const exportBtn = this.modal.querySelector('#export-excel-btn');
        exportBtn.addEventListener('click', () => this.exportToExcel());

        // Click outside modal to close
        this.modal.addEventListener('click', (e) => {
            if (e.target === this.modal) {
                this.close();
            }
        });

        // Escape key to close
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape' && this.modal.style.display === 'flex') {
                this.close();
            }
        });

        // Search and filter handlers
        const searchInput = this.modal.querySelector('#table-search');
        const filterSelect = this.modal.querySelector('#classification-filter');
        
        searchInput.addEventListener('input', () => this.filterDataTable());
        filterSelect.addEventListener('change', () => this.filterDataTable());
    }

    async open(deviceId, deviceData) {
        this.currentDeviceId = deviceId;
        this.currentData = deviceData;

        // Update modal title
        document.getElementById('modal-device-name').textContent = `${deviceId} - Detailed Analytics`;

        // Fetch 30-day data
        await this.fetch30DayData(deviceId);

        // Show modal with animation
        this.modal.style.display = 'flex';
        setTimeout(() => {
            this.modal.classList.add('modal-visible');
        }, 10);

        // Prevent body scroll
        document.body.style.overflow = 'hidden';
    }

    close() {
        this.modal.classList.remove('modal-visible');
        setTimeout(() => {
            this.modal.style.display = 'none';
            document.body.style.overflow = '';
            
            // Destroy charts if they exist
            if (window.modalTrendChart) {
                window.modalTrendChart.destroy();
                window.modalTrendChart = null;
            }
            if (window.modalDistributionChart) {
                window.modalDistributionChart.destroy();
                window.modalDistributionChart = null;
            }
        }, 300);
    }

    async fetch30DayData(deviceId) {
        try {
            // Fetch 30 days of both sensor and prediction data (720 hours)
            const data = await window.apiClient.fetchHistoricalData(deviceId, 30, 5000);

            this.fullPredictions = data.prediction_data || [];
            this.fullSensorData = data.sensor_data || [];

            // Pair predictions with nearest sensor readings
            this.pairPredictionsWithSensors();

            // Calculate prediction breakdown
            this.calculatePredictionBreakdown(this.fullPredictions);

            // Render charts
            this.renderTrendChart(this.fullPredictions);
            this.renderDistributionChart(this.fullPredictions);

            // Show recent predictions table (top 10)
            this.renderRecentPredictions(this.fullPredictions.slice(0, 10));

            // Render full data table
            this.renderFullDataTable();

        } catch (error) {
            console.error('Error fetching 30-day data:', error);
            this.showError('Failed to load 30-day analytics');
        }
    }

    pairPredictionsWithSensors() {
        this.pairedData = [];
        
        // Create a map of sensor data by timestamp for quick lookup
        const sensorMap = new Map();
        this.fullSensorData.forEach(sensor => {
            sensorMap.set(sensor.timestamp, sensor);
        });

        // For each prediction, find the closest sensor reading (within 10 seconds)
        this.fullPredictions.forEach((pred, idx) => {
            // Calculate classification
            const window = this.fullPredictions.slice(Math.max(0, idx - 4), idx + 1);
            const highScoreCount = window.filter(p => p.score >= 50).length;

            let classification = 'Normal';
            let classStyle = 'normal';
            if (highScoreCount >= 4) {
                classification = 'Anomaly Detected';
                classStyle = 'anomaly';
            } else if (highScoreCount === 3) {
                classification = 'Warning';
                classStyle = 'warning';
            }

            // Find nearest sensor reading
            let closestSensor = null;
            let minDiff = Infinity;
            
            this.fullSensorData.forEach(sensor => {
                const diff = Math.abs(sensor.timestamp - pred.timestamp);
                if (diff < minDiff && diff <= 10) { // Within 10 seconds
                    minDiff = diff;
                    closestSensor = sensor;
                }
            });

            this.pairedData.push({
                timestamp: pred.timestamp,
                prediction: pred,
                sensor: closestSensor,
                classification: classification,
                classStyle: classStyle,
                highScoreCount: highScoreCount
            });
        });
    }

    calculatePredictionBreakdown(predictions) {
        let anomalyCount = 0;
        let warningCount = 0;
        let normalCount = 0;

        // Group predictions into 5-reading windows and apply same logic as dashboard
        for (let i = 0; i < predictions.length; i++) {
            // Get the 5 most recent predictions at this point in time
            const window = predictions.slice(Math.max(0, i - 4), i + 1);
            const highScoreCount = window.filter(p => p.score >= 50).length;

            // Apply same classification logic as app.js
            if (highScoreCount >= 4) {
                anomalyCount++;
            } else if (highScoreCount === 3) {
                warningCount++;
            } else {
                normalCount++;
            }
        }

        const total = predictions.length;

        // Update stats in modal
        document.getElementById('stat-anomaly').textContent = anomalyCount;
        document.getElementById('stat-warning').textContent = warningCount;
        document.getElementById('stat-normal').textContent = normalCount;
        document.getElementById('stat-total').textContent = total;

        // Calculate percentages
        document.getElementById('stat-anomaly-pct').textContent = 
            total > 0 ? `${(anomalyCount / total * 100).toFixed(1)}%` : '0%';
        document.getElementById('stat-warning-pct').textContent = 
            total > 0 ? `${(warningCount / total * 100).toFixed(1)}%` : '0%';
        document.getElementById('stat-normal-pct').textContent = 
            total > 0 ? `${(normalCount / total * 100).toFixed(1)}%` : '0%';
    }

    renderTrendChart(predictions) {
        const ctx = document.getElementById('modal-trend-chart');
        if (!ctx) return;

        // Destroy existing chart
        if (window.modalTrendChart) {
            window.modalTrendChart.destroy();
        }

        // Reverse for chronological order
        const reversed = [...predictions].reverse();

        // Group by day
        const dailyData = this.groupByDay(reversed);

        const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
        const textColor = isDark ? '#e6e6e6' : '#1a1a1a';
        const gridColor = isDark ? '#30363d' : '#d9d9d9';

        window.modalTrendChart = new Chart(ctx, {
            type: 'line',
            data: {
                labels: dailyData.map(d => d.date),
                datasets: [
                    {
                        label: 'Anomaly Detected',
                        data: dailyData.map(d => d.anomalyCount),
                        borderColor: '#f44336',
                        backgroundColor: 'rgba(244, 67, 54, 0.1)',
                        tension: 0.4,
                        fill: true
                    },
                    {
                        label: 'Warning',
                        data: dailyData.map(d => d.warningCount),
                        borderColor: '#ff9800',
                        backgroundColor: 'rgba(255, 152, 0, 0.1)',
                        tension: 0.4,
                        fill: true
                    },
                    {
                        label: 'Normal',
                        data: dailyData.map(d => d.normalCount),
                        borderColor: '#4CAF50',
                        backgroundColor: 'rgba(76, 175, 80, 0.1)',
                        tension: 0.4,
                        fill: true
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {
                        labels: { color: textColor }
                    },
                    tooltip: {
                        mode: 'index',
                        intersect: false
                    }
                },
                scales: {
                    x: {
                        ticks: { color: textColor },
                        grid: { color: gridColor }
                    },
                    y: {
                        ticks: { color: textColor },
                        grid: { color: gridColor },
                        stacked: false
                    }
                }
            }
        });
    }

    renderDistributionChart(predictions) {
        const ctx = document.getElementById('modal-distribution-chart');
        if (!ctx) return;

        // Destroy existing chart
        if (window.modalDistributionChart) {
            window.modalDistributionChart.destroy();
        }

        // Count predictions by classification
        let anomalyCount = 0;
        let warningCount = 0;
        let normalCount = 0;

        for (let i = 0; i < predictions.length; i++) {
            const window = predictions.slice(Math.max(0, i - 4), i + 1);
            const highScoreCount = window.filter(p => p.score >= 50).length;

            if (highScoreCount >= 4) {
                anomalyCount++;
            } else if (highScoreCount === 3) {
                warningCount++;
            } else {
                normalCount++;
            }
        }

        const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
        const textColor = isDark ? '#e6e6e6' : '#1a1a1a';

        window.modalDistributionChart = new Chart(ctx, {
            type: 'doughnut',
            data: {
                labels: ['Anomaly Detected', 'Warning', 'Normal'],
                datasets: [{
                    data: [anomalyCount, warningCount, normalCount],
                    backgroundColor: [
                        'rgba(244, 67, 54, 0.8)',
                        'rgba(255, 152, 0, 0.8)',
                        'rgba(76, 175, 80, 0.8)'
                    ],
                    borderColor: [
                        '#f44336',
                        '#ff9800',
                        '#4CAF50'
                    ],
                    borderWidth: 2
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                plugins: {
                    legend: {
                        labels: { color: textColor },
                        position: 'bottom'
                    },
                    tooltip: {
                        callbacks: {
                            label: function(context) {
                                const label = context.label || '';
                                const value = context.parsed || 0;
                                const total = context.dataset.data.reduce((a, b) => a + b, 0);
                                const percentage = ((value / total) * 100).toFixed(1);
                                return `${label}: ${value} (${percentage}%)`;
                            }
                        }
                    }
                }
            }
        });
    }

    renderRecentPredictions(predictions) {
        const container = document.getElementById('recent-predictions');
        if (!container) return;

        if (predictions.length === 0) {
            container.innerHTML = '<div class="no-data">No recent predictions available</div>';
            return;
        }

        let html = '<table class="predictions-table"><thead><tr><th>Time</th><th>Classification</th><th>Score</th><th>Pattern</th></tr></thead><tbody>';

        predictions.forEach((pred, idx) => {
            const date = new Date(pred.timestamp * 1000);
            const timeStr = date.toLocaleString();

            // Calculate classification for this prediction
            const window = predictions.slice(Math.max(0, idx - 4), idx + 1);
            const highScoreCount = window.filter(p => p.score >= 50).length;

            let classification = 'Normal';
            let classStyle = 'normal';
            if (highScoreCount >= 4) {
                classification = 'Anomaly Detected';
                classStyle = 'anomaly';
            } else if (highScoreCount === 3) {
                classification = 'Warning';
                classStyle = 'warning';
            }

            html += `
                <tr>
                    <td>${timeStr}</td>
                    <td><span class="prediction-badge-small ${classStyle}">${classification}</span></td>
                    <td>${pred.score.toFixed(1)}</td>
                    <td>${highScoreCount}/5 high</td>
                </tr>
            `;
        });

        html += '</tbody></table>';
        container.innerHTML = html;
    }

    groupByDay(predictions) {
        const dailyMap = new Map();

        predictions.forEach((pred, idx) => {
            const date = new Date(pred.timestamp * 1000);
            const dateKey = date.toLocaleDateString();

            if (!dailyMap.has(dateKey)) {
                dailyMap.set(dateKey, {
                    date: dateKey,
                    anomalyCount: 0,
                    warningCount: 0,
                    normalCount: 0
                });
            }

            // Calculate classification
            const window = predictions.slice(Math.max(0, idx - 4), idx + 1);
            const highScoreCount = window.filter(p => p.score >= 50).length;

            const dayData = dailyMap.get(dateKey);
            if (highScoreCount >= 4) {
                dayData.anomalyCount++;
            } else if (highScoreCount === 3) {
                dayData.warningCount++;
            } else {
                dayData.normalCount++;
            }
        });

        return Array.from(dailyMap.values());
    }

    showError(message) {
        const modalBody = this.modal.querySelector('.modal-body');
        modalBody.innerHTML = `<div class="error-message">${message}</div>`;
    }

    renderFullDataTable() {
        const container = document.getElementById('full-data-list');
        if (!container) return;

        if (this.pairedData.length === 0) {
            container.innerHTML = '<div class="no-data">No data available</div>';
            return;
        }

        let html = `
            <table class="full-data-table">
                <thead>
                    <tr>
                        <th>Timestamp</th>
                        <th>Classification</th>
                        <th>ML Score</th>
                        <th>Pattern</th>
                        <th>Temp (°C)</th>
                        <th>Vibration (m/s²)</th>
                        <th>Current (A)</th>
                        <th>Accel X</th>
                        <th>Accel Y</th>
                        <th>Accel Z</th>
                    </tr>
                </thead>
                <tbody>
        `;

        this.pairedData.forEach(pair => {
            const date = new Date(pair.timestamp * 1000);
            const timeStr = date.toLocaleString();
            
            const sensor = pair.sensor;
            const tempC = sensor ? sensor.temp_c.toFixed(1) : 'N/A';
            const vibMag = sensor ? Math.sqrt(
                Math.pow(sensor.ax || 0, 2) + 
                Math.pow(sensor.ay || 0, 2) + 
                Math.pow(sensor.az || 0, 2)
            ).toFixed(2) : 'N/A';
            const current = sensor ? sensor.current_a.toFixed(3) : 'N/A';
            const ax = sensor ? sensor.ax.toFixed(3) : 'N/A';
            const ay = sensor ? sensor.ay.toFixed(3) : 'N/A';
            const az = sensor ? sensor.az.toFixed(3) : 'N/A';

            html += `
                <tr data-classification="${pair.classStyle}">
                    <td>${timeStr}</td>
                    <td><span class="prediction-badge-small ${pair.classStyle}">${pair.classification}</span></td>
                    <td>${pair.prediction.score.toFixed(1)}</td>
                    <td>${pair.highScoreCount}/5</td>
                    <td>${tempC}</td>
                    <td>${vibMag}</td>
                    <td>${current}</td>
                    <td>${ax}</td>
                    <td>${ay}</td>
                    <td>${az}</td>
                </tr>
            `;
        });

        html += '</tbody></table>';
        container.innerHTML = html;
    }

    filterDataTable() {
        const searchTerm = document.getElementById('table-search').value.toLowerCase();
        const filterValue = document.getElementById('classification-filter').value;
        
        const rows = document.querySelectorAll('.full-data-table tbody tr');
        
        rows.forEach(row => {
            const classification = row.getAttribute('data-classification');
            const text = row.textContent.toLowerCase();
            
            const matchesSearch = text.includes(searchTerm);
            const matchesFilter = filterValue === 'all' || classification === filterValue;
            
            row.style.display = (matchesSearch && matchesFilter) ? '' : 'none';
        });
    }

    exportToExcel() {
        if (this.pairedData.length === 0) {
            alert('No data to export');
            return;
        }

        // Create CSV content
        let csv = 'Timestamp,Classification,ML Score,Pattern (High/5),Temperature (°C),Vibration (m/s²),Current (A),Accel X,Accel Y,Accel Z,Reconstruction Error,Days to Maintenance\n';
        
        this.pairedData.forEach(pair => {
            const date = new Date(pair.timestamp * 1000);
            const timeStr = date.toLocaleString();
            
            const sensor = pair.sensor;
            const tempC = sensor ? sensor.temp_c : '';
            const vibMag = sensor ? Math.sqrt(
                Math.pow(sensor.ax || 0, 2) + 
                Math.pow(sensor.ay || 0, 2) + 
                Math.pow(sensor.az || 0, 2)
            ) : '';
            const current = sensor ? sensor.current_a : '';
            const ax = sensor ? sensor.ax : '';
            const ay = sensor ? sensor.ay : '';
            const az = sensor ? sensor.az : '';
            
            const reconError = pair.prediction.reconstruction_error || '';
            const daysToMaint = pair.prediction.days_until_maintenance || '';
            
            csv += `"${timeStr}","${pair.classification}",${pair.prediction.score},${pair.highScoreCount},${tempC},${vibMag},${current},${ax},${ay},${az},${reconError},${daysToMaint}\n`;
        });

        // Create download link
        const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
        const url = URL.createObjectURL(blob);
        const link = document.createElement('a');
        link.setAttribute('href', url);
        link.setAttribute('download', `${this.currentDeviceId}_30day_report_${Date.now()}.csv`);
        link.style.visibility = 'hidden';
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        URL.revokeObjectURL(url);
    }
}

// Initialize modal when DOM is ready
let deviceDetailsModal;
document.addEventListener('DOMContentLoaded', () => {
    deviceDetailsModal = new DeviceDetailsModal();
});

// Make it globally accessible
window.openDeviceDetails = function(deviceId, deviceData) {
    if (deviceDetailsModal) {
        deviceDetailsModal.open(deviceId, deviceData);
    }
};
