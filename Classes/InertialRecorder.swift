import CoreLocation
import CoreMotion
import Foundation
import UIKit

let GRAVITY = 9.80  // see https://developer.apple.com/documentation/coremotion/getting_raw_accelerometer_events
let RATE = 100.0  // fps for inertial data

// MARK: - NodeWrapper

class NodeWrapper: NSObject {
    var time: TimeInterval = 0
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
    var isGyro: Bool = false

    func compare(_ otherObject: NodeWrapper) -> ComparisonResult {
        return NSNumber(value: self.time).compare(
            NSNumber(value: otherObject.time)
        )
    }
}

// MARK: - GPSNodeWrapper

class GPSNodeWrapper: NSObject {
    var time: TimeInterval = 0
    var latitude: Double = 0
    var longitude: Double = 0
    var speed: Double = 0

    func compare(_ otherObject: GPSNodeWrapper) -> ComparisonResult {
        return NSNumber(value: self.time).compare(
            NSNumber(value: otherObject.time)
        )
    }
}

// MARK: - Global Functions

func getFileURL(_ filename: String) -> URL? {
    let paths = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    )
    guard let documentsURL = paths.last else { return nil }
    return documentsURL.appendingPathComponent(filename, isDirectory: false)
}

func createOutputFolderURL() -> URL? {
    let now = Date()
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy_MM_dd_HH_mm_ss"
    let dateTimeString = dateFormatter.string(from: now)

    let paths = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    )
    guard let documentsURL = paths.last else { return nil }
    let outputFolderURL = documentsURL.appendingPathComponent(
        dateTimeString,
        isDirectory: true
    )

    do {
        try FileManager.default.createDirectory(
            at: outputFolderURL,
            withIntermediateDirectories: false,
            attributes: nil
        )
        return outputFolderURL
    } catch {
        print("Error creating directory: \(error)")
        return nil
    }
}

// MARK: - InertialRecorder

class InertialRecorder: NSObject, CLLocationManagerDelegate {

    // MARK: - Properties

    var fileURL: URL?
    var isRecording: Bool = false
    private(set) var currentSpeed: CLLocationSpeed = 0.0
    
    // GPS status for UI display
    private(set) var gpsStatus: String = "Initializing..."
    private(set) var gpsLatitude: Double = 0.0
    private(set) var gpsLongitude: Double = 0.0
    private(set) var gpsHorizontalAccuracy: Double = -1.0
    private(set) var gpsUpdateCount: Int = 0
    private(set) var lastGPSUpdateTimestamp: Date?

    private var motionManager: CMMotionManager
    private var locationManager: CLLocationManager
    private var queue: OperationQueue?
    private var timer: Timer?

    private var rawAccelGyroData: [NodeWrapper]?
    private var rawGPSData: [GPSNodeWrapper]?

    private var interpolateAccel: Bool = true  // interpolate accelerometer data at gyro timestamps?
    private var timeStartImu: String?
    private var bootTimeReference: TimeInterval = 0  // Store boot time reference for GPS synchronization
    private var lastGPSUpdateTime: TimeInterval = 0  // Track GPS update frequency
    
    // Visualization buffers (always active, not just during recording)
    private(set) var accelVisualizationBuffer: SensorRingBuffer
    private(set) var gyroVisualizationBuffer: SensorRingBuffer

    // MARK: - Initialization

    override init() {
        self.motionManager = CMMotionManager()
        self.locationManager = CLLocationManager()
        
        // Initialize visualization buffers (5 second window, ~500 samples at 100 Hz)
        self.accelVisualizationBuffer = SensorRingBuffer(maxSamples: 500, timeWindow: 5.0)
        self.gyroVisualizationBuffer = SensorRingBuffer(maxSamples: 500, timeWindow: 5.0)

        super.init()

        if !motionManager.isDeviceMotionAvailable {
            print("Device does not support motion capture.")
        }

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation  // Highest accuracy
        locationManager.distanceFilter = kCLDistanceFilterNone  // Update on every location change
        locationManager.pausesLocationUpdatesAutomatically = false  // Don't pause updates automatically
        locationManager.allowsBackgroundLocationUpdates = true  // Allow background updates
        
        // Start GPS location updates immediately for HUD speed display (not just when recording)
        startGPSUpdates()
        
        // Start motion updates for visualization (always running)
        startVisualizationUpdates()
    }
    
