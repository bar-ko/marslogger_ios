/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample's licensing information

 Abstract:
 Application delegate for MarsLogger iOS app
 */

import AVFoundation
import CoreLocation
import Photos
import UIKit

class RosyWriterAppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    // Location manager for background location updates
    private var locationManager: CLLocationManager?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication
            .LaunchOptionsKey: Any]?
    ) -> Bool {
        // Configure the application
        setupAppearance()
        setupLocationManager()

        // Check permissions on launch
        checkPermissions()

        print("MarsLogger App launched successfully")
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state.
        // This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message)
        // or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates.
        print("App will resign active")
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers,
        // and store enough application state information to restore your application to its current state
        // in case it is terminated later.
        print("App did enter background")
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the inactive state;
        // here you can undo many of the changes made on entering the background.
        print("App will enter foreground")
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive.
        // If the application was previously in the background, optionally refresh the user interface.
        print("App did become active")
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate.
        // Save data if appropriate. See also applicationDidEnterBackground:.
        print("App will terminate")
    }

    // MARK: - Background Location

    func application(
        _ application: UIApplication,
        didChangeStatusBarOrientation oldStatusBarOrientation:
            UIInterfaceOrientation
    ) {
        // Called when the status bar orientation changes
        print("Status bar orientation changed")
    }

    // MARK: - Private Methods

    private func setupAppearance() {
        // Configure global appearance
        UINavigationBar.appearance().tintColor = .systemBlue
        UITabBar.appearance().tintColor = .systemBlue
    }

    private func setupLocationManager() {
        locationManager = CLLocationManager()
        locationManager?.delegate = self

        // Configure for maximum accuracy and background updates
        locationManager?.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager?.distanceFilter = kCLDistanceFilterNone
        locationManager?.pausesLocationUpdatesAutomatically = false
        locationManager?.allowsBackgroundLocationUpdates = true
    }

    private func checkPermissions() {
        // Check camera permission
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        print("Camera permission status: \(cameraStatus.rawValue)")

        // Check location permission
        let locationStatus = CLLocationManager.authorizationStatus()
        print("Location permission status: \(locationStatus.rawValue)")

        // Check photo library permission (iOS 14+)
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus()
            print("Photo library permission status: \(status.rawValue)")
            if status != .authorized {
                PHPhotoLibrary.requestAuthorization { status in
                    if status != .authorized {
                        let accessDescription =
                            Bundle.main.object(
                                forInfoDictionaryKey:
                                    "NSPhotoLibraryUsageDescription"
                            ) as? String ?? ""

                        let alertController = UIAlertController(
                            title: accessDescription,
                            message:
                                "To give permissions tap on 'Change Settings' button",
                            preferredStyle: .alert
                        )

                        alertController.addAction(
                            UIAlertAction(
                                title: "Cancel",
                                style: .cancel,
                                handler: nil
                            )
                        )

                        alertController.addAction(
                            UIAlertAction(
                                title: "Change Settings",
                                style: .default
                            ) { _ in
                                if let url = URL(
                                    string: UIApplication.openSettingsURLString
                                ) {
                                    UIApplication.shared.open(
                                        url,
                                        options: [:],
                                        completionHandler: nil
                                    )
                                }
                            }
                        )

                        // Get the top view controller to present alert
                        DispatchQueue.main.async {
                            if #available(iOS 13.0, *) {
                                let windowScene =
                                    UIApplication.shared.connectedScenes.first
                                    as? UIWindowScene
                                windowScene?.windows.first?.rootViewController?
                                    .present(
                                        alertController,
                                        animated: true,
                                        completion: nil
                                    )
                            } else {
                                UIApplication.shared.keyWindow?
                                    .rootViewController?.present(
                                        alertController,
                                        animated: true,
                                        completion: nil
                                    )
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension RosyWriterAppDelegate: CLLocationManagerDelegate {

    func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        print("Location authorization changed to: \(status.rawValue)")

        switch status {
        case .authorizedAlways:
            print("Location: Always authorized")
        case .authorizedWhenInUse:
            print("Location: When in use authorized")
        case .denied, .restricted:
            print("Location: Denied or restricted")
            showLocationPermissionAlert()
        case .notDetermined:
            print("Location: Not determined")
            manager.requestAlwaysAuthorization()
        @unknown default:
            break
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        print("Location manager failed: \(error.localizedDescription)")
    }

    private func showLocationPermissionAlert() {
        // This would typically be shown from the view controller, but we can prepare for it here
        print(
            "Location permission denied - user should be prompted to enable in settings"
        )
    }
}
