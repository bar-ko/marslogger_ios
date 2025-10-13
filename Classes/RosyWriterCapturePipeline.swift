/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample's licensing information
 
 Abstract:
 The class that creates and manages the AVCaptureSession
 */

import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import Photos
import UIKit
import CoreLocation

// MARK: - Constants

let RETAINED_BUFFER_COUNT = 6
let RECORD_AUDIO = false
private let LOG_CAPTURE_PIPELINE_STATUS_TRANSITIONS = false

let VIDEO_META_FILENAME = "movie_metadata.csv"
let IMU_OUTPUT_FILENAME = "gyro_accel.csv"

// MARK: - Recording Status Enum

enum RosyWriterRecordingStatus: Int {
    case idle = 0
    case startingRecording
    case recording
    case stoppingRecording
}

// MARK: - RosyWriterCapturePipeline

class RosyWriterCapturePipeline: NSObject {
    
    // MARK: - Public Properties
    
    var renderingEnabled: Bool {
        get {
            objc_sync_enter(renderer)
            defer { objc_sync_exit(renderer) }
            return _renderingEnabled
        }
        set {
            objc_sync_enter(renderer)
            defer { objc_sync_exit(renderer) }
            _renderingEnabled = newValue
        }
    }
    
    var recordingOrientation: AVCaptureVideoOrientation = .portrait
    private(set) var videoFrameRate: Float = 0.0
    private(set) var fx: Float = 0.0
    private(set) var videoDimensions: CMVideoDimensions = CMVideoDimensions(width: 0, height: 0)
    private(set) var exposureDuration: Int64 = 0
    private(set) var autoLocked: Bool = false
    private(set) var videoDeviceInput: AVCaptureDeviceInput!
    private(set) var metadataFileURL: URL!
    
    // MARK: - Private Properties
    
    private var previousSecondTimestamps: [NSValue] = []
    private var captureSession: AVCaptureSession?
    private var videoDevice: AVCaptureDevice?
    private var audioConnection: AVCaptureConnection?
    private var videoConnection: AVCaptureConnection?
    private var videoBufferOrientation: AVCaptureVideoOrientation = .portrait
    private var running = false
    private var startCaptureSessionOnEnteringForeground = false
    private var applicationWillEnterForegroundNotificationObserver: Any?
    private var videoCompressionSettings: [String: Any]?
    private var audioCompressionSettings: [String: Any]?
    
    private let sessionQueue: DispatchQueue
    private let videoDataOutputQueue: DispatchQueue
    
    private var renderer: RosyWriterRenderer
    private var _renderingEnabled = false
    
    private var recorder: MovieRecorder?
    private let recordingURL: URL
    private var recordingStatus: RosyWriterRecordingStatus = .idle
    
    private var pipelineRunningTask: UIBackgroundTaskIdentifier = .invalid
    
    private weak var delegate: RosyWriterCapturePipelineDelegate?
    private let delegateCallbackQueue: DispatchQueue
    
    private var adjustExpFinishTime: CMTime = CMTimeMake(value: 0, timescale: 1)
    private var inertialRecorder: InertialRecorder
    private var adjustExposureFinished = true
    
    private var currentPreviewPixelBuffer: CVPixelBuffer?
    private var outputVideoFormatDescription: CMFormatDescription?
    private var outputAudioFormatDescription: CMFormatDescription?
    
    private let videoTimeConverter: VideoTimeConverter
    
    // MARK: - Initialization
    
    init(delegate: RosyWriterCapturePipelineDelegate, callbackQueue: DispatchQueue) {
        self.delegate = delegate
        self.delegateCallbackQueue = callbackQueue
        
        self.sessionQueue = DispatchQueue(label: "com.apple.sample.capturepipeline.session")
        self.videoDataOutputQueue = DispatchQueue(label: "com.apple.sample.capturepipeline.video", qos: .userInitiated)
        
        // Initialize renderer (using CPU renderer as default)
        self.renderer = RosyWriterCPURenderer()
        
        self.recordingURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Movie.MP4")
        
        self.inertialRecorder = InertialRecorder()
        self.videoTimeConverter = VideoTimeConverter()
        
        super.init()
    }
    
    deinit {
        teardownCaptureSession()
    }
    
    // MARK: - Public Methods
    
