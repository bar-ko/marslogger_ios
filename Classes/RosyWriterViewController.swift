/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample's licensing information
 
 Abstract:
 View controller for camera interface
 */

import UIKit
import AVFoundation
import QuartzCore
import MessageUI
import CoreLocation
import AWSS3
import AWSClientRuntime

// MARK: - RosyWriterViewController

class RosyWriterViewController: UIViewController {
    
    // MARK: - IBOutlets
    
    @IBOutlet weak var preview: UIView!
    @IBOutlet var recordButton: UIBarButtonItem!
    @IBOutlet var framerateLabel: UILabel!
    @IBOutlet var dimensionsLabel: UILabel!
    @IBOutlet weak var recordTimeLabel: UILabel!
    @IBOutlet weak var speedMphLabel: UILabel!
    @IBOutlet weak var speedKmLabel: UILabel!
    @IBOutlet weak var exposureDurationLabel: UILabel!
    @IBOutlet weak var lockAutoLabel: UILabel!
    @IBOutlet weak var exportButton: UIBarButtonItem!
    @IBOutlet weak var uploadButton: UIBarButtonItem!
    
    // Progress bar elements
    private var progressView: UIProgressView?
    private var progressLabel: UILabel?
    private var progressContainerView: UIView?
    
    // S3 Upload elements
    private var uploadProgressView: UIProgressView?
    private var uploadProgressLabel: UILabel?
    private var uploadProgressContainerView: UIView?
    private let s3UploadService = S3UploadService.shared
    
    // MARK: - Properties
    
    var tapToFocus: Bool = true
    var videoCaptureDevice: AVCaptureDevice?
    var focusBoxLayer: CALayer?
    var focusBoxAnimation: CAAnimation?
    var captureVideoPreviewLayer: AVCaptureVideoPreviewLayer?
    
    private var addedObservers = false
    private var recording = false
    private var backgroundRecordingID: UIBackgroundTaskIdentifier = .invalid
    private var allowedToUseGPU = false
    private var labelTimer: Timer?
    private var previewView: OpenGLPixelBufferView?
    private var capturePipeline: RosyWriterCapturePipeline?
    private var previousSpeed: CLLocationSpeed = -1
    
    // Recording timer properties
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    
    // Current recording session UUID
    private var currentRecordingUUID: String?
    
    // File URLs for cleanup after S3 upload
    private var currentVideoURL: URL?
    private var currentInertialDataURL: URL?
    private var currentJSONURL: URL?
    private var totalFilesToUpload = 0
    private var completedUploads = 0
    
    // MARK: - Lifecycle
    