    // MARK: - Visualization Updates
    
    private func startVisualizationUpdates() {
        guard motionManager.isGyroAvailable && motionManager.isAccelerometerAvailable else {
            print("Motion sensors not available for visualization")
            return
        }
        
        // Use a queue for visualization updates (always running)
        let visQueue = OperationQueue()
        visQueue.name = "com.apple.sample.inertialRecorder.visualization"
        visQueue.qualityOfService = .userInitiated
        visQueue.maxConcurrentOperationCount = 1
        
        motionManager.gyroUpdateInterval = 1.0 / RATE
        motionManager.accelerometerUpdateInterval = 1.0 / RATE
        
        motionManager.startGyroUpdates(to: visQueue) { [weak self] (gyroData, error) in
            guard let self = self, let gyroData = gyroData else { return }
            
            let rotate = gyroData.rotationRate
            self.gyroVisualizationBuffer.append(
                timestamp: gyroData.timestamp,
                x: rotate.x,
                y: rotate.y,
                z: rotate.z
            )
        }
        
        motionManager.startAccelerometerUpdates(to: visQueue) { [weak self] (accelData, error) in
            guard let self = self, let accelData = accelData else { return }
            
            let accel = accelData.acceleration
            self.accelVisualizationBuffer.append(
                timestamp: accelData.timestamp,
                x: -accel.x,
                y: -accel.y,
                z: -accel.z
            )
        }
    }
    

    // MARK: - Helper Methods

    private func removeDuplicates(_ array: [NodeWrapper]) -> [NodeWrapper] {
        guard !array.isEmpty else { return [] }

        var mutableArray = array
        var index = array.count - 1

        for object in array.reversed() {
            if let foundIndex = mutableArray[0..<index].firstIndex(of: object) {
                mutableArray.remove(at: index)
            }
            index -= 1
        }

        return mutableArray
    }

    private func interpolateGPSData(
        atTime targetTime: TimeInterval,
        fromArray gpsArray: [GPSNodeWrapper],
        currentIndex: inout Int
    ) -> GPSNodeWrapper? {
        guard !gpsArray.isEmpty else { return nil }

        var lowerGPS: GPSNodeWrapper?
        var upperGPS: GPSNodeWrapper?
        var lowerIndex = -1
        var upperIndex = -1

        // Find the GPS data points surrounding the target time
        for i in currentIndex..<gpsArray.count {
            let gps = gpsArray[i]
            if gps.time <= targetTime {
                lowerGPS = gps
                lowerIndex = i
                currentIndex = i  // Update current index for efficiency
            } else {
                upperGPS = gps
                upperIndex = i
                break
            }
        }

        // If we have exact match
        if let lowerGPS = lowerGPS, abs(lowerGPS.time - targetTime) < 0.001 {
            return lowerGPS
        }

        // If we have both lower and upper bounds, interpolate
        if let lowerGPS = lowerGPS, let upperGPS = upperGPS, lowerIndex >= 0,
            upperIndex >= 0
        {
            // Prevent division by zero
            let timeDiff = upperGPS.time - lowerGPS.time
            if abs(timeDiff) < 0.000001 {  // Small epsilon to check for near-zero values
                return lowerGPS  // Return lower bound if times are too close
            }
            let ratio = (targetTime - lowerGPS.time) / timeDiff

            let interpolatedGPS = GPSNodeWrapper()
            interpolatedGPS.time = targetTime
            interpolatedGPS.latitude =
                lowerGPS.latitude + (upperGPS.latitude - lowerGPS.latitude)
                * ratio
            interpolatedGPS.longitude =
                lowerGPS.longitude + (upperGPS.longitude - lowerGPS.longitude)
                * ratio
            interpolatedGPS.speed =
                lowerGPS.speed + (upperGPS.speed - lowerGPS.speed) * ratio

            return interpolatedGPS
        }

        // If we only have lower bound, use it (extrapolation)
        if let lowerGPS = lowerGPS {
            return lowerGPS
        }

        // If we only have upper bound, use it (extrapolation)
        if let upperGPS = upperGPS {
            return upperGPS
        }

        return nil
    }

