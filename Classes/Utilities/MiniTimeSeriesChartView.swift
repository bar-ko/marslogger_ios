/*
 Mini time-series chart view for displaying 3-axis sensor data
 Uses CAShapeLayer for efficient drawing
 */

import UIKit

class MiniTimeSeriesChartView: UIView {
    
    private let titleLabel: UILabel
    private let xLabel: UILabel
    private let yLabel: UILabel
    private let zLabel: UILabel
    
    private let xPathLayer: CAShapeLayer
    private let yPathLayer: CAShapeLayer
    private let zPathLayer: CAShapeLayer
    private let gridLayer: CAShapeLayer
    
    private var ringBuffer: SensorRingBuffer?
    
    // Configuration
    private let padding: CGFloat = 8.0
    private let labelHeight: CGFloat = 12.0
    private let titleHeight: CGFloat = 16.0
    
    // Colors
    private let xColor = UIColor.red.withAlphaComponent(0.8)
    private let yColor = UIColor.green.withAlphaComponent(0.8)
    private let zColor = UIColor.blue.withAlphaComponent(0.8)
    private let gridColor = UIColor.white.withAlphaComponent(0.2)
    private let chartBackgroundColor = UIColor.black.withAlphaComponent(0.6)
    
    override init(frame: CGRect) {
        // Create title label
        titleLabel = UILabel()
        titleLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .left
        
        // Create axis labels
        xLabel = UILabel()
        xLabel.font = UIFont.systemFont(ofSize: 8)
        xLabel.textColor = xColor
        xLabel.text = "x"
        
        yLabel = UILabel()
        yLabel.font = UIFont.systemFont(ofSize: 8)
        yLabel.textColor = yColor
        yLabel.text = "y"
        
        zLabel = UILabel()
        zLabel.font = UIFont.systemFont(ofSize: 8)
        zLabel.textColor = zColor
        zLabel.text = "z"
        
        // Create shape layers
        gridLayer = CAShapeLayer()
        gridLayer.strokeColor = gridColor.cgColor
        gridLayer.fillColor = UIColor.clear.cgColor
        gridLayer.lineWidth = 0.5
        
        xPathLayer = CAShapeLayer()
        xPathLayer.strokeColor = xColor.cgColor
        xPathLayer.fillColor = UIColor.clear.cgColor
        xPathLayer.lineWidth = 1.0
        xPathLayer.lineCap = .round
        xPathLayer.lineJoin = .round
        
        yPathLayer = CAShapeLayer()
        yPathLayer.strokeColor = yColor.cgColor
        yPathLayer.fillColor = UIColor.clear.cgColor
        yPathLayer.lineWidth = 1.0
        yPathLayer.lineCap = .round
        yPathLayer.lineJoin = .round
        
        zPathLayer = CAShapeLayer()
        zPathLayer.strokeColor = zColor.cgColor
        zPathLayer.fillColor = UIColor.clear.cgColor
        zPathLayer.lineWidth = 1.0
        zPathLayer.lineCap = .round
        zPathLayer.lineJoin = .round
        
        super.init(frame: frame)
        
        // Setup view
        self.backgroundColor = chartBackgroundColor
        layer.cornerRadius = 4.0
        
        // Add subviews
        addSubview(titleLabel)
        addSubview(xLabel)
        addSubview(yLabel)
        addSubview(zLabel)
        
        // Add layers
        layer.addSublayer(gridLayer)
        layer.addSublayer(xPathLayer)
        layer.addSublayer(yPathLayer)
        layer.addSublayer(zPathLayer)
        
        // Setup constraints
        setupConstraints()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupConstraints() {
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        xLabel.translatesAutoresizingMaskIntoConstraints = false
        yLabel.translatesAutoresizingMaskIntoConstraints = false
        zLabel.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            titleLabel.heightAnchor.constraint(equalToConstant: titleHeight),
            
            xLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
            xLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            xLabel.widthAnchor.constraint(equalToConstant: 20),
            xLabel.heightAnchor.constraint(equalToConstant: labelHeight),
            
            yLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
            yLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            yLabel.widthAnchor.constraint(equalToConstant: 20),
            yLabel.heightAnchor.constraint(equalToConstant: labelHeight),
            
            zLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
            zLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            zLabel.widthAnchor.constraint(equalToConstant: 20),
            zLabel.heightAnchor.constraint(equalToConstant: labelHeight)
        ])
    }
    
    func setTitle(_ title: String) {
        titleLabel.text = title
    }
    
    func setRingBuffer(_ buffer: SensorRingBuffer) {
        ringBuffer = buffer
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        updateChart()
    }
    
    func updateChart() {
        guard let ringBuffer = ringBuffer else { return }
        
        let samples = ringBuffer.getSamples()
        guard !samples.isEmpty else {
            clearChart()
            return
        }
        
        let scaling = ringBuffer.getScaling()
        
        // Calculate chart area
        let chartTop = padding + titleHeight + 4
        let chartBottom = bounds.height - padding - labelHeight - 4
        let chartLeft = padding + 20
        let chartRight = bounds.width - padding - 20
        let chartHeight = chartBottom - chartTop
        let chartWidth = chartRight - chartLeft
        
        // Draw grid
        drawGrid(chartTop: chartTop, chartBottom: chartBottom, chartLeft: chartLeft, chartRight: chartRight)
        
        // Draw zero line
        let zeroY = chartTop + chartHeight / 2.0
        
        // Draw paths
        let xPath = UIBezierPath()
        let yPath = UIBezierPath()
        let zPath = UIBezierPath()
        
        guard !samples.isEmpty else {
            clearChart()
            return
        }
        
        // Calculate time range
        guard let latestTime = samples.last?.timestamp,
              let oldestTime = samples.first?.timestamp else {
            clearChart()
            return
        }
        let timeRange = latestTime - oldestTime
        guard timeRange > 0 else {
            clearChart()
            return
        }
        
        var firstPoint = true
        
        for sample in samples {
            // Calculate X position based on relative time (0 = oldest, 1 = newest)
            let relativeTime = (sample.timestamp - oldestTime) / timeRange
            let x = chartLeft + CGFloat(relativeTime) * chartWidth
            
            // Normalize sensor values to 0-1 range
            let normalizedX = normalize(value: sample.x, min: scaling.minX, max: scaling.maxX)
            let normalizedY = normalize(value: sample.y, min: scaling.minY, max: scaling.maxY)
            let normalizedZ = normalize(value: sample.z, min: scaling.minZ, max: scaling.maxZ)
            
            // Map normalized values (0-1) to chart Y coordinates
            // Invert Y axis: 0 = bottom, 1 = top
            let yX = chartBottom - CGFloat(normalizedX) * chartHeight
            let yY = chartBottom - CGFloat(normalizedY) * chartHeight
            let yZ = chartBottom - CGFloat(normalizedZ) * chartHeight
            
            if firstPoint {
                xPath.move(to: CGPoint(x: x, y: yX))
                yPath.move(to: CGPoint(x: x, y: yY))
                zPath.move(to: CGPoint(x: x, y: yZ))
                firstPoint = false
            } else {
                xPath.addLine(to: CGPoint(x: x, y: yX))
                yPath.addLine(to: CGPoint(x: x, y: yY))
                zPath.addLine(to: CGPoint(x: x, y: yZ))
            }
        }
        
        xPathLayer.path = xPath.cgPath
        yPathLayer.path = yPath.cgPath
        zPathLayer.path = zPath.cgPath
    }
    
    private func drawGrid(chartTop: CGFloat, chartBottom: CGFloat, chartLeft: CGFloat, chartRight: CGFloat) {
        let gridPath = UIBezierPath()
        
        // Horizontal zero line
        let zeroY = chartTop + (chartBottom - chartTop) / 2.0
        gridPath.move(to: CGPoint(x: chartLeft, y: zeroY))
        gridPath.addLine(to: CGPoint(x: chartRight, y: zeroY))
        
        // Vertical lines (time markers)
        let numVerticalLines = 5
        for i in 0...numVerticalLines {
            let x = chartLeft + CGFloat(i) * (chartRight - chartLeft) / CGFloat(numVerticalLines)
            gridPath.move(to: CGPoint(x: x, y: chartTop))
            gridPath.addLine(to: CGPoint(x: x, y: chartBottom))
        }
        
        gridLayer.path = gridPath.cgPath
    }
    
    private func normalize(value: Double, min: Double, max: Double) -> Double {
        let range = max - min
        guard range > 0 else { return 0.5 }
        let clamped = Swift.max(min, Swift.min(max, value))
        return (clamped - min) / range
    }
    
    private func clearChart() {
        xPathLayer.path = nil
        yPathLayer.path = nil
        zPathLayer.path = nil
        gridLayer.path = nil
    }
}