    deinit {
        if addedObservers {
            NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
            NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
            NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: UIDevice.current)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
        
        // Clean up timers
        recordingTimer?.invalidate()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        capturePipeline = RosyWriterCapturePipeline(delegate: self, callbackQueue: DispatchQueue.main)
        
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceOrientationDidChange), name: UIDevice.orientationDidChangeNotification, object: UIDevice.current)
        
        // Keep track of changes to the device orientation so we can update the capture pipeline
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        
        addedObservers = true
        
        // the willEnterForeground and didEnterBackground notifications are subsequently used to update allowedToUseGPU
        allowedToUseGPU = UIApplication.shared.applicationState != .background
        capturePipeline?.renderingEnabled = allowedToUseGPU
        
        // Preview layer
        let bounds = preview.layer.bounds
        captureVideoPreviewLayer = AVCaptureVideoPreviewLayer()
        captureVideoPreviewLayer?.videoGravity = .resizeAspectFill
        captureVideoPreviewLayer?.bounds = bounds
        captureVideoPreviewLayer?.position = CGPoint(x: bounds.midX, y: bounds.midY)
        
        print("previewlayer frame size \(String(format: "%.3f %.3f", captureVideoPreviewLayer?.frame.size.width ?? 0, captureVideoPreviewLayer?.frame.size.height ?? 0)) super preview size \(String(format: "%.3f %.3f", preview.frame.size.width, preview.frame.size.height))")
        
        let devicePosition = AVCaptureDevice.Position.back
        if devicePosition == .unspecified {
            videoCaptureDevice = AVCaptureDevice.default(for: .video)
        } else {
            videoCaptureDevice = camera(with: devicePosition)
        }
        
        // Tap to lock auto focus and auto exposure
        tapToFocus = true
        let tapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTapFrom(_:)))
        tapGestureRecognizer.numberOfTouchesRequired = 1
        tapGestureRecognizer.numberOfTapsRequired = 1
        preview.addGestureRecognizer(tapGestureRecognizer)
        tapGestureRecognizer.delegate = self
        addDefaultFocusBox() // add focus box to view
        
        // Long press to unlock auto focus and auto exposure
        let longPressGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPressFrom(_:)))
        longPressGestureRecognizer.minimumPressDuration = 0.5
        
        // Setup progress bar
        setupProgressBar()
        
        // Setup upload progress bar
        setupUploadProgressBar()
        
        // Setup S3 upload service
        s3UploadService.delegate = self
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        previousSpeed = -1
        capturePipeline?.startRunning()

        labelTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(updateLabels), userInfo: nil, repeats: true)
    }

    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        labelTimer?.invalidate()
        labelTimer = nil
        
        // Stop recording timer if active
        stopRecordingTimer()

        previousSpeed = -1
        capturePipeline?.stopRunning()
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }
    
    override var prefersStatusBarHidden: Bool {
        return true
    }
    
    // MARK: - Application Lifecycle
    
    @objc private func applicationDidEnterBackground() {
        // Avoid using the GPU in the background
        allowedToUseGPU = false
        capturePipeline?.renderingEnabled = false
        
        capturePipeline?.stopRecording() // a no-op if we aren't recording
        
        // We reset the OpenGLPixelBufferView to ensure all resources have been cleared when going to the background.
        previewView?.reset()
    }
    
    @objc private func applicationWillEnterForeground() {
        allowedToUseGPU = true
        capturePipeline?.renderingEnabled = true
    }
    
    // MARK: - Camera Helpers
    
    private func camera(with position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if #available(iOS 10.0, *) {
            let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: position)
            if let device = discoverySession.devices.first {
                return device
            }
            let fallbackSession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
            return fallbackSession.devices.first { $0.position == position }
        } else {
            let devices = AVCaptureDevice.devices(for: .video)
            for device in devices where device.position == position {
                return device
            }
            return nil
        }
    }
    
    // MARK: - Focus Box
    
    private func showFocusBox(at point: CGPoint) {
        if let focusBoxLayer = focusBoxLayer {
            focusBoxLayer.removeAllAnimations()
            
            CATransaction.begin()
            CATransaction.setValue(true, forKey: kCATransactionDisableActions)
            focusBoxLayer.position = point
            CATransaction.commit()
        }
        
        if let focusBoxAnimation = focusBoxAnimation {
            focusBoxLayer?.add(focusBoxAnimation, forKey: "animateOpacity")
        }
    }
    
    func alterFocusBox(_ layer: CALayer, animation: CAAnimation) {
        self.focusBoxLayer = layer
        self.focusBoxAnimation = animation
    }
    
    private func addDefaultFocusBox() {
        let focusBox = CALayer()
        focusBox.cornerRadius = 5.0
        focusBox.bounds = CGRect(x: 0.0, y: 0.0, width: 70, height: 60)
        focusBox.borderWidth = 3.0
        focusBox.borderColor = UIColor.yellow.cgColor
        focusBox.opacity = 0.0
        view.layer.addSublayer(focusBox)
        
        let focusBoxAnimation = CABasicAnimation(keyPath: "opacity")
        focusBoxAnimation.duration = 0.75
        focusBoxAnimation.autoreverses = false
        focusBoxAnimation.repeatCount = 0.0
        focusBoxAnimation.fromValue = 1.0
        focusBoxAnimation.toValue = 0.0
        
        if capturePipeline?.autoLocked == true {
            lockAutoLabel.text = "AE/AF locked"
            lockAutoLabel.isHidden = false
        } else {
            lockAutoLabel.text = "AE/AF"
            lockAutoLabel.isHidden = false
        }
        
        alterFocusBox(focusBox, animation: focusBoxAnimation)
    }
    
    // MARK: - Gesture Handlers
    
    @objc private func handleTapFrom(_ gestureRecognizer: UITapGestureRecognizer) {
        guard tapToFocus else { return }
        
        if gestureRecognizer.state == .ended {
            let touchedPoint = gestureRecognizer.location(in: gestureRecognizer.view)
            
            if let previewLayer = captureVideoPreviewLayer,
               let ports = capturePipeline?.videoDeviceInput.ports {
                let pointOfInterest = convertToPointOfInterest(from: touchedPoint, previewLayer: previewLayer, ports: ports)
                capturePipeline?.focus(at: pointOfInterest)
                
                if capturePipeline?.autoLocked == true {
                    lockAutoLabel.text = "AE/AF locked"
                    lockAutoLabel.isHidden = false
                    showFocusBox(at: touchedPoint)
                } else {
                    lockAutoLabel.text = "AE/AF"
                    lockAutoLabel.isHidden = false
                }
            }
        }
    }
    
    @objc private func handleLongPressFrom(_ gestureRecognizer: UILongPressGestureRecognizer) {
        if gestureRecognizer.state == .ended {
            capturePipeline?.unlockFocusAndExposure()
            
            if capturePipeline?.autoLocked == true {
                lockAutoLabel.text = "AE/AF locked"
                lockAutoLabel.isHidden = false
            } else {
                lockAutoLabel.text = "AE/AF"
                lockAutoLabel.isHidden = false
            }
        }
    }
    
    // MARK: - UI Actions
    
    @IBAction func toggleRecording(_ sender: Any) {
        if recording {
            capturePipeline?.stopRecording()
        } else {
            // Generate new UUID for this recording session
            currentRecordingUUID = UUID().uuidString
            print("Starting new recording session with UUID: \(currentRecordingUUID!)")
            
            // Set UUID in capture pipeline
            capturePipeline?.setRecordingUUID(currentRecordingUUID!)
            
            // Disable the idle timer while recording
            UIApplication.shared.isIdleTimerDisabled = true
            
            // Make sure we have time to finish saving the movie if the app is backgrounded during recording
            if UIDevice.current.isMultitaskingSupported {
                backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: {})
            }
            
            recordButton.isEnabled = false // re-enabled once recording has finished starting
            recordButton.title = "Stop"
            
            capturePipeline?.startRecording()
            
            // Start recording timer
            startRecordingTimer()
            
            recording = true
        }
    }
    