    private func interpolate(
        accelGyroData: [NodeWrapper],
        gpsData: [GPSNodeWrapper],
        startTime: String
    ) -> String {
        var gyroArray: [NodeWrapper] = []
        var accelArray: [NodeWrapper] = []

        for nw in accelGyroData {
            if nw.time <= 0 {
                continue
            }
            if nw.isGyro {
                gyroArray.append(nw)
            } else {
                accelArray.append(nw)
            }
        }

        let sortedArrayGyro = gyroArray.sorted {
            $0.compare($1) == .orderedAscending
        }
        let sortedArrayAccel = accelArray.sorted {
            $0.compare($1) == .orderedAscending
        }

        let mutableGyroCopy = removeDuplicates(sortedArrayGyro)
        let mutableAccelCopy = removeDuplicates(sortedArrayAccel)

        // Sort GPS data by time
        let sortedGPSArray = gpsData.sorted {
            $0.compare($1) == .orderedAscending
        }

        print(
            "Interpolating data: \(mutableGyroCopy.count) gyro samples, \(mutableAccelCopy.count) accel samples, \(sortedGPSArray.count) GPS samples"
        )

        // interpolate
        var mainString = ""
        var accelIndex = 0
        var gpsIndex = 0
        // mainString +=
        //     "datetime, gyroX, gyroY, gyroZ, accX, accY, accZ, lat, lon, speed\n" with lat, lon
        mainString +=
            "datetime,gyroX,gyroY,gyroZ,accX,accY,accZ,speed\n"
        // Check if arrays are empty to avoid out of bounds access
        guard !mutableGyroCopy.isEmpty && !mutableAccelCopy.isEmpty else {
            return mainString
        }

        for gyroIndex in 0..<mutableGyroCopy.count {
            let nwg = mutableGyroCopy[gyroIndex]

            // Make sure accelIndex is within bounds
            guard accelIndex < mutableAccelCopy.count else {
                break
            }

            let nwa = mutableAccelCopy[accelIndex]

            // Find GPS data for this timestamp with interpolation
            let nwGPS = interpolateGPSData(
                atTime: nwg.time,
                fromArray: sortedGPSArray,
                currentIndex: &gpsIndex
            )

            if nwg.time < nwa.time {
                continue
            } else if nwg.time == nwa.time {
                if let nwGPS = nwGPS {
                    mainString += String(
                        format:
                            "%@,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f\n",
                        secDoubleToDateTimeString(nwg.time),
                        nwg.x,
                        nwg.y,
                        nwg.z,
                        nwa.x,
                        nwa.y,
                        nwa.z,
                    //    nwGPS.latitude,
                    //    nwGPS.longitude,
                        nwGPS.speed
                    )
                } else {
                    mainString += String(
                        format:
                            "%@,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f\n",
                        secDoubleToDateTimeString(nwg.time),
                        nwg.x,
                        nwg.y,
                        nwg.z,
                        nwa.x,
                        nwa.y,
                        nwa.z,
                        // 0.0,
                        // 0.0,
                        0.0
                    )
                }
            } else {
                var lowerIndex = accelIndex
                var upperIndex = accelIndex + 1

                for iterIndex in (accelIndex + 1)..<mutableAccelCopy.count {
                    let nwa1 = mutableAccelCopy[iterIndex]
                    if nwa1.time < nwg.time {
                        lowerIndex = iterIndex
                    } else if nwa1.time > nwg.time {
                        upperIndex = iterIndex
                        break
                    } else {
                        lowerIndex = iterIndex
                        upperIndex = iterIndex
                        break
                    }
                }

                // Make sure upperIndex is valid
                guard upperIndex < mutableAccelCopy.count else {
                    break
                }

                if upperIndex == lowerIndex {
                    let nwa1 = mutableAccelCopy[upperIndex]
                    if let nwGPS = nwGPS {
                        mainString += String(
                            format:
                                "%@,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f\n",
                            secDoubleToDateTimeString(nwg.time),
                            nwg.x,
                            nwg.y,
                            nwg.z,
                            nwa1.x,
                            nwa1.y,
                            nwa1.z,
                            // nwGPS.latitude,
                            // nwGPS.longitude,
                            nwGPS.speed
                        )
                    } else {
                        mainString += String(
                            format:
                                "%@,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f\n",
                            secDoubleToDateTimeString(nwg.time),
                            nwg.x,
                            nwg.y,
                            nwg.z,
                            nwa1.x,
                            nwa1.y,
                            nwa1.z,
                            // 0.0,
                            // 0.0,
                            0.0
                        )
                    }
                } else if upperIndex == lowerIndex + 1 {
                    // Make sure both indices are valid
                    guard
                        lowerIndex >= 0 && lowerIndex < mutableAccelCopy.count
                            && upperIndex >= 0
                            && upperIndex < mutableAccelCopy.count
                    else {
                        break
                    }

                    let nwa = mutableAccelCopy[lowerIndex]
                    let nwa1 = mutableAccelCopy[upperIndex]

                    // Prevent division by zero
                    let timeDiff = nwa1.time - nwa.time
                    if abs(timeDiff) < 0.000001 {  // Small epsilon to check for near-zero values
                        continue
                    }

                    let ratio = (nwg.time - nwa.time) / timeDiff
                    let interpax = nwa.x + (nwa1.x - nwa.x) * ratio
                    let interpay = nwa.y + (nwa1.y - nwa.y) * ratio
                    let interpaz = nwa.z + (nwa1.z - nwa.z) * ratio

                    if let nwGPS = nwGPS {
                        mainString += String(
                            format:
                                "%@,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f\n",
                            secDoubleToDateTimeString(nwg.time),
                            nwg.x,
                            nwg.y,
                            nwg.z,
                            interpax,
                            interpay,
                            interpaz,
                            // nwGPS.latitude,
                            // nwGPS.longitude,
                            nwGPS.speed
                        )
                    } else {
                        mainString += String(
                            format:
                                "%@,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f,%.15f\n",
                            secDoubleToDateTimeString(nwg.time),
                            nwg.x,
                            nwg.y,
                            nwg.z,
                            interpax,
                            interpay,
                            interpaz,
                            // 0.0,
                            // 0.0,
                            0.0
                        )
                    }
                } else {
                    print(
                        "Impossible lower and upper bound \(lowerIndex) \(upperIndex) for gyro timestamp \(String(format: "%.5f", nwg.time))"
                    )
                }
                accelIndex = lowerIndex
            }
        }

        return mainString
    }

