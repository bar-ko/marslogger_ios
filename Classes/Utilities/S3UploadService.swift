import Foundation
import AWSS3
import AWSClientRuntime
import ClientRuntime
import AWSSDKIdentity

protocol S3UploadDelegate: AnyObject {
    func s3Upload(_ service: S3UploadService, didCompleteUpload key: String, location: String)
    func s3Upload(_ service: S3UploadService, didFailWithError error: Error, forKey key: String)
    func s3Upload(_ service: S3UploadService, didUpdateProgress progress: Float, forKey key: String)
}

final class S3UploadService {
    
    static let shared = S3UploadService()
    
    private var client: S3Client
    private let bucket: String
    private var activeTasks: [String: Task<Void, Never>] = [:]
    weak var delegate: S3UploadDelegate?
    
    private init() {
        self.bucket = AWSConfig.bucketName
        
        // Print configuration for debugging
        AWSConfig.printConfiguration()
        
        do {
            // Set environment variables for AWS credentials
            if let accessKey = AWSConfig.accessKeyId, let secretKey = AWSConfig.secretAccessKey {
                setenv("AWS_ACCESS_KEY_ID", accessKey, 1)
                setenv("AWS_SECRET_ACCESS_KEY", secretKey, 1)
            }
            
            let config = try S3Client.S3ClientConfiguration(region: AWSConfig.region)
            self.client = S3Client(config: config)
        } catch {
            fatalError("Failed to initialize S3Client: \(error)")
        }
    }
    
    func uploadVideo(at fileURL: URL, withUUID uuid: String) {
        let key = "mars_data/video/\(uuid).mp4"
        uploadFile(at: fileURL, withKey: key, contentType: "video/mp4")
    }
    
    func uploadInertialData(at fileURL: URL, withUUID uuid: String) {
        let key = "mars_data/data/\(uuid).csv"
        uploadFile(at: fileURL, withKey: key, contentType: "text/csv")
    }
    
    func uploadJSON(at fileURL: URL, withUUID uuid: String) {
        let key = "mars_data/task/\(uuid).json"
        uploadFile(at: fileURL, withKey: key, contentType: "application/json")
    }
    
    private func uploadFile(at fileURL: URL, withKey key: String, contentType: String) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            delegate?.s3Upload(
                self,
                didFailWithError: NSError(domain: "S3UploadService", code: 404, userInfo: [
                    NSLocalizedDescriptionKey: "File not found: \(fileURL.path)"
                ]),
                forKey: key
            )
            return
        }
        
        let task = Task.detached { [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: fileURL)
                
                let putObjectInput = PutObjectInput(
                    body: .data(data),
                    bucket: self.bucket,
                    contentType: contentType,
                    key: key,
                    metadata: [
                        "uploaded-by": "mars-logger-ios",
                        "upload-timestamp": ISO8601DateFormatter().string(from: Date())
                    ]
                )
                
                let response = try await self.client.putObject(input: putObjectInput)
                
                DispatchQueue.main.async {
                    self.delegate?.s3Upload(self, didCompleteUpload: key, location: "s3://\(self.bucket)/\(key)")
                }
                
                // Remove completed task
                self.activeTasks.removeValue(forKey: key)
                
                print("Upload complete: \(response)")
            } catch {
                DispatchQueue.main.async {
                    self.delegate?.s3Upload(self, didFailWithError: error, forKey: key)
                }
                
                // Remove failed task
                self.activeTasks.removeValue(forKey: key)
                
                print("Upload failed for \(key): \(error.localizedDescription)")
            }
        }
        
        activeTasks[key] = task
    }
    
    
    func cancelUpload(forKey key: String) {
        activeTasks[key]?.cancel()
        activeTasks.removeValue(forKey: key)
    }
    
    func cancelAllUploads() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
    }
    
    func activeUploadCount() -> Int {
        return activeTasks.count
    }
    
    func cleanupFiles(videoURL: URL?, inertialDataURL: URL?, jsonURL: URL?) {
        // Clean up video file
        if let videoURL = videoURL {
            try? FileManager.default.removeItem(at: videoURL)
            print("Cleaned up video file: \(videoURL.path)")
        }
        
        // Clean up inertial data file and its parent folder if empty
        if let inertialDataURL = inertialDataURL {
            let parentFolder = inertialDataURL.deletingLastPathComponent()
            
            try? FileManager.default.removeItem(at: inertialDataURL)
            print("Cleaned up inertial data file: \(inertialDataURL.path)")
            
            // Try to remove parent folder if it's empty
            removeEmptyFolder(at: parentFolder)
        }
        
        // Clean up JSON file
        if let jsonURL = jsonURL {
            try? FileManager.default.removeItem(at: jsonURL)
            print("Cleaned up JSON file: \(jsonURL.path)")
        }
    }
    
    private func removeEmptyFolder(at folderURL: URL) {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
            
            // If folder is empty, remove it
            if contents.isEmpty {
                try FileManager.default.removeItem(at: folderURL)
                print("Removed empty folder: \(folderURL.path)")
            } else {
                print("Folder not empty, keeping: \(folderURL.path)")
            }
        } catch {
            print("Could not check/remove folder \(folderURL.path): \(error.localizedDescription)")
        }
    }
}
