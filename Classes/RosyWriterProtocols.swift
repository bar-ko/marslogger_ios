/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample's licensing information

 Abstract:
 Swift protocols and stub implementations for RosyWriter components
 */

import Foundation
import CoreMedia
import CoreVideo
import AVFoundation

// MARK: - RosyWriterRenderer Protocol

protocol RosyWriterRenderer: AnyObject {

    // Format/Processing Requirements
    var operatesInPlace: Bool { get }
    var inputPixelFormat: FourCharCode { get }

    // Resource Lifecycle
    func prepareForInput(withFormatDescription inputFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int)
    func reset()

    // Rendering
    func copyRenderedPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer?

    // Optional
    var outputFormatDescription: CMFormatDescription? { get }
}

// MARK: - MovieRecorderDelegate Protocol

// MovieRecorderDelegate protocol is now defined in MovieRecorder.swift

// MARK: - Stub Renderer Implementations

class RosyWriterOpenGLRenderer: NSObject, RosyWriterRenderer {
    var operatesInPlace: Bool { return false }
    var inputPixelFormat: FourCharCode { return kCVPixelFormatType_32BGRA }
    var outputFormatDescription: CMFormatDescription?

    func prepareForInput(withFormatDescription inputFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
        print("OpenGLRenderer: prepareForInput called")
    }

    func reset() {
        print("OpenGLRenderer: reset called")
    }

    func copyRenderedPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        // Stub: just return the input buffer with retained reference
        return pixelBuffer
    }
}

class RosyWriterCPURenderer: NSObject, RosyWriterRenderer {
    var operatesInPlace: Bool { return true }
    var inputPixelFormat: FourCharCode { return kCVPixelFormatType_32BGRA }
    var outputFormatDescription: CMFormatDescription?

    func prepareForInput(withFormatDescription inputFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
        print("CPURenderer: prepareForInput called")
    }

    func reset() {
        print("CPURenderer: reset called")
    }

    func copyRenderedPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        // Stub: just return the input buffer with retained reference
        return pixelBuffer
    }
}

class RosyWriterCIFilterRenderer: NSObject, RosyWriterRenderer {
    var operatesInPlace: Bool { return false }
    var inputPixelFormat: FourCharCode { return kCVPixelFormatType_32BGRA }
    var outputFormatDescription: CMFormatDescription?

    func prepareForInput(withFormatDescription inputFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
        print("CIFilterRenderer: prepareForInput called")
    }

    func reset() {
        print("CIFilterRenderer: reset called")
    }

    func copyRenderedPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        // Stub: just return the input buffer with retained reference
        return pixelBuffer
    }
}

class RosyWriterOpenCVRenderer: NSObject, RosyWriterRenderer {
    var operatesInPlace: Bool { return false }
    var inputPixelFormat: FourCharCode { return kCVPixelFormatType_32BGRA }
    var outputFormatDescription: CMFormatDescription?

    func prepareForInput(withFormatDescription inputFormatDescription: CMFormatDescription, outputRetainedBufferCountHint: Int) {
        print("OpenCVRenderer: prepareForInput called")
    }

    func reset() {
        print("OpenCVRenderer: reset called")
    }

    func copyRenderedPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        // Stub: just return the input buffer with retained reference
        return pixelBuffer
    }
}

// MARK: - RosyWriterCapturePipelineDelegate Protocol

protocol RosyWriterCapturePipelineDelegate: AnyObject {
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, didStopRunningWithError error: Error)

    // Preview
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, previewPixelBufferReadyForDisplay previewPixelBuffer: CVPixelBuffer)
    func capturePipelineDidRunOutOfPreviewBuffers(_ capturePipeline: RosyWriterCapturePipeline)

    // Recording
    func capturePipelineRecordingDidStart(_ capturePipeline: RosyWriterCapturePipeline)
    func capturePipeline(_ capturePipeline: RosyWriterCapturePipeline, recordingDidFailWithError error: Error)
    func capturePipelineRecordingWillStop(_ capturePipeline: RosyWriterCapturePipeline)
    func capturePipelineRecordingDidStop(_ capturePipeline: RosyWriterCapturePipeline)
}

// MARK: - OpenGLPixelBufferView

// OpenGLPixelBufferView is fully implemented in OpenGLPixelBufferView.swift
// Import and use that class for camera preview functionality