@IBAction func exportButtonPressed(_ sender: Any) {
        guard let inertialDataFile = capturePipeline?.getInertialFileURL() else {
            showAlert("No inertial data file available for upload")
            return
        }
        
        if recording {
            showAlert("Cannot upload while recording")
            return
        }
        
        // Show confirmation dialog
        let alert = UIAlertController(
            title: "Upload to S3",
            message: "Upload video and inertial data to AWS S3?",
            preferredStyle: .alert
        )
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Upload", style: .default) { [weak self] _ in
            self?.startS3Upload()
        })
        
        present(alert, animated: true)
    }
    
    // MARK: - Recording Timer Methods
    
    private func startRecordingTimer() {
        recordingStartTime = Date()
        recordTimeLabel.text = "00:00"
        recordingTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(updateRecordingTime), userInfo: nil, repeats: true)
    }
    
    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartTime = nil
        recordTimeLabel.text = ""
    }
    
    @objc private func updateRecordingTime() {
        guard let startTime = recordingStartTime else { return }
        
        let elapsed = Date().timeIntervalSince(startTime)
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        
        recordTimeLabel.text = String(format: "%02d:%02d", minutes, seconds)
    }
    
    // MARK: - Helper Methods
    
    private func recordingStopped() {
        recording = false
        recordButton.isEnabled = true
        recordButton.title = "Record"
        
        // Stop recording timer
        stopRecordingTimer()
        
        UIApplication.shared.isIdleTimerDisabled = false
        
        UIApplication.shared.endBackgroundTask(backgroundRecordingID)
        backgroundRecordingID = .invalid
    }
    
    private func setupPreviewView() {
        // Set up GL view
        previewView = OpenGLPixelBufferView(frame: .zero)
        previewView?.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        
        // Get current interface orientation
        let currentInterfaceOrientation: UIInterfaceOrientation
        if #available(iOS 13.0, *) {
            currentInterfaceOrientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        } else {
            currentInterfaceOrientation = UIApplication.shared.statusBarOrientation
        }
        
        if let transform = capturePipeline?.transform(fromVideoBufferOrientationTo: AVCaptureVideoOrientation(rawValue: currentInterfaceOrientation.rawValue)!, withAutoMirroring: true) {
            previewView?.transform = transform
        }
        
        if let previewView = previewView {
            view.insertSubview(previewView, at: 0)
            var bounds = CGRect.zero
            bounds.size = view.convert(view.bounds, to: previewView).size
            previewView.bounds = bounds
            previewView.center = CGPoint(x: view.bounds.size.width / 2.0, y: view.bounds.size.height / 2.0)
        }
    }
    
    private func setupProgressBar() {
        // Create container view
        progressContainerView = UIView()
        progressContainerView?.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        progressContainerView?.layer.cornerRadius = 10
        progressContainerView?.translatesAutoresizingMaskIntoConstraints = false
        
        // Create progress view
        progressView = UIProgressView(progressViewStyle: .default)
        progressView?.progressTintColor = UIColor.systemBlue
        progressView?.trackTintColor = UIColor.systemGray4
        progressView?.translatesAutoresizingMaskIntoConstraints = false
        
        // Create progress label
        progressLabel = UILabel()
        progressLabel?.text = "Сохранение видео... 0%"
        progressLabel?.textColor = UIColor.white
        progressLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        progressLabel?.textAlignment = .center
        progressLabel?.translatesAutoresizingMaskIntoConstraints = false
        
        guard let containerView = progressContainerView,
              let progressView = progressView,
              let progressLabel = progressLabel else { return }
        
        // Add subviews
        containerView.addSubview(progressLabel)
        containerView.addSubview(progressView)
        view.addSubview(containerView)
        
        // Set up constraints
        NSLayoutConstraint.activate([
            // Container view constraints
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 280),
            containerView.heightAnchor.constraint(equalToConstant: 80),
            
            // Progress label constraints
            progressLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            progressLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            progressLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            
            // Progress view constraints
            progressView.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 8),
            progressView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            progressView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            progressView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16)
        ])
        
        // Initially hidden
        containerView.isHidden = true
    }
    
    private func setupUploadProgressBar() {
        // Create container view
        uploadProgressContainerView = UIView()
        uploadProgressContainerView?.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.9)
        uploadProgressContainerView?.layer.cornerRadius = 10
        uploadProgressContainerView?.translatesAutoresizingMaskIntoConstraints = false
        
        // Create progress view
        uploadProgressView = UIProgressView(progressViewStyle: .default)
        uploadProgressView?.progressTintColor = UIColor.white
        uploadProgressView?.trackTintColor = UIColor.systemGray5
        uploadProgressView?.translatesAutoresizingMaskIntoConstraints = false
        
        // Create progress label
        uploadProgressLabel = UILabel()
        uploadProgressLabel?.text = "Uploading to S3... 0%"
        uploadProgressLabel?.textColor = UIColor.white
        uploadProgressLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        uploadProgressLabel?.textAlignment = .center
        uploadProgressLabel?.translatesAutoresizingMaskIntoConstraints = false
        
        guard let containerView = uploadProgressContainerView,
              let progressView = uploadProgressView,
              let progressLabel = uploadProgressLabel else { return }
        
        // Add subviews
        containerView.addSubview(progressLabel)
        containerView.addSubview(progressView)
        view.addSubview(containerView)
        
        // Set up constraints
        NSLayoutConstraint.activate([
            // Container view constraints
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 100),
            containerView.widthAnchor.constraint(equalToConstant: 280),
            containerView.heightAnchor.constraint(equalToConstant: 80),
            
            // Progress label constraints
            progressLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 16),
            progressLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            progressLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            
            // Progress view constraints
            progressView.topAnchor.constraint(equalTo: progressLabel.bottomAnchor, constant: 8),
            progressView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 16),
            progressView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -16),
            progressView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -16)
        ])
        
        // Initially hidden
        containerView.isHidden = true
    }
    
    @objc private func deviceOrientationDidChange() {
        let deviceOrientation = UIDevice.current.orientation
        
        // Update the recording orientation if the device changes to portrait or landscape orientation (but not face up/down)
        if deviceOrientation.isPortrait || deviceOrientation.isLandscape {
            capturePipeline?.recordingOrientation = AVCaptureVideoOrientation(rawValue: deviceOrientation.rawValue)!
        }
    }
    
    @objc private func updateLabels() {
        guard let capturePipeline = capturePipeline else { return }
        
        let frameRateString = String(format: "%.1f FPS %.2f", capturePipeline.videoFrameRate, capturePipeline.fx)
        framerateLabel.text = frameRateString
        
        let dimensionsString = String(format: "%d x %d", capturePipeline.videoDimensions.width, capturePipeline.videoDimensions.height)
        dimensionsLabel.text = dimensionsString
        
        let exposureDurationString = String(format: "%.2f ms", Double(capturePipeline.exposureDuration) / 1000000.0)
        exposureDurationLabel.text = exposureDurationString

        let currentSpeed = capturePipeline.getCurrentSpeed()
        if previousSpeed < 0 || abs(currentSpeed - previousSpeed) >= 0.01 {
            updateSpeedLabels(withMetersPerSecond: currentSpeed)
            previousSpeed = currentSpeed
        }
    }

    private func updateSpeedLabels(withMetersPerSecond speed: CLLocationSpeed) {
        let clampedSpeed = max(speed, 0)
        let speedMph = clampedSpeed * 2.23693629
        let speedKm = clampedSpeed * 3.6

        speedMphLabel.text = String(format: "%.1f mph", speedMph)
        speedKmLabel.text = String(format: "%.1f km/h", speedKm)
    }
    
    private func showAlert(_ message: String) {
        let alert = UIAlertController(title: nil, message: "", preferredStyle: .alert)
        
        if let firstSubview = alert.view.subviews.first,
           let alertContentView = firstSubview.subviews.first {
            for subSubView in alertContentView.subviews {
                subSubView.backgroundColor = UIColor(red: 141/255.0, green: 0/255.0, blue: 254/255.0, alpha: 1.0)
            }
        }
        
        let attributedString = NSMutableAttributedString(string: message)
        attributedString.addAttribute(.foregroundColor, value: UIColor.white, range: NSRange(location: 0, length: attributedString.length))
        alert.setValue(attributedString, forKey: "attributedTitle")
        
        present(alert, animated: true, completion: nil)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            alert.dismiss(animated: true, completion: nil)
        }
    }
    
    private func showError(_ error: Error) {
        let alert = UIAlertController(title: error.localizedDescription, message: (error as NSError).localizedFailureReason, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension RosyWriterViewController: UIGestureRecognizerDelegate {
    // Add any gesture recognizer delegate methods if needed
}

// MARK: - MFMailComposeViewControllerDelegate

extension RosyWriterViewController: MFMailComposeViewControllerDelegate {
    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        switch result {
        case .sent:
            print("Email sent")
        case .saved:
            print("Email saved")
        case .cancelled:
            print("Email cancelled")
        case .failed:
            print("Email failed")
        @unknown default:
            print("Error occurred during email creation")
        }
        
        dismiss(animated: true, completion: nil)
    }
}

// MARK: - RosyWriterCapturePipelineDelegate

extension RosyWriterViewController: RosyWriterCapturePipelineDelegate {
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, didStopRunningWithError error: Error) {
        showError(error)
        recordButton.isEnabled = false
    }
    
    // Preview
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, previewPixelBufferReadyForDisplay previewPixelBuffer: CVPixelBuffer) {
        guard allowedToUseGPU else { return }
        
        if previewView == nil {
            setupPreviewView()
        }
        
        previewView?.displayPixelBuffer(previewPixelBuffer)
    }
    
    func capturePipelineDidRunOutOfPreviewBuffers(_ capturePipeline: RosyWriterCapturePipeline) {
        if allowedToUseGPU {
            previewView?.flushPixelBufferCache()
        }
    }
    
    // Recording
    func capturePipelineRecordingDidStart(_ capturePipeline: RosyWriterCapturePipeline) {
        recordButton.isEnabled = true
    }
    
    func capturePipelineRecordingWillStop(_ capturePipeline: RosyWriterCapturePipeline) {
        // Disable record button until we are ready to start another recording
        recordButton.isEnabled = false
        recordButton.title = "Record"
        
        // Show progress bar when starting to save video
        showProgressBar()
    }
    
    func capturePipelineRecordingDidStop(_ capturePipeline: RosyWriterCapturePipeline) {
        recordingStopped()
    }
    
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, recordingDidFailWithError error: Error) {
        recordingStopped()
        hideProgressBar()
        showError(error)
    }
    
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, didUpdateSavingProgress progress: Float) {
        DispatchQueue.main.async { [weak self] in
            self?.updateProgressBar(progress: progress)
        }
    }
}

