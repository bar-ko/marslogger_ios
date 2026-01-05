/*
 Thread-safe ring buffer for storing sensor data samples
 */

import Foundation

struct SensorSample {
    let timestamp: TimeInterval
    let x: Double
    let y: Double
    let z: Double
}

class SensorRingBuffer {
    private let maxSamples: Int
    private let timeWindow: TimeInterval
    
    private var buffer: [SensorSample] = []
    private let lock = NSLock()
    
    // Auto-scaling parameters
    private var minX: Double = -1.0
    private var maxX: Double = 1.0
    private var minY: Double = -1.0
    private var maxY: Double = 1.0
    private var minZ: Double = -1.0
    private var maxZ: Double = 1.0
    
    private let smoothingFactor: Double = 0.95 // Exponential smoothing factor
    
    init(maxSamples: Int = 500, timeWindow: TimeInterval = 5.0) {
        self.maxSamples = maxSamples
        self.timeWindow = timeWindow
    }
    
    func append(timestamp: TimeInterval, x: Double, y: Double, z: Double) {
        lock.lock()
        defer { lock.unlock() }
        
        let sample = SensorSample(timestamp: timestamp, x: x, y: y, z: z)
        
        // Remove old samples outside time window
        let cutoffTime = timestamp - timeWindow
        buffer.removeAll { $0.timestamp < cutoffTime }
        
        // Add new sample
        buffer.append(sample)
        
        // Limit buffer size
        if buffer.count > maxSamples {
            buffer.removeFirst(buffer.count - maxSamples)
        }
        
        // Update auto-scaling with exponential smoothing
        updateScaling(x: x, y: y, z: z)
    }
    
    private func updateScaling(x: Double, y: Double, z: Double) {
        // Update min/max with exponential smoothing to avoid jitter
        let absX = abs(x)
        let absY = abs(y)
        let absZ = abs(z)
        
        // Expand range if needed, but smooth it
        if absX > maxX {
            maxX = smoothingFactor * maxX + (1.0 - smoothingFactor) * absX * 1.1
        } else {
            maxX = smoothingFactor * maxX + (1.0 - smoothingFactor) * absX * 1.1
        }
        
        if absY > maxY {
            maxY = smoothingFactor * maxY + (1.0 - smoothingFactor) * absY * 1.1
        } else {
            maxY = smoothingFactor * maxY + (1.0 - smoothingFactor) * absY * 1.1
        }
        
        if absZ > maxZ {
            maxZ = smoothingFactor * maxZ + (1.0 - smoothingFactor) * absZ * 1.1
        } else {
            maxZ = smoothingFactor * maxZ + (1.0 - smoothingFactor) * absZ * 1.1
        }
        
        // Ensure minimum range
        if maxX < 0.1 { maxX = 0.1 }
        if maxY < 0.1 { maxY = 0.1 }
        if maxZ < 0.1 { maxZ = 0.1 }
        
        minX = -maxX
        minY = -maxY
        minZ = -maxZ
    }
    
    func getSamples() -> [SensorSample] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
    
    func getScaling() -> (minX: Double, maxX: Double, minY: Double, maxY: Double, minZ: Double, maxZ: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (minX, maxX, minY, maxY, minZ, maxZ)
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll()
        minX = -1.0
        maxX = 1.0
        minY = -1.0
        maxY = 1.0
        minZ = -1.0
        maxZ = 1.0
    }
}




