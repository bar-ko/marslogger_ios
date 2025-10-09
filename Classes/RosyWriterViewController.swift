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

// MARK: - RosyWriterViewController

class RosyWriterViewController: UIViewController {
    
    // MARK: - IBOutlets
    
    @IBOutlet weak var preview: UIView!
    @IBOutlet var recordButton: UIBarButtonItem!
    @IBOutlet var framerateLabel: UILabel!
    @IBOutlet var dimensionsLabel: UILabel!
    @IBOutlet weak var exposureDurationLabel: UILabel!
    @IBOutlet weak var lockAutoLabel: UILabel!
    @IBOutlet weak var exportButton: UIBarButtonItem!
    
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
    
    // MARK: - Lifecycle
    
    deinit {
        if addedObservers {
            NotificationCenter.default.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
            NotificationCenter.default.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: UIApplication.shared)
            NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: UIDevice.current)
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
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
        preview.addGestureRecognizer(longPressGestureRecognizer)
        longPressGestureRecognizer.delegate = self
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        capturePipeline?.startRunning()
        
        labelTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(updateLabels), userInfo: nil, repeats: true)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        
        labelTimer?.invalidate()
        labelTimer = nil
        
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
        let devices = AVCaptureDevice.devices(for: .video)
        for device in devices {
            if device.position == position {
                return device
            }
        }
        return nil
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
            // Disable the idle timer while recording
            UIApplication.shared.isIdleTimerDisabled = true
            
            // Make sure we have time to finish saving the movie if the app is backgrounded during recording
            if UIDevice.current.isMultitaskingSupported {
                backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: {})
            }
            
            recordButton.isEnabled = false // re-enabled once recording has finished starting
            recordButton.title = "Stop"
            
            capturePipeline?.startRecording()
            
            recording = true
        }
    }
    
    @IBAction func exportButtonPressed(_ sender: Any) {
        guard let videoMetadataFile = capturePipeline?.metadataFileURL,
              let inertialDataFile = capturePipeline?.getInertialFileURL() else {
            print("Video metadata file or inertial data file is nil, so no export will be done!")
            return
        }
        
        if recording {
            print("In recording state no export will be done!")
            return
        }
        
        if MFMailComposeViewController.canSendMail() {
            let mailVC = MFMailComposeViewController()
            mailVC.mailComposeDelegate = self
            
            let outputURL = videoMetadataFile.deletingLastPathComponent()
            let outputBasename = outputURL.lastPathComponent
            mailVC.setSubject(outputBasename)
            
            let message = """
            The attached metadata of camera frames and inertial data were captured by the MARS logger starting from \(outputBasename)!
            The associated video was the most recent one found with the Photos App at the time of sending this email.
            """
            mailVC.setMessageBody(message, isHTML: false)
            
            if let metaData = try? Data(contentsOf: videoMetadataFile) {
                let videoBasename = videoMetadataFile.lastPathComponent
                mailVC.addAttachmentData(metaData, mimeType: "text/csv", fileName: videoBasename)
            }
            
            if let inertialData = try? Data(contentsOf: inertialDataFile) {
                let inertialBasename = inertialDataFile.lastPathComponent
                mailVC.addAttachmentData(inertialData, mimeType: "text/csv", fileName: inertialBasename)
            }
            
            present(mailVC, animated: true, completion: nil)
        } else {
            showAlert("This device cannot send email. Have you setup the mailbox?")
        }
    }
    
    // MARK: - Helper Methods
    
    private func recordingStopped() {
        recording = false
        recordButton.isEnabled = true
        recordButton.title = "Record"
        
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
    }
    
    func capturePipelineRecordingDidStop(_ capturePipeline: RosyWriterCapturePipeline) {
        recordingStopped()
    }
    
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, recordingDidFailWithError error: Error) {
        recordingStopped()
        showError(error)
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
                    let cleanAperture = CMVideoFormatDescriptionGetCleanAperture(port.formatDescription!, true)
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