// MARK: - Progress Bar Methods

extension RosyWriterViewController {
    private func showProgressBar() {
        progressContainerView?.isHidden = false
        progressView?.progress = 0.0
        progressLabel?.text = "Saving video... 0%"
    }
    
    private func hideProgressBar() {
        progressContainerView?.isHidden = true
    }
    
    private func updateProgressBar(progress: Float) {
        let percentage = Int(progress * 100)
        progressView?.progress = progress
        progressLabel?.text = "Saving video... \(percentage)%"
        
        // Hide progress bar when complete
        if progress >= 1.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.hideProgressBar()
            }
        }
    }
}

// MARK: - S3 Upload Methods

extension RosyWriterViewController {
    
    private func startS3Upload() {
        guard let inertialDataFile = capturePipeline?.getInertialFileURL(),
              let recordingUUID = currentRecordingUUID else {
            showAlert("No files available for upload or missing recording UUID")
            return
        }
        
        let videoFileURL = capturePipeline?.getVideoFileURL()
        
        // Store file URLs for cleanup
        currentVideoURL = videoFileURL
        currentInertialDataURL = inertialDataFile
        
        // Reset upload counters
        completedUploads = 0
        totalFilesToUpload = 1 // inertial data (JSON and video will be added separately)
        if videoFileURL != nil {
            totalFilesToUpload += 1 // add video if available
        }
        
        showUploadProgressBar()
        
        // Upload video file
        if let videoURL = videoFileURL {
            s3UploadService.uploadVideo(at: videoURL, withUUID: recordingUUID)
        }
        
        // Upload inertial data file
        s3UploadService.uploadInertialData(at: inertialDataFile, withUUID: recordingUUID)
        
        // Create and upload JSON file with session metadata
        createAndUploadJSONMetadata(withUUID: recordingUUID)
    }
    
