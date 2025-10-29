import Foundation
import AWSClientRuntime
import AWSS3

struct AWSConfig {
    
    // MARK: - Configuration Keys
    
    private enum ConfigKeys {
        static let bucketName = "AWS_S3_BUCKET_NAME"
        static let region = "AWS_REGION"
        static let accessKeyId = "AWS_ACCESS_KEY_ID"
        static let secretAccessKey = "AWS_SECRET_ACCESS_KEY"
    }
    
    // MARK: - Default Values
    
    struct Defaults {
        static let bucketName = "mars-logger-bucket"
        static let region = "us-east-1"
    }
    
    // MARK: - Configuration Properties
    
    static var bucketName: String {
        return Bundle.main.object(forInfoDictionaryKey: ConfigKeys.bucketName) as? String 
            ?? ProcessInfo.processInfo.environment[ConfigKeys.bucketName] 
            ?? Defaults.bucketName
    }
    
    static var region: String {
        return Bundle.main.object(forInfoDictionaryKey: ConfigKeys.region) as? String 
            ?? ProcessInfo.processInfo.environment[ConfigKeys.region] 
            ?? Defaults.region
    }
    
    static var accessKeyId: String? {
        return Bundle.main.object(forInfoDictionaryKey: ConfigKeys.accessKeyId) as? String 
            ?? ProcessInfo.processInfo.environment[ConfigKeys.accessKeyId]
    }
    
    static var secretAccessKey: String? {
        return Bundle.main.object(forInfoDictionaryKey: ConfigKeys.secretAccessKey) as? String 
            ?? ProcessInfo.processInfo.environment[ConfigKeys.secretAccessKey]
    }
    
    // MARK: - Validation
    
    static func validateConfiguration() -> (isValid: Bool, missingKeys: [String]) {
        var missingKeys: [String] = []
        
        if accessKeyId?.isEmpty != false {
            missingKeys.append("AWS Access Key ID")
        }
        
        if secretAccessKey?.isEmpty != false {
            missingKeys.append("AWS Secret Access Key")
        }
        
        return (missingKeys.isEmpty, missingKeys)
    }
    
    // MARK: - Helper Methods
    
    // MARK: - Configuration Info
    
    static func printConfiguration() {
        print("=== AWS Configuration ===")
        print("Bucket Name: \(bucketName)")
        print("Region: \(region)")
        print("Access Key ID: \(accessKeyId?.prefix(8) ?? "Not Set")...")
        print("Secret Access Key: \(secretAccessKey != nil ? "Set" : "Not Set")")
        
        let validation = validateConfiguration()
        if validation.isValid {
            print("Configuration is valid")
        } else {
            print("Missing configuration: \(validation.missingKeys.joined(separator: ", "))")
        }
        print("========================")
    }
}
