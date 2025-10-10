/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample's licensing information

 Abstract:
 OpenGL ES pixel buffer view for camera preview - Swift Implementation
 */

import Foundation
import UIKit
import CoreVideo
import OpenGLES
import QuartzCore

// MARK: - Shader Constants

let kPassThruVertex = """
attribute vec4 position;
attribute mediump vec4 texturecoordinate;
varying mediump vec2 coordinate;

void main() {
    gl_Position = position;
    coordinate = texturecoordinate.xy;
}
"""

let kPassThruFragment = """
varying highp vec2 coordinate;
uniform sampler2D videoframe;

void main() {
    gl_FragColor = texture2D(videoframe, coordinate);
}
"""

let ATTRIB_VERTEX: GLuint = 0
let ATTRIB_TEXTUREPOSITON: GLuint = 1
let NUM_ATTRIBUTES: Int = 2

// MARK: - OpenGLPixelBufferView

class OpenGLPixelBufferView: UIView {

    // MARK: - Private Properties

    private var oglContext: EAGLContext?
    private var textureCache: CVOpenGLESTextureCache?
    private var width: GLint = 0
    private var height: GLint = 0
    private var frameBufferHandle: GLuint = 0
    private var colorBufferHandle: GLuint = 0
    private var program: GLuint = 0
    private var frameUniform: GLint = 0

    // MARK: - UIView Overrides

    override class var layerClass: AnyClass {
        return CAEAGLLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        // Set up content scale factor for native screen resolution
        if #available(iOS 8.0, *) {
            if UIScreen.instancesRespond(to: #selector(getter: UIScreen.nativeScale)) {
                contentScaleFactor = UIScreen.main.nativeScale
            } else {
                contentScaleFactor = UIScreen.main.scale
            }
        } else {
            contentScaleFactor = UIScreen.main.scale
        }