    private func showUploadProgressBar() {
        uploadProgressContainerView?.isHidden = false
        uploadProgressView?.progress = 0.0
        uploadProgressLabel?.text = "Uploading to S3... 0%"
    }
    
    private func hideUploadProgressBar() {
        uploadProgressContainerView?.isHidden = true
    }
    
    private func updateUploadProgressBar(progress: Float, message: String) {
        let percentage = Int(progress * 100)
        uploadProgressView?.progress = progress
        uploadProgressLabel?.text = "\(message) \(percentage)%"
        
        // Hide progress bar when complete
        if progress >= 1.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.hideUploadProgressBar()
            }
        }
    }
    
    private func createAndUploadJSONMetadata(withUUID uuid: String) {
        // Create JSON metadata with session information
        let metadata: [String: Any] = [
            "session_uuid": uuid,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "device_info": [
                "model": UIDevice.current.model,
                "system_name": UIDevice.current.systemName,
                "system_version": UIDevice.current.systemVersion,
                "identifier_for_vendor": UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
            ],
            "recording_info": [
                "start_time": recordingStartTime?.timeIntervalSince1970 ?? 0,
                "duration_seconds": recordingStartTime != nil ? Date().timeIntervalSince(recordingStartTime!) : 0
            ],
            "files": [
                "video": "mars_data/video/\(uuid).mp4",
                "inertial_data": "mars_data/data/\(uuid).csv",
                "session_info": "mars_data/task/\(uuid).json"
            ]
        ]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted)
            
            // Create temporary file
            let tempDirectory = FileManager.default.temporaryDirectory
            let jsonFileURL = tempDirectory.appendingPathComponent("\(uuid).json")
            
            try jsonData.write(to: jsonFileURL)
            
            // Store JSON URL for cleanup
            currentJSONURL = jsonFileURL
            totalFilesToUpload += 1 // Add JSON to total count
            
            // Upload JSON file
            s3UploadService.uploadJSON(at: jsonFileURL, withUUID: uuid)
            
            print("Created and uploading JSON metadata file: \(jsonFileURL.path)")
            
        } catch {
            print("Failed to create JSON metadata: \(error.localizedDescription)")
            showAlert("Failed to create session metadata")
        }
    }
}