    func startRunning() {
        sessionQueue.sync {
            self.setupCaptureSession()
            
            if let captureSession = self.captureSession {
                captureSession.startRunning()
                self.running = true
            }
        }
    }
    
    func stopRunning() {
        sessionQueue.sync {
            self.running = false
            
            self.stopRecording()
            
            self.captureSession?.stopRunning()
            
            self.captureSessionDidStopRunning()
            
            self.teardownCaptureSession()
        }
    }
    
    func startRecording() {
        resetOutputFolder()
        
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        
        guard recordingStatus == .idle else {
            fatalError("Already recording")
        }
        
        transition(toRecordingStatus: .startingRecording, error: nil)
        
        inertialRecorder.switchRecording()
        
        let callbackQueue = DispatchQueue(label: "com.apple.sample.capturepipeline.recordercallback")
        let recorder = MovieRecorder(url: recordingURL, delegate: self, callbackQueue: callbackQueue)
        
        if RECORD_AUDIO, let outputAudioFormatDescription = outputAudioFormatDescription, let audioCompressionSettings = audioCompressionSettings {
            recorder.addAudioTrack(withSourceFormatDescription: outputAudioFormatDescription, settings: audioCompressionSettings)
        }
        
        let videoTransform = transform(fromVideoBufferOrientationTo: recordingOrientation, withAutoMirroring: false)
        
        if let outputVideoFormatDescription = outputVideoFormatDescription, let videoCompressionSettings = videoCompressionSettings {
            recorder.addVideoTrack(withSourceFormatDescription: outputVideoFormatDescription, transform: videoTransform, settings: videoCompressionSettings)
        }
        
        self.recorder = recorder
        recorder.prepareToRecord()
    }
    
    func stopRecording() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        
        guard recordingStatus == .recording else {
            return
        }
        
        transition(toRecordingStatus: .stoppingRecording, error: nil)
        