        // Initialize OpenGL ES 2.0
        guard let eaglLayer = layer as? CAEAGLLayer else { return }
        eaglLayer.isOpaque = true
        eaglLayer.drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        ]

        oglContext = EAGLContext(api: .openGLES2)
        if oglContext == nil {
            print("Problem with OpenGL context.")
        }
    }

    deinit {
        reset()
    }

    // MARK: - Public Methods

    func displayPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        let squareVertices: [GLfloat] = [
            -1.0, -1.0, // bottom left
             1.0, -1.0, // bottom right
            -1.0,  1.0, // top left
             1.0,  1.0  // top right
        ]

        let oldContext = EAGLContext.current()
        if oldContext !== oglContext {
            guard EAGLContext.setCurrent(oglContext) else {
                fatalError("Problem with OpenGL context")
            }
        }

        if frameBufferHandle == 0 {
            guard initializeBuffers() else {
                print("Problem initializing OpenGL buffers.")
                return
            }
        }

        // Create CVOpenGLESTexture from CVPixelBuffer
        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)

        var texture: CVOpenGLESTexture?
        let err = CVOpenGLESTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            GLenum(GL_TEXTURE_2D),
            GL_RGBA,
            GLsizei(frameWidth),
            GLsizei(frameHeight),
            GLenum(GL_BGRA),
            GLenum(GL_UNSIGNED_BYTE),
            0,
            &texture
        )

        guard let texture = texture, err == kCVReturnSuccess else {
            print("CVOpenGLESTextureCacheCreateTextureFromImage failed (error: \(err))")
            return
        }

        // Set viewport
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBufferHandle)
        glViewport(0, 0, width, height)

        glUseProgram(program)
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(CVOpenGLESTextureGetTarget(texture), CVOpenGLESTextureGetName(texture))
        glUniform1i(frameUniform, 0)

        // Set texture parameters
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLint(GLenum(GL_CLAMP_TO_EDGE)))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLint(GLenum(GL_CLAMP_TO_EDGE)))

        // Set vertex attributes
        glVertexAttribPointer(ATTRIB_VERTEX, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 0, squareVertices)
        glEnableVertexAttribArray(ATTRIB_VERTEX)

        // Calculate texture sampling size to preserve aspect ratio
        let cropScaleAmount = CGSize(
            width: bounds.width / CGFloat(frameWidth),
            height: bounds.height / CGFloat(frameHeight)
        )

        let textureSamplingSize: CGSize
        if cropScaleAmount.height > cropScaleAmount.width {
            textureSamplingSize = CGSize(
                width: bounds.width / (CGFloat(frameWidth) * cropScaleAmount.height),
                height: 1.0
            )
        } else {
            textureSamplingSize = CGSize(
                width: 1.0,
                height: bounds.height / (CGFloat(frameHeight) * cropScaleAmount.width)
            )
        }

        // Create texture coordinates with vertical flip
        // CVPixelBuffers have top-left origin, OpenGL has bottom-left origin
        let passThroughTextureVertices: [GLfloat] = [
            (1.0 - GLfloat(textureSamplingSize.width)) / 2.0, (1.0 + GLfloat(textureSamplingSize.height)) / 2.0, // top left
            (1.0 + GLfloat(textureSamplingSize.width)) / 2.0, (1.0 + GLfloat(textureSamplingSize.height)) / 2.0, // top right
            (1.0 - GLfloat(textureSamplingSize.width)) / 2.0, (1.0 - GLfloat(textureSamplingSize.height)) / 2.0, // bottom left
            (1.0 + GLfloat(textureSamplingSize.width)) / 2.0, (1.0 - GLfloat(textureSamplingSize.height)) / 2.0  // bottom right
        ]

        glVertexAttribPointer(ATTRIB_TEXTUREPOSITON, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), 0, passThroughTextureVertices)
        glEnableVertexAttribArray(ATTRIB_TEXTUREPOSITON)

        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)

        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)
        oglContext?.presentRenderbuffer(Int(GL_RENDERBUFFER))

        glBindTexture(CVOpenGLESTextureGetTarget(texture), 0)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        // CVOpenGLESTexture is automatically managed by ARC in Swift

        if oldContext !== oglContext {
            EAGLContext.setCurrent(oldContext)
        }
    }

    func flushPixelBufferCache() {
        if let textureCache = textureCache {
            CVOpenGLESTextureCacheFlush(textureCache, 0)
        }
    }

    func reset() {
        let oldContext = EAGLContext.current()
        if oldContext !== oglContext {
            guard EAGLContext.setCurrent(oglContext) else {
                fatalError("Problem with OpenGL context")
            }
        }

        if frameBufferHandle != 0 {
            glDeleteFramebuffers(1, &frameBufferHandle)
            frameBufferHandle = 0
        }

        if colorBufferHandle != 0 {
            glDeleteRenderbuffers(1, &colorBufferHandle)
            colorBufferHandle = 0
        }

        if program != 0 {
            glDeleteProgram(program)
            program = 0
        }

        if textureCache != nil {
            // CVOpenGLESTextureCache is automatically managed by ARC in Swift
            textureCache = nil
        }

        if oldContext !== oglContext {
            EAGLContext.setCurrent(oldContext)
        }
    }

    // MARK: - Private Methods

    private func initializeBuffers() -> Bool {
        glDisable(GLenum(GL_DEPTH_TEST))

        glGenFramebuffers(1, &frameBufferHandle)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), frameBufferHandle)

        glGenRenderbuffers(1, &colorBufferHandle)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorBufferHandle)

        oglContext?.renderbufferStorage(Int(GL_RENDERBUFFER), from: layer as! CAEAGLLayer)

        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &width)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &height)

        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorBufferHandle)

        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            print("Failure with framebuffer generation")
            reset()
            return false
        }

        // Create CVOpenGLESTexture cache
        var cache: CVOpenGLESTextureCache?
        let err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, nil, oglContext!, nil, &cache)
        textureCache = cache

        guard err == kCVReturnSuccess else {
            print("Error at CVOpenGLESTextureCacheCreate \(err)")
            reset()
            return false
        }

        // Create shader program
        let attribLocations: [GLint] = [GLint(ATTRIB_VERTEX), GLint(ATTRIB_TEXTUREPOSITON)]
        let attribNames: [UnsafePointer<GLchar>?] = [
            ("position" as NSString).utf8String,
            ("texturecoordinate" as NSString).utf8String
        ]

        let status = attribNames.withUnsafeBufferPointer { attribNamesBuffer in
            glueCreateProgram(
                kPassThruVertex,
                kPassThruFragment,
                GLsizei(NUM_ATTRIBUTES),
                attribNamesBuffer.baseAddress,
                attribLocations,
                0, nil, nil, // no uniforms
                &program
            )
        }

        guard status != 0, program != 0 else {
            print("Error creating the program")
            reset()
            return false
        }

        frameUniform = glueGetUniformLocation(program, "videoframe")

        return true
    }
}

// MARK: - Shader Utilities