// MARK: - Helper Extension (Coordinate Conversion)

extension RosyWriterViewController {
    func convertToPointOfInterest(from viewCoordinates: CGPoint, previewLayer: AVCaptureVideoPreviewLayer, ports: [AVCaptureInput.Port]) -> CGPoint {
        var pointOfInterest = CGPoint(x: 0.5, y: 0.5)
        let frameSize = previewLayer.frame.size
        
        if previewLayer.videoGravity == .resize {
            pointOfInterest = CGPoint(x: viewCoordinates.y / frameSize.height, y: 1.0 - (viewCoordinates.x / frameSize.width))
        } else {
            for port in ports {
                if port.mediaType == .video {
                    let cleanAperture = CMVideoFormatDescriptionGetCleanAperture(port.formatDescription!, originIsAtTopLeft: true)
                    let apertureSize = cleanAperture.size
                    let point = viewCoordinates
                    
                    let apertureRatio = apertureSize.height / apertureSize.width
                    let viewRatio = frameSize.width / frameSize.height
                    var xc: CGFloat = 0.5
                    var yc: CGFloat = 0.5
                    
                    if previewLayer.videoGravity == .resizeAspect {
                        if viewRatio > apertureRatio {
                            let y2 = frameSize.height
                            let x2 = frameSize.height * apertureRatio
                            let x1 = frameSize.width
                            let blackBar = (x1 - x2) / 2
                            if point.x >= blackBar && point.x <= blackBar + x2 {
                                xc = point.y / y2
                                yc = 1.0 - ((point.x - blackBar) / x2)
                            }
                        } else {
                            let y2 = frameSize.width / apertureRatio
                            let y1 = frameSize.height
                            let x2 = frameSize.width
                            let blackBar = (y1 - y2) / 2
                            if point.y >= blackBar && point.y <= blackBar + y2 {
                                xc = (point.y - blackBar) / y2
                                yc = 1.0 - (point.x / x2)
                            }
                        }
                    } else if previewLayer.videoGravity == .resizeAspectFill {
                        if viewRatio > apertureRatio {
                            let y2 = apertureSize.width * (frameSize.width / apertureSize.height)
                            xc = (point.y + ((y2 - frameSize.height) / 2.0)) / y2
                            yc = (frameSize.width - point.x) / frameSize.width
                        } else {
                            let x2 = apertureSize.height * (frameSize.height / apertureSize.width)
                            yc = 1.0 - ((point.x + ((x2 - frameSize.width) / 2)) / x2)
                            xc = point.y / frameSize.height
                        }
                    }
                    
                    pointOfInterest = CGPoint(x: xc, y: yc)
                    break
                }
            }
        }
        
        return pointOfInterest
    }
    
