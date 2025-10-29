import Foundation
import AVFoundation
import CoreMedia

let kDesiredExposureTimeMillisec: Int64 = 5

func computeExpectedExposureTimeAndIso(format: AVCaptureDevice.Format,
                                      oldDuration: CMTime,
                                      oldISO: Float,
                                      expectedDuration: inout CMTime,
                                      expectedISO: inout Float) {
    // eg., for iphone 6S format.minExposureDuration 1e-2 ms
    // format.maxExposureDuration 333.3 ms format.minISO 23 format.maxISO 736
    let desiredDuration = CMTimeMake(value: kDesiredExposureTimeMillisec, timescale: 1000)
    let ratio = Float(CMTimeGetSeconds(oldDuration) / CMTimeGetSeconds(desiredDuration))
    
    print("Present exposure duration \(String(format: "%.5f", CMTimeGetSeconds(oldDuration) * 1000)) ms and ISO \(String(format: "%.5f", oldISO))")
    
    if CMTimeCompare(desiredDuration, oldDuration) == 1 { // desiredDuration > oldDuration
        expectedDuration = oldDuration
        expectedISO = oldISO
    } else {
        expectedDuration = desiredDuration
        expectedISO = oldISO * ratio
        if expectedISO > format.maxISO {
            expectedISO = format.maxISO
        } else if expectedISO < format.minISO {
            expectedISO = format.minISO
        }
    }
    
    print("Camera old exposure duration \(String(format: "%.5f", CMTimeGetSeconds(oldDuration))) and ISO \(String(format: "%.3f", oldISO)), desired exposure duration \(String(format: "%.5f", CMTimeGetSeconds(expectedDuration))) and ISO \(String(format: "%.3f", expectedISO)) and ratio \(String(format: "%.3f", ratio))")
}
