import Foundation
import AVFoundation
import CoreMedia
import Photos

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

/**
 Warn: This function does not return meaningful path at the moment.
 */
func getAssetPath(_ assetLocalIdentifier: String) -> String? {
    // see: https://stackoverflow.com/questions/27854937/ios8-photos-framework-how-to-get-the-nameor-filename-of-a-phasset
    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetLocalIdentifier], options: nil)
    
    guard fetchResult.count > 0 else { return nil }
    
    let asset = fetchResult.lastObject
    var path: String?
    
    if let asset = asset {
        // get photo info from this asset
        // for iOS 8
        let imageRequestOptions = PHImageRequestOptions()
        imageRequestOptions.isSynchronous = true
        
        // Warn: Because by default, requestImageDataForAsset method executes asynchronously, the following way to pass out path will not work.
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: imageRequestOptions) { (imageData, dataUTI, orientation, info) in
            if let info = info,
               let fileURL = info["PHImageFileURLKey"] as? URL {
                // path looks like this -
                // file:///var/mobile/Media/DCIM/###APPLE/IMG_####.JPG
                path = FileManager.default.displayName(atPath: fileURL.path)
                print("PHImageFile path \(path ?? "")")
            }
        }
        
        // for iOS 9+
        // https://stackoverflow.com/questions/32687403/phasset-get-original-file-name/32706194
        // this path looks like "Movie.MP4"
        let resources = PHAssetResource.assetResources(for: asset)
        if !resources.isEmpty {
            path = resources[0].originalFilename
        }
    }
    
    return path
}