    // MARK: - Recording Control

    func switchRecording() {
        if isRecording {
            isRecording = false
            // Don't stop motion updates - they're needed for visualization
            // motionManager.stopGyroUpdates()
            // motionManager.stopAccelerometerUpdates()
            // Don't stop GPS location updates - keep running for HUD speed display
            // locationManager.stopUpdatingLocation()

            // Don't reset currentSpeed - keep last known speed for HUD display
            // currentSpeed = 0.0

            var mainString = ""

            if !interpolateAccel {
                mainString +=
                    "Timestamp[nanosec], x, y, z[(a:m/s^2)/(g:rad/s)], isGyro?\n"
                if let rawData = rawAccelGyroData {
                    for nw in rawData {
                        mainString += String(
                            format: "%.7f,%.5f,%.5f,%.5f,%d\n",
                            nw.time,
                            nw.x,
                            nw.y,
                            nw.z,
                            nw.isGyro ? 1 : 0
                        )
                    }
                }
            } else {
                // linearly interpolate acceleration offline
                if let rawAccelGyro = rawAccelGyroData, let rawGPS = rawGPSData,
                    let startTime = timeStartImu
                {
                    mainString = interpolate(
                        accelGyroData: rawAccelGyro,
                        gpsData: rawGPS,
                        startTime: startTime
                    )
                }
            }

            // Release arrays
            rawAccelGyroData = nil
            rawGPSData = nil

            if let fileURL = fileURL {
                do {
                    try mainString.write(
                        to: fileURL,
                        atomically: true,
                        encoding: .utf8
                    )
                    print("Written inertial data to \(fileURL)")
                } catch {
                    print("Failed to record inertial data at \(fileURL)")
                }
            }

            print("Stopped recording inertial data!")
            // Motion updates continue running for visualization
        } else {
            isRecording = true
            print("Start recording inertial data!")
            rawAccelGyroData = []
            rawGPSData = []
            // Don't reset currentSpeed - keep the last known speed for HUD display
            motionManager.gyroUpdateInterval = 1.0 / RATE
            motionManager.accelerometerUpdateInterval = 1.0 / RATE

            // Store boot time reference for GPS synchronization
            bootTimeReference =
                Date().timeIntervalSince1970
                - ProcessInfo.processInfo.systemUptime
            gpsUpdateCount = 0
            lastGPSUpdateTime = 0
            print(
                "Boot time reference: \(String(format: "%.6f", bootTimeReference))"
            )

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "EEE_MM_dd_yyyy_HH_mm_ss"
            timeStartImu = dateFormatter.string(from: Date())

            if motionManager.isGyroAvailable
                && motionManager.isAccelerometerAvailable
            {
                queue = OperationQueue()
                queue?.name = "com.apple.sample.inertialRecorder.motion"
                queue?.qualityOfService = .userInitiated
                queue?.maxConcurrentOperationCount = 1

                motionManager.startGyroUpdates(to: queue!) {
                    [weak self] (gyroData, error) in
                    guard let self = self, let gyroData = gyroData else {
                        return
                    }

                    let rotate = gyroData.rotationRate
                    let nw = NodeWrapper()
                    nw.isGyro = true
                    nw.time = gyroData.timestamp
                    nw.x = rotate.x
                    nw.y = rotate.y
                    nw.z = rotate.z
                    self.rawAccelGyroData?.append(nw)
                    
                    // Feed visualization buffer
                    self.gyroVisualizationBuffer.append(
                        timestamp: gyroData.timestamp,
                        x: rotate.x,
                        y: rotate.y,
                        z: rotate.z
                    )
                }

                motionManager.startAccelerometerUpdates(to: queue!) {
                    [weak self] (accelData, error) in
                    guard let self = self, let accelData = accelData else {
                        return
                    }

                    let accel = accelData.acceleration
                    let nw = NodeWrapper()
                    nw.isGyro = false
                    // The time stamp is the amount of time in seconds since the device booted.
                    nw.time = accelData.timestamp
                    // nw.x = -accel.x * GRAVITY
                    // nw.y = -accel.y * GRAVITY
                    // nw.z = -accel.z * GRAVITY
                    nw.x = -accel.x 
                    nw.y = -accel.y
                    nw.z = -accel.z

                    self.rawAccelGyroData?.append(nw)
                    
                    // Feed visualization buffer
                    self.accelVisualizationBuffer.append(
                        timestamp: accelData.timestamp,
                        x: -accel.x,
                        y: -accel.y,
                        z: -accel.z
                    )
                }
            } else {
                print("Gyroscope or accelerometer not available")
            }

            // GPS location updates are already started in init() for HUD display
            // Ensure it's running (startGPSUpdates handles duplicates)
            startGPSUpdates()
        }
    }
    