private func glueCompileShader(_ target: GLenum, _ count: GLsizei, _ sources: UnsafePointer<UnsafePointer<GLchar>>, _ shader: UnsafeMutablePointer<GLuint>) -> GLint {
    var status: GLint = 0

    shader.pointee = glCreateShader(target)
    glShaderSource(shader.pointee, count, unsafeBitCast(sources, to: UnsafePointer<UnsafePointer<GLchar>?>?.self), nil)
    glCompileShader(shader.pointee)

    #if DEBUG
    var logLength: GLint = 0
    glGetShaderiv(shader.pointee, GLenum(GL_INFO_LOG_LENGTH), &logLength)
    if logLength > 0 {
        let log = UnsafeMutablePointer<GLchar>.allocate(capacity: Int(logLength))
        glGetShaderInfoLog(shader.pointee, logLength, &logLength, log)
        print("Shader compile log:\n\(String(cString: log))")
        log.deallocate()
    }
    #endif

    glGetShaderiv(shader.pointee, GLenum(GL_COMPILE_STATUS), &status)
    if status == 0 {
        print("Failed to compile shader")
    }

    return status
}

private func glueLinkProgram(_ program: GLuint) -> GLint {
    var status: GLint = 0

    glLinkProgram(program)

    #if DEBUG
    var logLength: GLint = 0
    glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), &logLength)
    if logLength > 0 {
        let log = UnsafeMutablePointer<GLchar>.allocate(capacity: Int(logLength))
        glGetProgramInfoLog(program, logLength, &logLength, log)
        print("Program link log:\n\(String(cString: log))")
        log.deallocate()
    }
    #endif

    glGetProgramiv(program, GLenum(GL_LINK_STATUS), &status)
    if status == 0 {
        print("Failed to link program \(program)")
    }

    return status
}

private func glueValidateProgram(_ program: GLuint) -> GLint {
    var status: GLint = 0

    glValidateProgram(program)

    #if DEBUG
    var logLength: GLint = 0
    glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), &logLength)
    if logLength > 0 {
        let log = UnsafeMutablePointer<GLchar>.allocate(capacity: Int(logLength))
        glGetProgramInfoLog(program, logLength, &logLength, log)
        print("Program validate log:\n\(String(cString: log))")
        log.deallocate()
    }
    #endif

    glGetProgramiv(program, GLenum(GL_VALIDATE_STATUS), &status)
    if status == 0 {
        print("Failed to validate program \(program)")
    }

    return status
}

private func glueGetUniformLocation(_ program: GLuint, _ uniformName: UnsafePointer<GLchar>) -> GLint {
    return glGetUniformLocation(program, uniformName)
}

private func glueCreateProgram(_ vertSource: String, _ fragSource: String,
                              _ attribNameCt: GLsizei, _ attribNames: UnsafePointer<UnsafePointer<GLchar>?>?,
                              _ attribLocations: [GLint],
                              _ uniformNameCt: GLsizei, _ uniformNames: UnsafePointer<UnsafePointer<GLchar>?>?,
                              _ uniformLocations: UnsafeMutablePointer<GLint>?,
                              _ program: UnsafeMutablePointer<GLuint>) -> GLint {

    var vertShader: GLuint = 0
    var fragShader: GLuint = 0
    var prog: GLuint = 0
    var status: GLint = 1

    // Create shader program
    prog = glCreateProgram()

    // Create and compile vertex shader
    vertSource.withCString { vertPtr in
        var sources = [vertPtr]
        sources.withUnsafeBufferPointer { sourcesBuffer in
            status *= glueCompileShader(GLenum(GL_VERTEX_SHADER), 1, sourcesBuffer.baseAddress!, &vertShader)
        }
    }

    // Create and compile fragment shader
    fragSource.withCString { fragPtr in
        var sources = [fragPtr]
        sources.withUnsafeBufferPointer { sourcesBuffer in
            status *= glueCompileShader(GLenum(GL_FRAGMENT_SHADER), 1, sourcesBuffer.baseAddress!, &fragShader)
        }
    }

    // Attach shaders
    glAttachShader(prog, vertShader)
    glAttachShader(prog, fragShader)

    // Bind attribute locations
    if let attribNames = attribNames {
        for i in 0..<Int(attribNameCt) {
            let namePtr = attribNames[i]
            if let name = namePtr, strlen(name) > 0 {
                glBindAttribLocation(prog, GLuint(attribLocations[i]), name)
            }
        }
    }

    // Link program
    status *= glueLinkProgram(prog)

    // Get uniform locations
    if status != 0 {
        if let uniformNames = uniformNames, let uniformLocations = uniformLocations {
            for i in 0..<Int(uniformNameCt) {
                let namePtr = uniformNames[i]
                if let name = namePtr, strlen(name) > 0 {
                    uniformLocations[i] = glueGetUniformLocation(prog, name)
                }
            }
        }
        program.pointee = prog
    }

    // Clean up shaders
    if vertShader != 0 {
        glDeleteShader(vertShader)
    }
    if fragShader != 0 {
        glDeleteShader(fragShader)
    }

    return status
}
