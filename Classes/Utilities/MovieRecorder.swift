/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample's licensing information

 Abstract:
 Real-time movie recorder which is totally non-blocking - Swift Implementation
 */

import Foundation
import AVFoundation
import CoreMedia

let LOG_STATUS_TRANSITIONS = false

// MARK: - MovieRecorderStatus Enum

enum MovieRecorderStatus: Int {
    case idle = 0
    case preparingToRecord
    case recording
    case finishingRecordingPart1 // waiting for inflight buffers to be appended
    case finishingRecordingPart2 // calling finish writing on the asset writer
    case finished // terminal state
    case failed // terminal state
}

// MARK: - MovieRecorderDelegate Protocol

protocol MovieRecorderDelegate: AnyObject {
    func movieRecorderDidFinishPreparing(_ recorder: MovieRecorder)
    func movieRecorder(_ recorder: MovieRecorder, didFailWithError error: Error)
    func movieRecorderDidFinishRecording(_ recorder: MovieRecorder)
}

// MARK: - MovieRecorder Class

class MovieRecorder: NSObject {

    // MARK: - Public Properties

    private(set) var savedFrameTimestamps: NSMutableArray = NSMutableArray()
    private(set) var savedFrameIntrinsics: NSMutableArray = NSMutableArray()
    private(set) var savedExposureDurations: NSMutableArray = NSMutableArray()

    // MARK: - Private Properties

    private var status: MovieRecorderStatus = .idle
    private let writingQueue: DispatchQueue
    private let url: URL
    private weak var delegate: MovieRecorderDelegate?
    private let delegateCallbackQueue: DispatchQueue

    private var assetWriter: AVAssetWriter?
    private var haveStartedSession = false

    private var audioTrackSourceFormatDescription: CMFormatDescription?
    private var audioTrackSettings: [String: Any]?
    private var audioInput: AVAssetWriterInput?

    private var videoTrackSourceFormatDescription: CMFormatDescription?
    private var videoTrackTransform: CGAffineTransform = .identity
    private var videoTrackSettings: [String: Any]?
    private var videoInput: AVAssetWriterInput?

    // MARK: - Initialization

    init(url: URL, delegate: MovieRecorderDelegate, callbackQueue: DispatchQueue) {
        precondition(delegate != nil, "Delegate cannot be nil")
        precondition(callbackQueue != nil, "Callback queue cannot be nil")
        precondition(url.isFileURL, "URL must be a file URL")

        self.url = url
        self.delegate = delegate
        self.delegateCallbackQueue = callbackQueue
        self.writingQueue = DispatchQueue(label: "com.apple.sample.movierecorder.writing")

        super.init()
    }

    deinit {
        if let audioTrackSourceFormatDescription = audioTrackSourceFormatDescription {
            audioTrackSourceFormatDescription.release()
        }

        if let videoTrackSourceFormatDescription = videoTrackSourceFormatDescription {
            videoTrackSourceFormatDescription.release()
        }
    }

    // MARK: - Public Methods

    func addVideoTrack(withSourceFormatDescription formatDescription: CMFormatDescription,
                      transform: CGAffineTransform,
                      settings videoSettings: [String: Any]) {

        precondition(formatDescription != nil, "Format description cannot be nil")

        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard status == .idle else {
            fatalError("Cannot add tracks while not idle")
        }

        guard videoTrackSourceFormatDescription == nil else {
            fatalError("Cannot add more than one video track")
        }

        videoTrackSourceFormatDescription = formatDescription.retained()
        videoTrackTransform = transform
        videoTrackSettings = videoSettings
    }

    func addAudioTrack(withSourceFormatDescription formatDescription: CMFormatDescription,
                      settings audioSettings: [String: Any]) {

        precondition(formatDescription != nil, "Format description cannot be nil")

        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard status == .idle else {
            fatalError("Cannot add tracks while not idle")
        }

        guard audioTrackSourceFormatDescription == nil else {
            fatalError("Cannot add more than one audio track")
        }

        audioTrackSourceFormatDescription = formatDescription.retained()
        audioTrackSettings = audioSettings
    }