    func cropImage(_ image: UIImage, usingPreviewLayer previewLayer: AVCaptureVideoPreviewLayer) -> UIImage {
        let previewBounds = previewLayer.bounds
        let outputRect = previewLayer.metadataOutputRectConverted(fromLayerRect: previewBounds)
        
        guard let takenCGImage = image.cgImage else { return image }
        let width = CGFloat(takenCGImage.width)
        let height = CGFloat(takenCGImage.height)
        let cropRect = CGRect(x: outputRect.origin.x * width,
                             y: outputRect.origin.y * height,
                             width: outputRect.size.width * width,
                             height: outputRect.size.height * height)
        
        guard let cropCGImage = takenCGImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropCGImage, scale: 1, orientation: image.imageOrientation)
    }
}

// MARK: - S3UploadDelegate

extension RosyWriterViewController: S3UploadDelegate {
    
    func s3Upload(_ service: S3UploadService, didCompleteUpload key: String, location: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            print("S3 Upload completed for key: \(key)")
            print("Upload location: \(location)")
            
            self.completedUploads += 1
            
            // Check if all uploads are complete
            if self.completedUploads >= self.totalFilesToUpload {
                self.updateUploadProgressBar(progress: 1.0, message: "Upload completed!")
                self.showAlert("Files successfully uploaded to S3")
                
                // Clean up local files after successful upload
                service.cleanupFiles(
                    videoURL: self.currentVideoURL,
                    inertialDataURL: self.currentInertialDataURL,
                    jsonURL: self.currentJSONURL
                )
                
                // Reset file URLs
                self.currentVideoURL = nil
                self.currentInertialDataURL = nil
                self.currentJSONURL = nil
                self.completedUploads = 0
                self.totalFilesToUpload = 0
            }
        }
    }
    
    func s3Upload(_ service: S3UploadService, didFailWithError error: Error, forKey key: String) {
        DispatchQueue.main.async { [weak self] in
            print("S3 Upload failed for key \(key): \(error.localizedDescription)")
            self?.hideUploadProgressBar()
            self?.showAlert("Upload failed: \(error.localizedDescription)")
        }
    }
    
    func s3Upload(_ service: S3UploadService, didUpdateProgress progress: Float, forKey key: String) {
        DispatchQueue.main.async { [weak self] in
            // Average progress across all active uploads
            let averageProgress = progress / Float(max(1, service.activeUploadCount()))
            self?.updateUploadProgressBar(progress: averageProgress, message: "Uploading to S3...")
        }
    }
}