        inertialRecorder.switchRecording()
        recorder?.finishRecording()
    }
    
    func reportLensFocalLenParams() -> Float {
        guard let device = videoDevice else { return 0.0 }
        
        let lensPos = device.lensPosition
        let videoZoom = device.videoZoomFactor
        var videoHFov = device.activeFormat.videoFieldOfView
        videoHFov *= .pi / 180.0
        let w = videoDimensions.width
        let focalLen = Float(w) / 2.0 / tan(videoHFov / 2.0)
        
        print("lensPos \(String(format: "%.4f", lensPos)) videoZoom \(videoZoom) HFOV \(String(format: "%.4f", videoHFov)) w \(w) focalLen \(String(format: "%.4f", focalLen))")
        
        return focalLen
    }
    
    func focus(at point: CGPoint) {
        guard let device = videoDevice else { return }
        
        var autoFocusLocked = false
        
        if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
                device.unlockForConfiguration()
                print("Camera focused at \(String(format: "%.3f, %.3f", point.x, point.y))")
                autoFocusLocked = true
            } catch {
                print("Camera error in locking autofocus: \(error)")
            }
        }
        
        if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
            let format = device.activeFormat
            let oldDuration = device.exposureDuration
            let oldISO = device.iso
            var expectedDuration = oldDuration
            var expectedISO = oldISO
            
            computeExpectedExposureTimeAndIso(format: format, oldDuration: oldDuration, oldISO: oldISO, expectedDuration: &expectedDuration, expectedISO: &expectedISO)
            
            do {
                try device.lockForConfiguration()
                
                adjustExposureFinished = false
                device.setExposureModeCustom(duration: expectedDuration, iso: expectedISO) { [weak self] syncTime in
                    self?.adjustExpFinishTime = syncTime
                    self?.exposureDuration = CMTimeGetNanoseconds(device.exposureDuration)
                    self?.adjustExposureFinished = true
                }
                
                device.unlockForConfiguration()
                autoLocked = autoFocusLocked
            } catch {
                print("Camera error in locking autoexposure: \(error)")
                autoLocked = false
            }
        }
    }
    
    func unlockFocusAndExposure() {
        guard let device = videoDevice else { return }
        
        var autoFocusEnabled = false
        
        if device.isFocusModeSupported(.continuousAutoFocus) {
            do {
                try device.lockForConfiguration()
                device.focusMode = .continuousAutoFocus
                device.unlockForConfiguration()
                autoFocusEnabled = true
                print("Camera auto focus enabled")
            } catch {
                print("Camera error in lockForConfiguration for focus: \(error)")
            }
        }
        
        if device.isExposureModeSupported(.continuousAutoExposure) {
            do {
                try device.lockForConfiguration()
                device.exposureMode = .continuousAutoExposure
                device.unlockForConfiguration()
                autoLocked = !autoFocusEnabled
                print("Camera auto exposure enabled")
            } catch {
                print("Camera error in lockForConfiguration for exposure: \(error)")
            }
        }
    }
    
    func getInertialFileURL() -> URL? {
        return inertialRecorder.fileURL
    }
    
    func getCurrentSpeed() -> CLLocationSpeed {
        return inertialRecorder.currentSpeed
    }
    
    func transform(fromVideoBufferOrientationTo orientation: AVCaptureVideoOrientation, withAutoMirroring mirror: Bool) -> CGAffineTransform {
        var transform = CGAffineTransform.identity
        
        let orientationAngleOffset = angleOffset(fromPortraitOrientationTo: orientation)
        let videoOrientationAngleOffset = angleOffset(fromPortraitOrientationTo: videoBufferOrientation)
        
        let angleOffset = orientationAngleOffset - videoOrientationAngleOffset
        transform = CGAffineTransform(rotationAngle: angleOffset)
        
        if videoDevice?.position == .front {
            if mirror {
                transform = transform.scaledBy(x: -1, y: 1)
            } else {
                if orientation == .portrait || orientation == .portraitUpsideDown {
                    transform = transform.rotated(by: .pi)
                }
            }
        }
        
        return transform
    }
    
    // MARK: - Private Methods
    
    private func frontCamera() -> AVCaptureDevice? {
        let devices = AVCaptureDevice.devices(for: .video)
        for device in devices {
            if device.position == .front {
                return device
            }
        }
        return nil
    }
    
    private func rearCamera() -> AVCaptureDevice? {
        return AVCaptureDevice.default(for: .video)
    }
    
    private func setupCaptureSession() {
        guard captureSession == nil else { return }
        
        let captureSession = AVCaptureSession()
        self.captureSession = captureSession
        
        NotificationCenter.default.addObserver(self, selector: #selector(captureSessionNotification(_:)), name: nil, object: captureSession)
        
        applicationWillEnterForegroundNotificationObserver = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: UIApplication.shared, queue: nil) { [weak self] _ in
            self?.applicationWillEnterForeground()
        }
        
        // Video setup
        guard let videoDevice = rearCamera() else { return }
        
        do {
            let videoIn = try AVCaptureDeviceInput(device: videoDevice)
            if captureSession.canAddInput(videoIn) {
                captureSession.addInput(videoIn)
                self.videoDevice = videoDevice
                self.videoDeviceInput = videoIn
            }
        } catch {
            handleNonRecoverableCaptureSessionRuntimeError(error)
            return
        }
        
        let videoOut = AVCaptureVideoDataOutput()
        videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: renderer.inputPixelFormat]
        videoOut.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        videoOut.alwaysDiscardsLateVideoFrames = false
        
        if captureSession.canAddOutput(videoOut) {
            captureSession.addOutput(videoOut)
        }
        
        videoConnection = videoOut.connection(with: .video)
        
        if #available(iOS 11.0, *) {
            if let videoConnection = videoConnection, videoConnection.isCameraIntrinsicMatrixDeliverySupported {
                print("camera intrinsic mat delivery supported")
                videoConnection.isCameraIntrinsicMatrixDeliveryEnabled = true
                if videoConnection.isCameraIntrinsicMatrixDeliveryEnabled {
                    print("camera intrinsic mat delivery enabled")
                } else {
                    print("camera intrinsic mat delivery NOT enabled")
                }
            } else {
                print("camera intrinsic mat delivery NOT supported")
            }
        }
        
        let frameRate: Int32
        var sessionPreset = AVCaptureSession.Preset.high
        
        if ProcessInfo.processInfo.processorCount == 1 {
            if captureSession.canSetSessionPreset(.vga640x480) {
                sessionPreset = .vga640x480
            }
            frameRate = 15
        } else {
            if captureSession.canSetSessionPreset(.hd1280x720) {
                sessionPreset = .hd1280x720
            }
            frameRate = 30
        }
        
        captureSession.sessionPreset = sessionPreset
        
        let frameDuration = CMTimeMake(value: 1, timescale: frameRate)
        
        do {
            try videoDevice.lockForConfiguration()
            videoDevice.activeVideoMaxFrameDuration = frameDuration
            videoDevice.activeVideoMinFrameDuration = frameDuration
            videoDevice.unlockForConfiguration()
        } catch {
            print("videoDevice lockForConfiguration returned error \(error)")
        }
        
        videoCompressionSettings = videoOut.recommendedVideoSettingsForAssetWriter(writingTo: .mp4)
        
        if let videoConnection = videoConnection {
            videoBufferOrientation = videoConnection.videoOrientation
            let cropFactor = videoConnection.videoScaleAndCropFactor
            print("Video scale and crop factor \(cropFactor)")
        }
    }
    
    private func teardownCaptureSession() {
        guard let captureSession = captureSession else { return }
        
        NotificationCenter.default.removeObserver(self, name: nil, object: captureSession)
        
        if let observer = applicationWillEnterForegroundNotificationObserver {
            NotificationCenter.default.removeObserver(observer)
            applicationWillEnterForegroundNotificationObserver = nil
        }
        
        self.captureSession = nil
        self.videoCompressionSettings = nil
        self.audioCompressionSettings = nil
    }
    
    @objc private func captureSessionNotification(_ notification: Notification) {
        sessionQueue.async {
            if notification.name == .AVCaptureSessionWasInterrupted {
                print("session interrupted")
                self.captureSessionDidStopRunning()
            } else if notification.name == .AVCaptureSessionInterruptionEnded {
                print("session interruption ended")
            } else if notification.name == .AVCaptureSessionRuntimeError {
                self.captureSessionDidStopRunning()
                
                if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError {
                    if error.code == AVError.deviceIsNotAvailableInBackground.rawValue {
                        print("device not available in background")
                        if self.running {
                            self.startCaptureSessionOnEnteringForeground = true
                        }
                    } else if error.code == AVError.mediaServicesWereReset.rawValue {
                        print("media services were reset")
                        self.handleRecoverableCaptureSessionRuntimeError(error)
                    } else {
                        self.handleNonRecoverableCaptureSessionRuntimeError(error)
                    }
                }
            } else if notification.name == .AVCaptureSessionDidStartRunning {
                print("session started running")
            } else if notification.name == .AVCaptureSessionDidStopRunning {
                print("session stopped running")
            }
        }
    }
    
    private func handleRecoverableCaptureSessionRuntimeError(_ error: Error) {
        if running {
            captureSession?.startRunning()
        }
    }
    
    private func handleNonRecoverableCaptureSessionRuntimeError(_ error: Error) {
        print("fatal runtime error \(error)")
        
        running = false
        teardownCaptureSession()
        
        invokeDelegateCallbackAsync {
            self.delegate?.capturePipeline(self, didStopRunningWithError: error)
        }
    }
    
    private func captureSessionDidStopRunning() {
        stopRecording()
        teardownVideoPipeline()
    }
    
    private func applicationWillEnterForeground() {
        print("-[\(type(of: self)) \(#function)] called")
        
        sessionQueue.sync {
            if self.startCaptureSessionOnEnteringForeground {
                print("-[\(type(of: self)) \(#function)] manually restarting session")
                
                self.startCaptureSessionOnEnteringForeground = false
                if self.running {
                    self.captureSession?.startRunning()
                }
            }
        }
    }
    
    private func setupVideoPipeline(withInputFormatDescription inputFormatDescription: CMFormatDescription) {
        print("-[\(type(of: self)) \(#function)] called")
        
        videoPipelineWillStartRunning()
        
        if let sampleBufferClock = captureSession?.masterClock {
            videoTimeConverter.sampleBufferClock = sampleBufferClock
        }
        
        videoTimeConverter.checkStatus()
        
        videoDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
        fx = reportLensFocalLenParams()
        renderer.prepareForInput(withFormatDescription: inputFormatDescription, outputRetainedBufferCountHint: RETAINED_BUFFER_COUNT)
        
        if !renderer.operatesInPlace, let outputDesc = renderer.outputFormatDescription {
            outputVideoFormatDescription = outputDesc
        } else {
            outputVideoFormatDescription = inputFormatDescription
        }
    }
    
    private func teardownVideoPipeline() {
        print("-[\(type(of: self)) \(#function)] called")
        
        videoDataOutputQueue.sync {
            guard self.outputVideoFormatDescription != nil else { return }
            
            self.outputVideoFormatDescription = nil
            self.renderer.reset()
            self.currentPreviewPixelBuffer = nil
            
            print("-[\(type(of: self)) \(#function)] finished teardown")
            
            self.videoPipelineDidFinishRunning()
        }
    }
    
    private func videoPipelineWillStartRunning() {
        print("-[\(type(of: self)) \(#function)] called")
        
        assert(pipelineRunningTask == .invalid, "should not have a background task active before the video pipeline starts running")
        
        pipelineRunningTask = UIApplication.shared.beginBackgroundTask {
            print("video capture pipeline background task expired")
        }
    }
    
    private func videoPipelineDidFinishRunning() {
        print("-[\(type(of: self)) \(#function)] called")
        
        assert(pipelineRunningTask != .invalid, "should have a background task active when the video pipeline finishes running")
        
        UIApplication.shared.endBackgroundTask(pipelineRunningTask)
        pipelineRunningTask = .invalid
    }
    
    private func videoPipelineDidRunOutOfBuffers() {
        invokeDelegateCallbackAsync {
            self.delegate?.capturePipelineDidRunOutOfPreviewBuffers(self)
        }
    }
    
    private func renderVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var renderedPixelBuffer: CVPixelBuffer?
        
        videoTimeConverter.convertSampleBufferTimeToMotionClock(sampleBuffer)
        let timestamp = getAttachmentTime(sampleBuffer)
        
        var array: [NSNumber] = []
        
        if #available(iOS 11.0, *) {
            if let intrinsicMatEncoded = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) as? Data {
                let count = intrinsicMatEncoded.count / MemoryLayout<Float>.size
                array = Array(repeating: 0, count: count)
                
                intrinsicMatEncoded.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                    let floatPtr = ptr.bindMemory(to: Float.self)
                    for i in 0..<count {
                        array[i] = NSNumber(value: floatPtr[i])
                    }
                }
                
                if array.count > 0 {
                    fx = array[0].floatValue
                }
            }
        } else {
            array = Array(repeating: 0, count: 12)
            array[0] = NSNumber(value: fx)
            array[5] = NSNumber(value: fx)
            array[8] = NSNumber(value: Float(videoDimensions.width) / 2.0 - 0.5)
            array[9] = NSNumber(value: Float(videoDimensions.height) / 2.0 - 0.5)
            array[11] = 1.0
        }
        
        if let videoDevice = videoDevice {
            exposureDuration = CMTimeGetNanoseconds(videoDevice.exposureDuration)
        }
        
        calculateFramerate(atTimestamp: timestamp)
        
        guard adjustExposureFinished else { return }
        
        objc_sync_enter(renderer)
        defer { objc_sync_exit(renderer) }
        
        if _renderingEnabled {
            if let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                renderedPixelBuffer = renderer.copyRenderedPixelBuffer(sourcePixelBuffer)
            }
        } else {
            return
        }
        
        if let renderedPixelBuffer = renderedPixelBuffer {
            objc_sync_enter(self)
            
            outputPreviewPixelBuffer(renderedPixelBuffer)
            
            if recordingStatus == .recording {
                recorder?.appendVideoPixelBuffer(renderedPixelBuffer, withPresentationTime: timestamp, withIntrinsicMat: array, withExposureDuration: exposureDuration)
            }
            
            objc_sync_exit(self)
        } else {
            videoPipelineDidRunOutOfBuffers()
        }
    }
    
    private func outputPreviewPixelBuffer(_ previewPixelBuffer: CVPixelBuffer) {
        currentPreviewPixelBuffer = previewPixelBuffer
        
        invokeDelegateCallbackAsync {
            var currentPreviewPixelBuffer: CVPixelBuffer?
            
            objc_sync_enter(self)
            currentPreviewPixelBuffer = self.currentPreviewPixelBuffer
            self.currentPreviewPixelBuffer = nil
            objc_sync_exit(self)
            
            if let currentPreviewPixelBuffer = currentPreviewPixelBuffer {
                self.delegate?.capturePipeline(self, previewPixelBufferReadyForDisplay: currentPreviewPixelBuffer)
            }
        }
    }
    
    private func transition(toRecordingStatus newStatus: RosyWriterRecordingStatus, error: Error?) {
        let oldStatus = recordingStatus
        recordingStatus = newStatus
        
        if LOG_CAPTURE_PIPELINE_STATUS_TRANSITIONS {
            print("RosyWriterCapturePipeline recording state transition: \(oldStatus)->\(newStatus)")
        }
        
        if newStatus != oldStatus {
            var delegateCallbackBlock: (() -> Void)?
            
            if let error = error, newStatus == .idle {
                delegateCallbackBlock = { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.capturePipeline(self, recordingDidFailWithError: error)
                }
            } else {
                if oldStatus == .startingRecording && newStatus == .recording {
                    delegateCallbackBlock = { [weak self] in
                        guard let self = self else { return }
                        self.delegate?.capturePipelineRecordingDidStart(self)
                    }
                } else if oldStatus == .recording && newStatus == .stoppingRecording {
                    delegateCallbackBlock = { [weak self] in
                        guard let self = self else { return }
                        self.delegate?.capturePipelineRecordingWillStop(self)
                    }
                } else if oldStatus == .stoppingRecording && newStatus == .idle {
                    delegateCallbackBlock = { [weak self] in
                        guard let self = self else { return }
                        self.delegate?.capturePipelineRecordingDidStop(self)
                    }
                }
            }
            
            if let delegateCallbackBlock = delegateCallbackBlock {
                invokeDelegateCallbackAsync(delegateCallbackBlock)
            }
        }
    }
    
    private func invokeDelegateCallbackAsync(_ callbackBlock: @escaping () -> Void) {
        delegateCallbackQueue.async {
            autoreleasepool {
                callbackBlock()
            }
        }
    }
    
    private func angleOffset(fromPortraitOrientationTo orientation: AVCaptureVideoOrientation) -> CGFloat {
        var angle: CGFloat = 0.0
        
        switch orientation {
        case .portrait:
            angle = 0.0
        case .portraitUpsideDown:
            angle = .pi
        case .landscapeRight:
            angle = -.pi / 2
        case .landscapeLeft:
            angle = .pi / 2
        @unknown default:
            break
        }
        
        return angle
    }
    
    private func calculateFramerate(atTimestamp timestamp: CMTime) {
        previousSecondTimestamps.append(NSValue(time: timestamp))
        
        let oneSecond = CMTimeMake(value: 1, timescale: 1)
        let oneSecondAgo = CMTimeSubtract(timestamp, oneSecond)
        
        while !previousSecondTimestamps.isEmpty && CMTimeCompare(previousSecondTimestamps[0].timeValue, oneSecondAgo) < 0 {
            previousSecondTimestamps.removeFirst()
        }
        
        if previousSecondTimestamps.count > 1 {
            let duration = CMTimeGetSeconds(CMTimeSubtract(previousSecondTimestamps.last!.timeValue, previousSecondTimestamps[0].timeValue))
            let newRate = Float(previousSecondTimestamps.count - 1) / Float(duration)
            videoFrameRate = newRate
        }
    }
    
    private func saveVideoToAlbum() {
        var placeholder: PHObjectPlaceholder?
        
        PHPhotoLibrary.shared().performChanges({
            let createAssetRequest = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: self.recordingURL)
            placeholder = createAssetRequest?.placeholderForCreatedAsset
        }) { [weak self] success, error in
            guard let self = self else { return }
            
            try? FileManager.default.removeItem(at: self.recordingURL)
            
            objc_sync_enter(self)
            defer { objc_sync_exit(self) }
            
            guard self.recordingStatus == .stoppingRecording else {
                fatalError("Expected to be in StoppingRecording state")
            }
            
            self.transition(toRecordingStatus: .idle, error: error)
            
            if success {
                print("didFinishRecordingToOutputFileAtURL - success!")
            } else if let error = error {
                print("\(error)")
            }
        }
    }
    
    private func requestAuthorizationWithRedirectionToSettings() {
        DispatchQueue.main.async {
            let status = PHPhotoLibrary.authorizationStatus()
            if status == .authorized {
                self.saveVideoToAlbum()
            } else {
                PHPhotoLibrary.requestAuthorization { status in
                    if status != .authorized {
                        let accessDescription = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") as? String ?? ""
                        
                        let alertController = UIAlertController(title: accessDescription, message: "To give permissions tap on 'Change Settings' button", preferredStyle: .alert)
                        
                        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
                        
                        alertController.addAction(UIAlertAction(title: "Change Settings", style: .default) { _ in
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                            }
                        })
                        
                        // Get the top view controller to present alert
                        DispatchQueue.main.async {
                            if #available(iOS 13.0, *) {
                                let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                                windowScene?.windows.first?.rootViewController?.present(alertController, animated: true, completion: nil)
                            } else {
                                UIApplication.shared.keyWindow?.rootViewController?.present(alertController, animated: true, completion: nil)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func resetOutputFolder() {
        if let outputFolderURL = createOutputFolderURL() {
            let inertialFileURL = outputFolderURL.appendingPathComponent(IMU_OUTPUT_FILENAME, isDirectory: false)
            inertialRecorder.fileURL = inertialFileURL
            metadataFileURL = outputFolderURL.appendingPathComponent(VIDEO_META_FILENAME, isDirectory: false)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension RosyWriterCapturePipeline: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
        
        if connection == videoConnection {
            if outputVideoFormatDescription == nil {
                setupVideoPipeline(withInputFormatDescription: formatDescription!)
            } else {
                renderVideoSampleBuffer(sampleBuffer, from: connection)
            }
        } else if connection == audioConnection {
            outputAudioFormatDescription = formatDescription
            
            objc_sync_enter(self)
            defer { objc_sync_exit(self) }
            
            if recordingStatus == .recording {
                recorder?.appendAudioSampleBuffer(sampleBuffer)
            }
        }
    }
}

// MARK: - MovieRecorderDelegate

extension RosyWriterCapturePipeline: MovieRecorderDelegate {
    
    func movieRecorderDidFinishPreparing(_ recorder: MovieRecorder) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        
        guard recordingStatus == .startingRecording else {
            fatalError("Expected to be in StartingRecording state")
        }
        
        transition(toRecordingStatus: .recording, error: nil)
    }
    
    func movieRecorder(_ recorder: MovieRecorder, didFailWithError error: Error) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        
        self.recorder = nil
        transition(toRecordingStatus: .idle, error: error)
    }
    
    func movieRecorderDidFinishRecording(_ recorder: MovieRecorder) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        
        guard recordingStatus == .stoppingRecording else {
            fatalError("Expected to be in StoppingRecording state")
        }
        
        let savedFrameTimestamps = recorder.savedFrameTimestamps
        let savedFrameIntrinsics = recorder.savedFrameIntrinsics
        let savedExposureDurations = recorder.savedExposureDurations
        
        self.recorder = nil
        
        requestAuthorizationWithRedirectionToSettings()
        
        print("Video finished recording with \(savedFrameTimestamps.count) timestamps and \(savedFrameIntrinsics.count) intrinsic mats and \(savedExposureDurations.count) exposure durations")
        
        var mainString = "Timestamp[nanosec], fx[px], fy[px], cx[px], cy[px], exposure duration[nanosec]\n"
        let hasIntrinsics = savedFrameIntrinsics.count > 0
        
        for i in 0..<savedFrameTimestamps.count {
            let timestamp = savedFrameTimestamps[i] as! NSNumber
            let exposureDuration = savedExposureDurations[i] as! NSNumber
            
            if hasIntrinsics {
                let intrinsic3x3 = savedFrameIntrinsics[i] as! [NSNumber]
                mainString += "\(timestamp.int64Value), \(intrinsic3x3[0]), \(intrinsic3x3[5]), \(intrinsic3x3[8]), \(intrinsic3x3[9]), \(exposureDuration.int64Value)\n"
            } else {
                mainString += "\(timestamp.int64Value), 1.00, 1.00, 0.50, 0.50, \(exposureDuration.int64Value)\n"
            }
        }
        
        if let settingsData = mainString.data(using: .utf8) {
            do {
                try settingsData.write(to: metadataFileURL, options: .atomic)
                print("Written video metadata to \(metadataFileURL!)")
            } catch {
                print("Failed to record video metadata to \(metadataFileURL!)")
            }
        }
    }
}