    func prepareToRecord() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard status == .idle else {
            fatalError("Already prepared, cannot prepare again")
        }

        // Clear saved data
        savedFrameTimestamps.removeAllObjects()
        savedFrameIntrinsics.removeAllObjects()
        savedExposureDurations.removeAllObjects()

        transition(toStatus: .preparingToRecord, error: nil)
        objc_sync_exit(self)

        // Perform preparation asynchronously
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            autoreleasepool {
                var error: NSError?

                // Remove existing file
                try? FileManager.default.removeItem(at: self.url)

                // Create asset writer
                do {
                    self.assetWriter = try AVAssetWriter(url: self.url, fileType: .mov)
                } catch let writerError {
                    error = writerError as NSError
                }

                // Setup inputs
                if error == nil, let videoFormat = self.videoTrackSourceFormatDescription {
                    self.setupAssetWriterVideoInput(withSourceFormatDescription: videoFormat,
                                                  transform: self.videoTrackTransform,
                                                  settings: self.videoTrackSettings,
                                                  error: &error)
                }

                if error == nil, let audioFormat = self.audioTrackSourceFormatDescription {
                    self.setupAssetWriterAudioInput(withSourceFormatDescription: audioFormat,
                                                  settings: self.audioTrackSettings,
                                                  error: &error)
                }

                // Start writing
                if error == nil {
                    let success = self.assetWriter?.startWriting() ?? false
                    if !success {
                        error = self.assetWriter?.error as NSError
                    }
                }

                // Transition to appropriate state
                objc_sync_enter(self)
                defer { objc_sync_exit(self) }

                if let error = error {
                    self.transition(toStatus: .failed, error: error)
                } else {
                    self.transition(toStatus: .recording, error: nil)
                }
            }
        }
    }

    func appendVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer,
                               withPresentationTime presentationTime: CMTime,
                               withIntrinsicMat intrinsic3x3: [NSNumber],
                               withExposureDuration exposureDuration: Int64) {

        var sampleBuffer: CMSampleBuffer?

        var timingInfo = CMSampleTimingInfo(duration: .invalid,
                                          presentationTimeStamp: presentationTime,
                                          decodeTimeStamp: .invalid)

        let status = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                      imageBuffer: pixelBuffer,
                                                      dataReady: true,
                                                      makeDataReadyCallback: nil,
                                                      refcon: nil,
                                                      formatDescription: videoTrackSourceFormatDescription!,
                                                      sampleTiming: &timingInfo,
                                                      sampleBufferOut: &sampleBuffer)

        if let sampleBuffer = sampleBuffer {
            appendSampleBuffer(sampleBuffer,
                             ofMediaType: .video,
                             withIntrinsicMat: intrinsic3x3,
                             withExposureDuration: exposureDuration)
            sampleBuffer.release()
        } else {
            fatalError("Sample buffer create failed (\(status))")
        }
    }

    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        appendSampleBuffer(sampleBuffer, ofMediaType: .audio)
    }

    func finishRecording() {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        var shouldFinishRecording = false

        switch status {
        case .idle, .preparingToRecord, .finishingRecordingPart1, .finishingRecordingPart2, .finished:
            fatalError("Not recording")
        case .failed:
            print("Recording has failed, nothing to do")
            return
        case .recording:
            shouldFinishRecording = true
        }

        if shouldFinishRecording {
            transition(toStatus: .finishingRecordingPart1, error: nil)
        }
        objc_sync_exit(self)

        writingQueue.async { [weak self] in
            guard let self = self else { return }

            autoreleasepool {
                objc_sync_enter(self)
                defer { objc_sync_exit(self) }

                // Check if we've transitioned to an error state
                guard self.status == .finishingRecordingPart1 else {
                    return
                }

                // Transition to finishing part 2
                self.transition(toStatus: .finishingRecordingPart2, error: nil)
                objc_sync_exit(self)

                // Finish writing
                self.assetWriter?.finishWriting { [weak self] in
                    guard let self = self else { return }

                    objc_sync_enter(self)
                    defer { objc_sync_exit(self) }

                    let error = self.assetWriter?.error
                    if let error = error {
                        self.transition(toStatus: .failed, error: error)
                    } else {
                        self.transition(toStatus: .finished, error: nil)
                    }
                }
            }
        }
    }

    // MARK: - Private Methods

    private func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                  ofMediaType mediaType: AVMediaType) {
        appendSampleBuffer(sampleBuffer,
                         ofMediaType: mediaType,
                         withIntrinsicMat: nil,
                         withExposureDuration: -1)
    }

    private func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                  ofMediaType mediaType: AVMediaType,
                                  withIntrinsicMat intrinsic3x3: [NSNumber]?,
                                  withExposureDuration exposureDuration: Int64) {

        precondition(sampleBuffer != nil, "Sample buffer cannot be nil")

        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        guard status.rawValue >= MovieRecorderStatus.recording.rawValue else {
            fatalError("Not ready to record yet")
        }
        objc_sync_exit(self)

        sampleBuffer.retain()
        writingQueue.async { [weak self] in
            guard let self = self else {
                sampleBuffer.release()
                return
            }

            autoreleasepool {
                objc_sync_enter(self)
                defer { objc_sync_exit(self) }

                // Check if we should still be recording
                guard self.status.rawValue <= MovieRecorderStatus.finishingRecordingPart1.rawValue else {
                    sampleBuffer.release()
                    return
                }

                let sampleTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let frameTimestamp = CMTimeGetNanoseconds(sampleTime)

                // Start session if needed
                if !self.haveStartedSession {
                    self.assetWriter?.startSession(atSourceTime: sampleTime)
                    self.haveStartedSession = true
                }

                // Get appropriate input
                let input = (mediaType == .video) ? self.videoInput : self.audioInput

                if input?.isReadyForMoreMediaData == true {
                    let success = input?.append(sampleBuffer) ?? false
                    if !success {
                        let error = self.assetWriter?.error
                        objc_sync_enter(self)
                        defer { objc_sync_exit(self) }
                        self.transition(toStatus: .failed, error: error)
                    } else {
                        // Store metadata
                        self.savedFrameTimestamps.add(NSNumber(value: frameTimestamp))
                        if let intrinsic3x3 = intrinsic3x3 {
                            self.savedFrameIntrinsics.add(intrinsic3x3)
                        }
                        if exposureDuration != -1 {
                            self.savedExposureDurations.add(NSNumber(value: exposureDuration))
                        }
                    }
                } else {
                    print("\(mediaType.rawValue) input not ready for more media data, dropping buffer")
                }

                sampleBuffer.release()
            }
        }
    }

    private func transition(toStatus newStatus: MovieRecorderStatus, error: Error?) {
        var shouldNotifyDelegate = false

        if LOG_STATUS_TRANSITIONS {
            print("MovieRecorder state transition: \(status) -> \(newStatus)")
        }

        if newStatus != status {
            // Terminal states
            if newStatus == .finished || newStatus == .failed {
                shouldNotifyDelegate = true

                writingQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.teardownAssetWriterAndInputs()
                    if newStatus == .failed {
                        try? FileManager.default.removeItem(at: self.url)
                    }
                }

                if LOG_STATUS_TRANSITIONS, let error = error {
                    print("MovieRecorder error: \(error.localizedDescription), code: \((error as NSError).code)")
                }
            } else if newStatus == .recording {
                shouldNotifyDelegate = true
            }

            status = newStatus
        }

        if shouldNotifyDelegate {
            delegateCallbackQueue.async { [weak self] in
                guard let self = self else { return }

                autoreleasepool {
                    switch newStatus {
                    case .recording:
                        self.delegate?.movieRecorderDidFinishPreparing(self)
                    case .finished:
                        self.delegate?.movieRecorderDidFinishRecording(self)
                    case .failed:
                        if let error = error {
                            self.delegate?.movieRecorder(self, didFailWithError: error)
                        }
                    default:
                        assertionFailure("Unexpected recording status (\(newStatus.rawValue)) for delegate callback")
                    }
                }
            }
        }
    }

    private func setupAssetWriterAudioInput(withSourceFormatDescription audioFormatDescription: CMFormatDescription,
                                           settings audioSettings: [String: Any]?,
                                           error errorOut: inout NSError?) {

        var audioSettings = audioSettings
        if audioSettings == nil {
            print("No audio settings provided, using default settings")
            audioSettings = [AVFormatIDKey: kAudioFormatMPEG4AAC]
        }

        guard let audioSettings = audioSettings else { return }

        if assetWriter?.canApply(outputSettings: audioSettings, forMediaType: .audio) == true {
            audioInput = AVAssetWriterInput(mediaType: .audio,
                                          outputSettings: audioSettings,
                                          sourceFormatHint: audioFormatDescription)
            audioInput?.expectsMediaDataInRealTime = true

            if assetWriter?.canAdd(audioInput!) == true {
                assetWriter?.add(audioInput!)
            } else {
                errorOut = MovieRecorder.cannotSetupInputError()
            }
        } else {
            errorOut = MovieRecorder.cannotSetupInputError()
        }
    }

    private func setupAssetWriterVideoInput(withSourceFormatDescription videoFormatDescription: CMFormatDescription,
                                           transform: CGAffineTransform,
                                           settings videoSettings: [String: Any]?,
                                           error errorOut: inout NSError?) {

        var videoSettings = videoSettings

        if videoSettings == nil {
            print("No video settings provided, using default settings")

            let dimensions = CMVideoFormatDescriptionGetDimensions(videoFormatDescription)
            let numPixels = Int(dimensions.width) * Int(dimensions.height)
            let bitsPerPixel: Float
            let bitsPerSecond: Int

            // Assume that lower-than-SD resolutions are intended for streaming
            if numPixels < (640 * 480) {
                bitsPerPixel = 4.05 // Matches AVCaptureSessionPresetMedium or Low quality
            } else {
                bitsPerPixel = 10.1 // Matches AVCaptureSessionPresetHigh quality
            }

            bitsPerSecond = Int(Float(numPixels) * bitsPerPixel)

            let compressionProperties: [String: Any] = [
                AVVideoAverageBitRateKey: bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]

            videoSettings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: dimensions.width,
                AVVideoHeightKey: dimensions.height,
                AVVideoCompressionPropertiesKey: compressionProperties
            ]
        }

        guard let videoSettings = videoSettings else { return }

        if assetWriter?.canApply(outputSettings: videoSettings, forMediaType: .video) == true {
            videoInput = AVAssetWriterInput(mediaType: .video,
                                          outputSettings: videoSettings,
                                          sourceFormatHint: videoFormatDescription)
            videoInput?.expectsMediaDataInRealTime = true
            videoInput?.transform = transform

            if assetWriter?.canAdd(videoInput!) == true {
                assetWriter?.add(videoInput!)
            } else {
                errorOut = MovieRecorder.cannotSetupInputError()
            }
        } else {
            errorOut = MovieRecorder.cannotSetupInputError()
        }
    }

    private static func cannotSetupInputError() -> NSError {
        let localizedDescription = NSLocalizedString("Recording cannot be started", comment: "")
        let localizedFailureReason = NSLocalizedString("Cannot setup asset writer input.", comment: "")
        let errorDict: [String: Any] = [
            NSLocalizedDescriptionKey: localizedDescription,
            NSLocalizedFailureReasonErrorKey: localizedFailureReason
        ]
        return NSError(domain: "com.apple.dts.samplecode", code: 0, userInfo: errorDict)
    }

    private func teardownAssetWriterAndInputs() {
        videoInput = nil
        audioInput = nil
        assetWriter = nil
    }
}

// MARK: - CMFormatDescription Extension

private extension CMFormatDescription {
    func retained() -> CMFormatDescription {
        return (self as CMFormatDescription).retain()
    }

    func release() {
        (self as CMFormatDescription).release()
    }
}

// MARK: - CMSampleBuffer Extension

private extension CMSampleBuffer {
    func retain() {
        CMSampleBufferRetain(self)
    }

    func release() {
        CMSampleBufferRelease(self)
    }
}
