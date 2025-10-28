import { useState } from 'react'
import './App.css'

function App() {
  const [data, setData] = useState([])
  const [selectedMetric, setSelectedMetric] = useState('temp_c')
  const [darkMode, setDarkMode] = useState(false)
  const [timeRange, setTimeRange] = useState('all')
  const [scrollPosition, setScrollPosition] = useState(0)

  const handleFileUpload = (event) => {
    const file = event.target.files[0]
    if (file) {
      const reader = new FileReader()
      reader.onload = (e) => {
        const csv = e.target.result
        const lines = csv.split('\n')
        const headers = lines[0].split(',')
        const parsedData = lines.slice(1)
          .filter(line => line.trim())
          .map(line => {
            const values = line.split(',')
            return headers.reduce((obj, header, index) => {
              obj[header] = isNaN(values[index]) ? values[index] : Number(values[index])
              return obj
            }, {})
          })
        setData(parsedData)
      }
      reader.readAsText(file)
    }
  }

  const getChartData = () => {
    let filteredData = data
    
    if (timeRange !== 'all' && data.length > 0) {
      const pointsPerRange = {
        '1min': 20,
        '5min': 100,
        '30min': 600,
        '1hour': 1200
      }
      const rangeSize = pointsPerRange[timeRange] || data.length
      const startIndex = Math.max(0, Math.min(scrollPosition, data.length - rangeSize))
      filteredData = data.slice(startIndex, startIndex + rangeSize)
    }
    
    return filteredData.map((row, index) => {
      let yValue = row[selectedMetric] || 0
      
      if (selectedMetric === 'accel_xy') {
        yValue = Math.sqrt((row.ax || 0) ** 2 + (row.ay || 0) ** 2)
      } else if (selectedMetric === 'gyro_xy') {
        yValue = Math.sqrt((row.gx || 0) ** 2 + (row.gy || 0) ** 2)
      }
      
      return {
        x: index,
        y: yValue,
        timestamp: row.timestamp
      }
    })
  }

  const chartData = getChartData()
  const maxY = chartData.length > 0 ? Math.max(...chartData.map(d => d.y)) : 0
  const minY = chartData.length > 0 ? Math.min(...chartData.map(d => d.y)) : 0

  return (
    <div className={darkMode ? 'dark' : 'light'} style={{ padding: '20px', minHeight: '100vh' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '20px' }}>
        <h1>Sensor Data Visualization</h1>
        <button onClick={() => setDarkMode(!darkMode)}>
          {darkMode ? '☀️' : '🌙'}
        </button>
      </div>
      
      <input 
        type="file" 
        accept=".csv" 
        onChange={handleFileUpload}
        style={{ marginBottom: '20px' }}
      />
      
      {data.length > 0 && (
        <>
          <div style={{ marginBottom: '20px', display: 'flex', gap: '10px', alignItems: 'center' }}>
            <select 
              value={selectedMetric} 
              onChange={(e) => setSelectedMetric(e.target.value)}
            >
              <option value="temp_c">Temperature (°C)</option>
              <option value="ax">Acceleration X</option>
              <option value="ay">Acceleration Y</option>
              <option value="az">Acceleration Z</option>
              <option value="gx">Gyroscope X</option>
              <option value="gy">Gyroscope Y</option>
              <option value="gz">Gyroscope Z</option>
              <option value="current_a">Current (A)</option>
              <option value="accel_xy">Acceleration XY Vector</option>
              <option value="gyro_xy">Gyroscope XY Vector</option>
            </select>
            
            <select 
              value={timeRange} 
              onChange={(e) => { setTimeRange(e.target.value); setScrollPosition(0); }}
            >
              <option value="all">All Data</option>
              <option value="1min">1 Minute</option>
              <option value="5min">5 Minutes</option>
              <option value="30min">30 Minutes</option>
              <option value="1hour">1 Hour</option>
            </select>
            
            {timeRange !== 'all' && (
              <input
                type="range"
                min="0"
                max={Math.max(0, data.length - (timeRange === '1min' ? 20 : timeRange === '5min' ? 100 : timeRange === '30min' ? 600 : 1200))}
                value={scrollPosition}
                onChange={(e) => setScrollPosition(Number(e.target.value))}
                style={{ width: '200px' }}
              />
            )}
          </div>
          
          <div className="chart-container">
            <h3>{selectedMetric.toUpperCase()} over Time</h3>
            <svg width="800" height="400" className="chart-svg">
              {/* Y-axis labels */}
              {[0, 0.25, 0.5, 0.75, 1].map(ratio => (
                <text key={ratio} x="10" y={380 - ratio * 340} fontSize="12" fill={darkMode ? '#ccc' : '#666'}>
                  {(minY + (maxY - minY) * ratio).toFixed(1)}
                </text>
              ))}
              {/* X-axis labels */}
              {[0, 0.25, 0.5, 0.75, 1].map(ratio => {
                const index = Math.round(ratio * (chartData.length - 1))
                const timestamp = chartData[index]?.timestamp
                const timeStr = timestamp ? new Date(timestamp * 1000).toLocaleTimeString() : ''
                return (
                  <text key={ratio} x={20 + ratio * 760} y="395" fontSize="10" fill={darkMode ? '#ccc' : '#666'} textAnchor="middle">
                    {timeStr}
                  </text>
                )
              })}
              <polyline
                fill="none"
                stroke="#0066cc"
                strokeWidth="2"
                points={chartData.map((d, i) => 
                  `${(i / (chartData.length - 1)) * 760 + 20},${380 - ((d.y - minY) / (maxY - minY)) * 340}`
                ).join(' ')}
              />
              {chartData.map((d, i) => (
                <circle
                  key={i}
                  cx={(i / (chartData.length - 1)) * 760 + 20}
                  cy={380 - ((d.y - minY) / (maxY - minY)) * 340}
                  r="3"
                  fill="#0066cc"
                />
              ))}
            </svg>
            <p>Min: {minY.toFixed(2)} | Max: {maxY.toFixed(2)} | Points: {chartData.length} / {data.length}</p>
          </div>
          
          <div style={{ marginTop: '20px', maxHeight: '300px', overflow: 'auto' }}>
            <h3>Data Table</h3>
            <table style={{ width: '100%', borderCollapse: 'collapse' }}>
              <thead>
                <tr style={{ backgroundColor: '#f0f0f0' }}>
                  {Object.keys(data[0]).map(key => (
                    <th key={key} style={{ border: '1px solid #ccc', padding: '8px' }}>{key}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {data.slice(0, 50).map((row, i) => (
                  <tr key={i}>
                    {Object.values(row).map((value, j) => (
                      <td key={j} style={{ border: '1px solid #ccc', padding: '8px' }}>
                        {typeof value === 'number' ? value.toFixed(3) : value}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
            {data.length > 50 && <p>Showing first 50 rows of {data.length} total</p>}
          </div>
        </>
      )}
    </div>
  )
}

export default App
