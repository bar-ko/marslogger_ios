import Foundation
import CoreMedia
import CoreMotion

let VIDEOSNAKE_REMAPPED_PTS = "RemappedPTS" as CFString
let kSecToNanos: Int32 = 1000000000

// MARK: - Global Functions

func getAttachmentTime(_ mediaSample: CMSampleBuffer) -> CMTime {
    let mediaTimeDict = CMGetAttachment(mediaSample, key: VIDEOSNAKE_REMAPPED_PTS, attachmentModeOut: nil) as? NSDictionary
    let mediaTime = mediaTimeDict != nil ? CMTimeMakeFromDictionary(mediaTimeDict! as CFDictionary) : CMSampleBufferGetPresentationTimeStamp(mediaSample)
    return mediaTime
}

func CMTimeGetNanoseconds(_ time: CMTime) -> Int64 {
    let timenano = CMTimeConvertScale(time, timescale: kSecToNanos, method: .default)
    return timenano.value
}

func CMTimeGetMilliseconds(_ time: CMTime) -> Int64 {
    let timenano = CMTimeConvertScale(time, timescale: 1000, method: .default)
    return timenano.value
}

func secDoubleToNanoString(_ time: Double) -> String {
    var integral: Double = 0
    let fractional = modf(time, &integral) * Double(kSecToNanos)
    return String(format: "%.0f%09.0f", integral, fractional)
}

func secDoubleToDateTimeString(_ time: Double) -> String {
    let date = Date(timeIntervalSince1970: time)
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
    dateFormatter.timeZone = TimeZone.current
    return dateFormatter.string(from: date)
}

func CMTimeForNSDate(_ date: Date) -> CMTime {
    let now = CMClockGetTime(CMClockGetHostTimeClock())
    let elapsed = -date.timeIntervalSinceNow // this will be a negative number if date was in the past (it should be).
    let eventTime = CMTimeSubtract(now, CMTimeMake(value: Int64(elapsed * Double(now.timescale)), timescale: now.timescale))
    return eventTime
}

func NSDateToString(_ date: Date) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy_MM_dd_HH_mm_ss.SSS"
    // Optionally for time zone conversions
    // dateFormatter.timeZone = TimeZone(identifier: "...")
    return dateFormatter.string(from: date)
}

// MARK: - VideoTimeConverter

class VideoTimeConverter: NSObject {
    
    // MARK: - Properties
    
    var sampleBufferClock: CMClock?
    private var motionClock: CMClock
    
    // MARK: - Initialization
    
    override init() {
        self.motionClock = CMClockGetHostTimeClock()
        super.init()
    }
    
    // MARK: - Methods
    
    func checkStatus() {
        guard sampleBufferClock != nil else {
            fatalError("No sample buffer clock. Please set one before calling start.")
        }
    }
    
    func convertSampleBufferTimeToMotionClock(_ sampleBuffer: CMSampleBuffer) {
        let originalPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var remappedPTS = originalPTS
        
        if let sampleBufferClock = sampleBufferClock {
            if !CFEqual(sampleBufferClock, motionClock) {
                remappedPTS = CMSyncConvertTime(originalPTS, from: sampleBufferClock, to: motionClock)
            }
        }
        
        // Attach the remapped timestamp to the buffer for use in -sync
        let remappedPTSDict = CMTimeCopyAsDictionary(remappedPTS, allocator: kCFAllocatorDefault)
        CMSetAttachment(sampleBuffer, key: VIDEOSNAKE_REMAPPED_PTS, value: remappedPTSDict, attachmentMode: kCMAttachmentMode_ShouldPropagate)
    }
    
    func movieTimeForLocationTime(_ date: Date) -> CMTime {
        let locationTime = CMTimeForNSDate(date)
        guard let sampleBufferClock = sampleBufferClock else {
            return locationTime
        }
        let locationMovieTime = CMSyncConvertTime(locationTime, from: CMClockGetHostTimeClock(), to: sampleBufferClock)
        return locationMovieTime
    }
}