    // MARK: - GPS Updates
    
    private func startGPSUpdates() {
        // Start GPS location updates with maximum frequency for HUD speed display
        // Check authorization status on background queue to avoid main thread warning
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            if CLLocationManager.locationServicesEnabled() {
                let status = self.locationManager.authorizationStatus
                
                DispatchQueue.main.async {
                    switch status {
                    case .notDetermined:
                        self.gpsStatus = "Requesting permission..."
                        self.locationManager.requestWhenInUseAuthorization()
                    case .authorizedWhenInUse:
                        self.gpsStatus = "Authorized (When In Use)"
                        // Request "Always" authorization for maximum update frequency
                        self.locationManager.requestAlwaysAuthorization()
                        self.locationManager.startUpdatingLocation()
                        print("Started GPS location updates with maximum frequency settings")
                    case .authorizedAlways:
                        self.gpsStatus = "Authorized (Always)"
                        self.locationManager.startUpdatingLocation()
                        print("Started GPS location updates with maximum frequency settings")
                    case .denied:
                        self.gpsStatus = "Denied"
                        print("Location services not authorized")
                    case .restricted:
                        self.gpsStatus = "Restricted"
                        print("Location services restricted")
                    @unknown default:
                        self.gpsStatus = "Unknown"
                    }
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.gpsStatus = "Disabled"
                }
                print("Location services not enabled")
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last,
            location.coordinate.latitude != 0,
            location.coordinate.longitude != 0
        else {
            DispatchQueue.main.async { [weak self] in
                self?.gpsStatus = "Waiting for fix..."
            }
            return
        }

        // Update GPS status and coordinates for UI display
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.gpsLatitude = location.coordinate.latitude
            self.gpsLongitude = location.coordinate.longitude
            self.gpsHorizontalAccuracy = location.horizontalAccuracy
            self.gpsUpdateCount += 1
            self.lastGPSUpdateTimestamp = Date()
            
            // Format status with accuracy info
            let accuracyStr = location.horizontalAccuracy >= 0 ? String(format: "%.1fm", location.horizontalAccuracy) : "N/A"
            self.gpsStatus = "Active (\(self.gpsUpdateCount) updates, ±\(accuracyStr))"
        }

        // Always update current speed for HUD display, even when not recording
        let speed = location.speed >= 0 ? location.speed : 0.0  // Handle negative speed values
        currentSpeed = speed
        
        // Use a local variable for logging since gpsUpdateCount is updated asynchronously
        let updateCount = gpsUpdateCount
        let accuracy = location.horizontalAccuracy >= 0 ? String(format: "±%.1fm", location.horizontalAccuracy) : "N/A"
        print("GPS Update #\(updateCount): lat=\(String(format: "%.6f", location.coordinate.latitude)), lon=\(String(format: "%.6f", location.coordinate.longitude)), speed=\(String(format: "%.2f", speed)) m/s (\(String(format: "%.1f", speed * 3.6)) km/h), accuracy=\(accuracy), isRecording=\(isRecording)")

        // Only append GPS data to recording buffer when actually recording
        guard isRecording else { return }

        let gpsNode = GPSNodeWrapper()
        // Use the same time reference as inertial data (time since device boot)
        // Convert from absolute time to time since boot using stored reference
        gpsNode.time =
            location.timestamp.timeIntervalSince1970 - bootTimeReference
        gpsNode.latitude = location.coordinate.latitude
        gpsNode.longitude = location.coordinate.longitude
        gpsNode.speed = speed

        rawGPSData?.append(gpsNode)
        // gpsUpdateCount is already incremented in the main thread block above

        // Log GPS update frequency every 10 updates
        if gpsUpdateCount % 10 == 0 {
            let timeSinceLastUpdate =
                lastGPSUpdateTime > 0 ? gpsNode.time - lastGPSUpdateTime : 0
            let gpsFrequency =
                lastGPSUpdateTime > 0 ? 1.0 / timeSinceLastUpdate : 0
            print(
                "GPS Update #\(gpsUpdateCount): lat=\(String(format: "%.15f", gpsNode.latitude)), lon=\(String(format: "%.15f", gpsNode.longitude)), speed=\(String(format: "%.15f", gpsNode.speed)), time=\(String(format: "%.6f", gpsNode.time)), freq=\(String(format: "%.1f", gpsFrequency)) Hz"
            )
        } else {
            print(
                "GPS: lat=\(String(format: "%.15f", gpsNode.latitude)), lon=\(String(format: "%.15f", gpsNode.longitude)), speed=\(String(format: "%.15f", gpsNode.speed)), time=\(String(format: "%.6f", gpsNode.time))"
            )
        }

        lastGPSUpdateTime = gpsNode.time
    }

    func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            // Start GPS updates regardless of recording state (for HUD speed display)
            startGPSUpdates()
            print("GPS authorization granted, starting location updates")
        case .denied, .restricted:
            print("GPS location access denied or restricted")
            currentSpeed = 0.0
        case .notDetermined:
            print("GPS location authorization not determined")
        @unknown default:
            break
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        print(
            "GPS location manager failed with error: \(error.localizedDescription)"
        )
    }
}
