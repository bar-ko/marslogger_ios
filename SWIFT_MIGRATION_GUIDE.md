# Swift Migration Guide for MarsLogger iOS

## Overview
This document tracks the migration of the MarsLogger iOS project from Objective-C to Swift.

## Migration Status

### ✅ Completed Files

1. **InertialRecorder** (Classes/InertialRecorder.swift)
   - Migrated from InertialRecorder.h/.m
   - Includes NodeWrapper and GPSNodeWrapper classes
   - All GPS and IMU recording functionality preserved
   - Global helper functions: getFileURL(), createOutputFolderURL()

2. **VideoTimeConverter** (Classes/Utilities/VideoTimeConverter.swift)
   - Migrated from VideoTimeConverter.h/.m
   - All time conversion utilities preserved
   - Global functions: CMTimeGetNanoseconds(), secDoubleToNanoString(), etc.

3. **RosyWriterAppDelegate** (Classes/RosyWriterAppDelegate.swift)
   - Migrated from RosyWriterAppDelegate.h/.m
   - Uses @main attribute for Swift app entry point
   - No need for separate main.m file in Swift

4. **RosyWriterViewController** (Classes/RosyWriterViewController.swift)
   - Main view controller for camera interface
   - Includes tap-to-focus, recording controls, email export
   - Helper extension for coordinate conversion
   - All gesture recognizers and UI actions migrated

5. **RosyWriterCapturePipeline** (Classes/RosyWriterCapturePipeline.swift)
   - Complete AVCaptureSession management
   - Video/audio capture and recording
   - Focus and exposure control
   - Frame rate calculation and metadata export

8. **OpenGLPixelBufferView** (Classes/Utilities/OpenGLPixelBufferView.swift)
   - **COMPLETED**: Full OpenGL ES implementation migrated
   - Real-time camera preview with proper shaders
   - Texture cache management and aspect ratio handling
   - Framebuffer and renderbuffer setup
   - Shader compilation utilities included

### ⏳ Pending Migration (Optional/Advanced)

The following files have stub implementations but may need full migration for production use:

#### Renderers (Currently Stubbed)
- RosyWriterOpenGLRenderer.h/.m - Full OpenGL implementation
- RosyWriterCIFilterRenderer.h/.m - Full Core Image implementation
- RosyWriterCPURenderer.h/.m - Full CPU-based rendering
- RosyWriterOpenCVRenderer.h - OpenCV integration (if needed)

#### Utilities (Currently Stubbed)
- ShaderUtilities.h (C header) - May need bridging
- matrix.h (C header) - May need bridging

## Key Migration Patterns

### Memory Management
- **Objective-C**: Manual retain/release, ARC
- **Swift**: Automatic reference counting with `weak` and `unowned`

### Optionals
- **Objective-C**: `nil` checks
- **Swift**: Optional types with `?` and `!`, guard statements, optional binding

### Protocols
- **Objective-C**: `@protocol` with `@required` and `@optional`
- **Swift**: `protocol` with default implementations via extensions

### Properties
- **Objective-C**: `@property (nonatomic, strong)`
- **Swift**: `var` with implicit strong reference, use `weak` when needed

### Blocks/Closures
- **Objective-C**: `^{ }` blocks
- **Swift**: `{ }` closures with capture lists `[weak self]`

### Enums
- **Objective-C**: C-style enums
- **Swift**: First-class types with associated values

### Error Handling
- **Objective-C**: NSError pointers
- **Swift**: `throws`, `do-catch`, `try?`, `try!`

## Xcode Project Configuration

### Required Changes

1. **Add Swift Bridging Header** (if mixing Swift and Objective-C)
   - Create `MarsLogger-Bridging-Header.h`
   - Import remaining Objective-C headers

2. **Update Build Settings**
   - Swift Language Version: Swift 5.0+
   - Enable module support
   - Update deployment target if needed

3. **Info.plist Updates**
   - Camera usage description
   - Location usage descriptions (When In Use, Always)
   - Microphone usage description

4. **Remove Objective-C Files** (after full migration)
   - Delete .h and .m files
   - Remove from Xcode project
   - Update imports in remaining files

## Testing Checklist

After migration, verify:
- [ ] Camera preview displays correctly
- [ ] Video recording starts/stops properly
- [ ] IMU data collection works
- [ ] GPS data collection works
- [ ] Tap-to-focus functionality
- [ ] Long-press to unlock focus
- [ ] Email export functionality
- [ ] Background recording
- [ ] Proper memory management (no leaks)
- [ ] UI updates on main thread

## Known Issues / Notes

1. **OpenGL/Metal**: OpenGLPixelBufferView may need significant refactoring for modern iOS
2. **C Headers**: ShaderUtilities.h and matrix.h may need wrapper or direct C interop
3. **Deprecated APIs**: UIAlertView should be replaced with UIAlertController (already done in Obj-C)
4. **Background Location**: Requires special entitlements and Info.plist keys

## Next Steps

1. Complete RosyWriterViewController migration
2. Migrate RosyWriterCapturePipeline (most complex class)
3. Migrate renderer classes
4. Migrate utility classes
5. Update Xcode project configuration
6. Comprehensive testing
7. Remove Objective-C files

## Resources

- [Swift Migration Guide](https://developer.apple.com/documentation/swift/migrating-your-objective-c-code-to-swift)
- [Swift Programming Language](https://docs.swift.org/swift-book/)
- [AVFoundation in Swift](https://developer.apple.com/av-foundation/)
