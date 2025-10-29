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
    
    func uploadVideo(at fileURL: URL, withKey key: String? = nil) {
        uploadFile(at: fileURL, withKey: key ?? generateVideoKey(from: fileURL), contentType: "video/quicktime")
    }
    
    func uploadMetadata(at fileURL: URL, withKey key: String? = nil) {
        uploadFile(at: fileURL, withKey: key ?? generateMetadataKey(from: fileURL), contentType: "text/csv")
    }
    
    func uploadInertialData(at fileURL: URL, withKey key: String? = nil) {
        uploadFile(at: fileURL, withKey: key ?? generateInertialDataKey(from: fileURL), contentType: "text/csv")
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
    
    private func generateVideoKey(from fileURL: URL) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return "videos/\(timestamp)/\(fileURL.lastPathComponent)"
    }
    
    private func generateMetadataKey(from fileURL: URL) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return "metadata/\(timestamp)/\(fileURL.lastPathComponent)"
    }
    
    private func generateInertialDataKey(from fileURL: URL) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return "inertial-data/\(timestamp)/\(fileURL.lastPathComponent)"
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
}
