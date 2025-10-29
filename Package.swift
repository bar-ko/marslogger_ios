// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MarsLogger",
    platforms: [
        .iOS(.v12)
    ],
    products: [
        .library(
            name: "MarsLogger",
            targets: ["MarsLogger"]
        ),
    ],
    dependencies: [
        // AWS SDK for Swift
        .package(url: "https://github.com/awslabs/aws-sdk-swift", from: "0.20.0"),
    ],
    targets: [
        .target(
            name: "MarsLogger",
            dependencies: [
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .product(name: "AWSClientRuntime", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
            ],
            path: "Classes"
        ),
        .testTarget(
            name: "MarsLoggerTests",
            dependencies: ["MarsLogger"],
            path: "MarsLoggerTests"
        ),
    ]
)
