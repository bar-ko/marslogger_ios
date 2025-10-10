import UIKit

private func clearScenePersistenceEarly() {
    let fileManager = FileManager.default
    if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        let sceneSessionDir = appSupport.appendingPathComponent("com.apple.uikit/sceneSession")
        if fileManager.fileExists(atPath: sceneSessionDir.path) {
            do {
                try fileManager.removeItem(at: sceneSessionDir)
                print("🧹Early cleared corrupted sceneSession data at \(sceneSessionDir.path)")
            } catch {
                print("Failed to clear sceneSession data: \(error)")
            }
        }
    }
}

clearScenePersistenceEarly()

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(RosyWriterAppDelegate.self)
)
