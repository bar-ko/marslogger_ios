/*
 Sensor overlay view containing accelerometer and gyroscope charts
 */

import UIKit

protocol SensorOverlayViewDelegate: AnyObject {
    func sensorOverlayViewDidToggleVisibility(_ view: SensorOverlayView)
}

class SensorOverlayView: UIView {
    
    weak var delegate: SensorOverlayViewDelegate?
    
    private let accelChart: MiniTimeSeriesChartView
    private let gyroChart: MiniTimeSeriesChartView
    let toggleButton: UIButton
    
    var isVisible: Bool = true {
        didSet {
            accelChart.isHidden = !isVisible
            gyroChart.isHidden = !isVisible
            toggleButton.setTitle(isVisible ? "Sensors: On" : "Sensors: Off", for: .normal)
        }
    }
    
    private var displayLink: CADisplayLink?
    
    init(frame: CGRect, accelBuffer: SensorRingBuffer, gyroBuffer: SensorRingBuffer) {
        accelChart = MiniTimeSeriesChartView()
        accelChart.setTitle("ACC")
        accelChart.setRingBuffer(accelBuffer)
        
        gyroChart = MiniTimeSeriesChartView()
        gyroChart.setTitle("GYRO")
        gyroChart.setRingBuffer(gyroBuffer)
        
        toggleButton = UIButton(type: .system)
        toggleButton.setTitle("Sensors: On", for: .normal)
        toggleButton.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        toggleButton.setTitleColor(.white, for: .normal)
        toggleButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        toggleButton.layer.cornerRadius = 4.0
        
        super.init(frame: frame)
        
        backgroundColor = .clear
        
        toggleButton.addTarget(self, action: #selector(toggleButtonTapped), for: .touchUpInside)
        
        addSubview(accelChart)
        addSubview(gyroChart)
        addSubview(toggleButton)
        
        setupConstraints()
        
        // Start display link for smooth updates
        startDisplayLink()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupConstraints() {
        accelChart.translatesAutoresizingMaskIntoConstraints = false
        gyroChart.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            // Toggle button at top right
            toggleButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            toggleButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toggleButton.widthAnchor.constraint(equalToConstant: 100),
            toggleButton.heightAnchor.constraint(equalToConstant: 28),
            
            // Accelerometer chart
            accelChart.topAnchor.constraint(equalTo: toggleButton.bottomAnchor, constant: 8),
            accelChart.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            accelChart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            accelChart.heightAnchor.constraint(equalToConstant: 80),
            
            // Gyroscope chart
            gyroChart.topAnchor.constraint(equalTo: accelChart.bottomAnchor, constant: 4),
            gyroChart.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            gyroChart.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            gyroChart.heightAnchor.constraint(equalToConstant: 80),
            gyroChart.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
    }
    
    @objc private func toggleButtonTapped() {
        isVisible.toggle()
        delegate?.sensorOverlayViewDidToggleVisibility(self)
        
        if isVisible {
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
    }
    
    private func startDisplayLink() {
        stopDisplayLink()
        
        // Target 30 FPS (or 15 FPS if needed for performance)
        let targetFPS: Int = 30
        let frameInterval = max(1, 60 / targetFPS) // CADisplayLink runs at 60 FPS
        
        displayLink = CADisplayLink(target: self, selector: #selector(updateCharts))
        displayLink?.preferredFramesPerSecond = targetFPS
        displayLink?.add(to: .main, forMode: .common)
    }
    
    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        // Force chart updates when layout changes (e.g., on rotation)
        if isVisible {
            accelChart.updateChart()
            gyroChart.updateChart()
        }
    }
    
    @objc private func updateCharts() {
        guard isVisible else { return }
        accelChart.updateChart()
        gyroChart.updateChart()
    }
    
    deinit {
        stopDisplayLink()
    }
}

