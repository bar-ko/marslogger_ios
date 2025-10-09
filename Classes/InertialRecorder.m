
#import "InertialRecorder.h"

#import <CoreMotion/CoreMotion.h>
#import <CoreLocation/CoreLocation.h>

#import "VideoTimeConverter.h"

const double GRAVITY = 9.80; // see https://developer.apple.com/documentation/coremotion/getting_raw_accelerometer_events
const double RATE = 100; // fps for inertial data

@interface InertialRecorder ()
{
    
}
@property CMMotionManager *motionManager;
@property CLLocationManager *locationManager;
@property NSOperationQueue *queue;
@property NSTimer *timer;

@property NSMutableArray *rawAccelGyroData;
@property NSMutableArray *rawGPSData;

@property BOOL interpolateAccel; // interpolate accelerometer data at gyro timestamps?
@property NSString *timeStartImu;
@property NSTimeInterval bootTimeReference; // Store boot time reference for GPS synchronization
@property NSTimeInterval lastGPSUpdateTime; // Track GPS update frequency
@property int gpsUpdateCount; // Count GPS updates

@end

@implementation InertialRecorder

- (instancetype)init {
    self = [super init];
    if ( self )
    {
        _isRecording = false;
        _motionManager = [[CMMotionManager alloc] init];
        if (!_motionManager.isDeviceMotionAvailable) {
            NSLog(@"Device does not support motion capture."); }
        
        _locationManager = [[CLLocationManager alloc] init];
        _locationManager.delegate = self;
        _locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation; // Highest accuracy
        _locationManager.distanceFilter = kCLDistanceFilterNone; // Update on every location change
        _locationManager.pausesLocationUpdatesAutomatically = NO; // Don't pause updates automatically
        _locationManager.allowsBackgroundLocationUpdates = YES; // Allow background updates
        
        _fileURL = nil;
        _interpolateAccel = TRUE;

    }
    return self;
}

- (NSMutableArray *) removeDuplicates:(NSArray *)array {
    // see https://stackoverflow.com/questions/1025674/the-best-way-to-remove-duplicate-values-from-nsmutablearray-in-objective-c
    if (!array || [array count] == 0) {
        return [NSMutableArray array];
    }
    
    NSMutableArray *mutableArray = [array mutableCopy];
    NSInteger index = [array count] - 1;
    for (id object in [array reverseObjectEnumerator]) {
        if ([mutableArray indexOfObject:object inRange:NSMakeRange(0, index)] != NSNotFound) {
            [mutableArray removeObjectAtIndex:index];
        }
        index--;
    }
    return mutableArray;
}

- (GPSNodeWrapper *)interpolateGPSDataAtTime:(NSTimeInterval)targetTime fromArray:(NSArray *)gpsArray currentIndex:(int *)currentIndex {
    if (!gpsArray || [gpsArray count] == 0) {
        return nil;
    }
    
    GPSNodeWrapper *lowerGPS = nil;
    GPSNodeWrapper *upperGPS = nil;
    int lowerIndex = -1;
    int upperIndex = -1;
    
    // Find the GPS data points surrounding the target time
    for (int i = *currentIndex; i < [gpsArray count]; i++) {
        GPSNodeWrapper *gps = [gpsArray objectAtIndex:i];
        if (gps.time <= targetTime) {
            lowerGPS = gps;
            lowerIndex = i;
            *currentIndex = i; // Update current index for efficiency
        } else {
            upperGPS = gps;
            upperIndex = i;
            break;
        }
    }
    
    // If we have exact match
    if (lowerGPS && fabs(lowerGPS.time - targetTime) < 0.001) {
        // Return the existing object, no need to create a new one
        return lowerGPS;
    }
    
    // If we have both lower and upper bounds, interpolate
    if (lowerGPS && upperGPS && lowerIndex >= 0 && upperIndex >= 0) {
        // Prevent division by zero
        double timeDiff = upperGPS.time - lowerGPS.time;
        if (fabs(timeDiff) < 0.000001) { // Small epsilon to check for near-zero values
            return lowerGPS; // Return lower bound if times are too close
        }
        double ratio = (targetTime - lowerGPS.time) / timeDiff;
        
        GPSNodeWrapper *interpolatedGPS = [[GPSNodeWrapper alloc] init];
        interpolatedGPS.time = targetTime;
        interpolatedGPS.latitude = lowerGPS.latitude + (upperGPS.latitude - lowerGPS.latitude) * ratio;
        interpolatedGPS.longitude = lowerGPS.longitude + (upperGPS.longitude - lowerGPS.longitude) * ratio;
        interpolatedGPS.speed = lowerGPS.speed + (upperGPS.speed - lowerGPS.speed) * ratio;
        
        return interpolatedGPS;
    }
    
    // If we only have lower bound, use it (extrapolation)
    if (lowerGPS) {
        return lowerGPS;
    }
    
    // If we only have upper bound, use it (extrapolation)
    if (upperGPS) {
        return upperGPS;
    }
    
    return nil;
}

- (NSMutableString*)interpolate:(NSMutableArray*) accelGyroData gpsData:(NSMutableArray*) gpsData startTime:(NSString *) startTime {
    
    NSMutableArray *gyroArray = [[NSMutableArray alloc] init];
    NSMutableArray *accelArray = [[NSMutableArray alloc] init];
    
    for (int i=0;i<[accelGyroData count];i++) {
        NodeWrapper *nw =[accelGyroData objectAtIndex:i];
        if (nw.time <= 0)
            continue;
        if (nw.isGyro)
            [gyroArray addObject:nw];
        else
            [accelArray addObject:nw];
    }
    
    NSArray *sortedArrayGyro = [gyroArray sortedArrayUsingSelector:@selector(compare:)];
    NSArray *sortedArrayAccel = [accelArray sortedArrayUsingSelector:@selector(compare:)];
    
    NSMutableArray *mutableGyroCopy = [self removeDuplicates:sortedArrayGyro];
    NSMutableArray *mutableAccelCopy = [self removeDuplicates:sortedArrayAccel];
    
    // Sort GPS data by time
    NSArray *sortedGPSArray = [gpsData sortedArrayUsingSelector:@selector(compare:)];
    
    NSLog(@"Interpolating data: %lu gyro samples, %lu accel samples, %lu GPS samples", 
          (unsigned long)[mutableGyroCopy count], (unsigned long)[mutableAccelCopy count], (unsigned long)[sortedGPSArray count]);
    
    // interpolate
    NSMutableString *mainString = [[NSMutableString alloc]initWithString:@""];
    int accelIndex = 0;
    int gpsIndex = 0;
    [mainString appendFormat:@"Timestamp[nanosec], gx[rad/s], gy[rad/s], gz[rad/s], ax[m/s^2], ay[m/s^2], az[m/s^2], latitude[deg], longitude[deg], speed[m/s]\n"];
    // Check if arrays are empty to avoid out of bounds access
    if ([mutableGyroCopy count] == 0 || [mutableAccelCopy count] == 0) {
        return mainString;
    }
    
    for (int gyroIndex = 0; gyroIndex < [mutableGyroCopy count]; ++gyroIndex) {
        NodeWrapper *nwg = [mutableGyroCopy objectAtIndex:gyroIndex];
        
        // Make sure accelIndex is within bounds
        if (accelIndex >= [mutableAccelCopy count]) {
            break;
        }
        
        NodeWrapper *nwa = [mutableAccelCopy objectAtIndex:accelIndex];
        
        // Find GPS data for this timestamp with interpolation
        GPSNodeWrapper *nwGPS = [self interpolateGPSDataAtTime:nwg.time fromArray:sortedGPSArray currentIndex:&gpsIndex];
        
        if (nwg.time < nwa.time) {
            continue;
        } else if (nwg.time == nwa.time) {
            if (nwGPS) {
                [mainString appendFormat:@"%@, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f\n", 
                 secDoubleToNanoString(nwg.time), nwg.x, nwg.y, nwg.z, nwa.x, nwa.y, nwa.z, 
                 nwGPS.latitude, nwGPS.longitude, nwGPS.speed];
            } else {
                [mainString appendFormat:@"%@, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f\n", 
                 secDoubleToNanoString(nwg.time), nwg.x, nwg.y, nwg.z, nwa.x, nwa.y, nwa.z, 
                 0.0, 0.0, 0.0];
            }
        } else {
            int lowerIndex = accelIndex;
            int upperIndex = accelIndex + 1;
            for (int iterIndex = accelIndex + 1; iterIndex < [mutableAccelCopy count]; ++iterIndex) {
                NodeWrapper *nwa1 = [mutableAccelCopy objectAtIndex:iterIndex];
                if (nwa1.time < nwg.time) {
                    lowerIndex = iterIndex;
                } else if (nwa1.time > nwg.time) {
                    upperIndex = iterIndex;
                    break;
                } else {
                    lowerIndex = iterIndex;
                    upperIndex = iterIndex;
                    break;
                }
            }
            
            // Make sure upperIndex is valid
            if (upperIndex >= [mutableAccelCopy count]) {
                break;
            }
            
            if (upperIndex == lowerIndex) {
                NodeWrapper *nwa1 = [mutableAccelCopy objectAtIndex:upperIndex];
                if (nwGPS) {
                    [mainString appendFormat:@"%@, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f\n", 
                     secDoubleToNanoString(nwg.time), nwg.x, nwg.y, nwg.z, nwa1.x, nwa1.y, nwa1.z, 
                     nwGPS.latitude, nwGPS.longitude, nwGPS.speed];
                } else {
                    [mainString appendFormat:@"%@, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f\n", 
                     secDoubleToNanoString(nwg.time), nwg.x, nwg.y, nwg.z, nwa1.x, nwa1.y, nwa1.z, 
                     0.0, 0.0, 0.0];
                }
            } else if (upperIndex == lowerIndex + 1) {
                // Make sure both indices are valid
                if (lowerIndex < 0 || lowerIndex >= [mutableAccelCopy count] || 
                    upperIndex < 0 || upperIndex >= [mutableAccelCopy count]) {
                    break;
                }
                
                NodeWrapper *nwa = [mutableAccelCopy objectAtIndex:lowerIndex];
                NodeWrapper *nwa1 = [mutableAccelCopy objectAtIndex:upperIndex];
                // Prevent division by zero
                double timeDiff = nwa1.time - nwa.time;
                if (fabs(timeDiff) < 0.000001) { // Small epsilon to check for near-zero values
                    continue;
                }
                double ratio = (nwg.time - nwa.time) / timeDiff;
                double interpax = nwa.x + (nwa1.x - nwa.x) * ratio;
                double interpay = nwa.y + (nwa1.y - nwa.y) * ratio;
                double interpaz = nwa.z + (nwa1.z - nwa.z) * ratio;
                if (nwGPS) {
                    [mainString appendFormat:@"%@, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f\n", 
                     secDoubleToNanoString(nwg.time), nwg.x, nwg.y, nwg.z, interpax, interpay, interpaz, 
                     nwGPS.latitude, nwGPS.longitude, nwGPS.speed];
                } else {
                    [mainString appendFormat:@"%@, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f, %.15f\n", 
                     secDoubleToNanoString(nwg.time), nwg.x, nwg.y, nwg.z, interpax, interpay, interpaz, 
                     0.0, 0.0, 0.0];
                }
            } else {
                NSLog(@"Impossible lower and upper bound %d %d for gyro timestamp %.5f", lowerIndex, upperIndex, nwg.time);
            }
            accelIndex = lowerIndex;
        }
    }
    // Local arrays will be automatically deallocated when the method exits
    // No need to call removeAllObjects
    return mainString;
}

- (void)switchRecording {
    if (_isRecording) {
        _isRecording = false;
        [_motionManager stopGyroUpdates];
        [_motionManager stopAccelerometerUpdates];
        [_locationManager stopUpdatingLocation];
        
        NSMutableString *mainString = [[NSMutableString alloc]initWithString:@""];
        if (!_interpolateAccel) {
            [mainString appendFormat:@"Timestamp[nanosec], x, y, z[(a:m/s^2)/(g:rad/s)], isGyro?\n"];
            for(int i=0;i<[_rawAccelGyroData count];i++ ) {
                NodeWrapper *nw =[_rawAccelGyroData objectAtIndex:i];
                [mainString appendFormat:@"%.7f, %.5f, %.5f, %.5f, %d\n", nw.time, nw.x, nw.y, nw.z, nw.isGyro];
            }
        } else { // linearly interpolate acceleration offline
            // TODO(jhuai): Though offline interpolation is enough for practical needs,
            // eg., 20 min recording, online interpolation may be still desirable.
            // It can be implemented referring to Vins Mobile and MarsLogger Android.
            mainString = [self interpolate:_rawAccelGyroData gpsData:_rawGPSData startTime:_timeStartImu];
        }
        // Set arrays to nil to properly release them
        _rawAccelGyroData = nil;
        _rawGPSData = nil;

        NSData *settingsData;
        settingsData = [mainString dataUsingEncoding: NSUTF8StringEncoding allowLossyConversion:false];
        
        if ([settingsData writeToURL:_fileURL atomically:YES]) {
            NSLog(@"Written inertial data to %@", _fileURL);
        }
        else {
            NSLog(@"Failed to record inertial data at %@", _fileURL);
        }
        
        NSLog(@"Stopped recording inertial data!");
    } else {
        _isRecording = true;
        NSLog(@"Start recording inertial data!");
        _rawAccelGyroData = [[NSMutableArray alloc] init];
        _rawGPSData = [[NSMutableArray alloc] init];
        _motionManager.gyroUpdateInterval = 1.0/RATE;
        _motionManager.accelerometerUpdateInterval = 1.0/RATE;
        
        // Store boot time reference for GPS synchronization
        _bootTimeReference = [NSDate date].timeIntervalSince1970 - [NSProcessInfo processInfo].systemUptime;
        _gpsUpdateCount = 0;
        _lastGPSUpdateTime = 0;
        NSLog(@"Boot time reference: %.6f", _bootTimeReference);
        
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        [dateFormatter setDateFormat:@"EEE_MM_dd_yyyy_HH_mm_ss"];
        _timeStartImu = [dateFormatter stringFromDate:[NSDate date]];
        
        if (_motionManager.gyroAvailable && _motionManager.accelerometerAvailable) {
//            _queue = [NSOperationQueue currentQueue]; // mainQueue, run on main UI thread
            _queue = [[NSOperationQueue alloc] init]; // background thread
            [_motionManager startGyroUpdatesToQueue:_queue withHandler: ^ (CMGyroData *gyroData, NSError *error) {
                CMRotationRate rotate = gyroData.rotationRate;
                
                NodeWrapper *nw = [[NodeWrapper alloc] init];
                nw.isGyro = true;
                nw.time = gyroData.timestamp;
                nw.x = rotate.x;
                nw.y = rotate.y;
                nw.z = rotate.z;
                [self->_rawAccelGyroData addObject:nw];
            }];
            [_motionManager startAccelerometerUpdatesToQueue:_queue withHandler: ^ (CMAccelerometerData *accelData, NSError *error) {
                CMAcceleration accel = accelData.acceleration;
                
                NodeWrapper *nw = [[NodeWrapper alloc] init];
                nw.isGyro = false;
                // The time stamp is the amount of time in seconds since the device booted.
                nw.time = accelData.timestamp;
                nw.x = - accel.x * GRAVITY;
                nw.y = - accel.y * GRAVITY;
                nw.z = - accel.z * GRAVITY;
                
                [self->_rawAccelGyroData addObject:nw];
            }];
        } else {
            NSLog(@"Gyroscope or accelerometer not available");
        }
        
        // Start GPS location updates with maximum frequency
        if ([CLLocationManager locationServicesEnabled]) {
            CLAuthorizationStatus status = [CLLocationManager authorizationStatus];
            if (status == kCLAuthorizationStatusNotDetermined) {
                [_locationManager requestWhenInUseAuthorization];
            } else if (status == kCLAuthorizationStatusAuthorizedWhenInUse || status == kCLAuthorizationStatusAuthorizedAlways) {
                // Request "Always" authorization for maximum update frequency
                if (status == kCLAuthorizationStatusAuthorizedWhenInUse) {
                    [_locationManager requestAlwaysAuthorization];
                }
                [_locationManager startUpdatingLocation];
                NSLog(@"Started GPS location updates with maximum frequency settings");
            } else {
                NSLog(@"Location services not authorized");
            }
        } else {
            NSLog(@"Location services not enabled");
        }
    }
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (!_isRecording) return;
    
    CLLocation *location = [locations lastObject];
    if (location && location.coordinate.latitude != 0 && location.coordinate.longitude != 0) {
        GPSNodeWrapper *gpsNode = [[GPSNodeWrapper alloc] init];
        // Use the same time reference as inertial data (time since device boot)
        // Convert from absolute time to time since boot using stored reference
        gpsNode.time = location.timestamp.timeIntervalSince1970 - _bootTimeReference;
        gpsNode.latitude = location.coordinate.latitude;
        gpsNode.longitude = location.coordinate.longitude;
        gpsNode.speed = location.speed >= 0 ? location.speed : 0.0; // Handle negative speed values
        
        [_rawGPSData addObject:gpsNode];
        _gpsUpdateCount++;
        
        // Log GPS update frequency every 10 updates
        if (_gpsUpdateCount % 10 == 0) {
            NSTimeInterval timeSinceLastUpdate = _lastGPSUpdateTime > 0 ? gpsNode.time - _lastGPSUpdateTime : 0;
            double gpsFrequency = _lastGPSUpdateTime > 0 ? 1.0 / timeSinceLastUpdate : 0;
            NSLog(@"GPS Update #%d: lat=%.15f, lon=%.15f, speed=%.15f, time=%.6f, freq=%.1f Hz", 
                  _gpsUpdateCount, gpsNode.latitude, gpsNode.longitude, gpsNode.speed, gpsNode.time, gpsFrequency);
        } else {
            NSLog(@"GPS: lat=%.15f, lon=%.15f, speed=%.15f, time=%.6f", gpsNode.latitude, gpsNode.longitude, gpsNode.speed, gpsNode.time);
        }
        
        _lastGPSUpdateTime = gpsNode.time;
    }
}

- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    switch (status) {
        case kCLAuthorizationStatusAuthorizedWhenInUse:
        case kCLAuthorizationStatusAuthorizedAlways:
            if (_isRecording) {
                [_locationManager startUpdatingLocation];
                NSLog(@"GPS authorization granted, starting location updates");
            }
            break;
        case kCLAuthorizationStatusDenied:
        case kCLAuthorizationStatusRestricted:
            NSLog(@"GPS location access denied or restricted");
            break;
        case kCLAuthorizationStatusNotDetermined:
            NSLog(@"GPS location authorization not determined");
            break;
        default:
            break;
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    NSLog(@"GPS location manager failed with error: %@", error.localizedDescription);
}

@end


@implementation NodeWrapper
- (NSComparisonResult)compare:(NodeWrapper *)otherObject {
    return [@(self.time) compare:@(otherObject.time)]; // @ converts double to NSNumber
}
@end

@implementation GPSNodeWrapper
- (NSComparisonResult)compare:(GPSNodeWrapper *)otherObject {
    return [@(self.time) compare:@(otherObject.time)]; // @ converts double to NSNumber
}
@end


NSURL *getFileURL(NSString *filename) {
    NSArray *paths = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    NSURL *documentsURL = [paths lastObject];
    return [documentsURL URLByAppendingPathComponent:filename isDirectory:NO];
}

NSURL *createOutputFolderURL(void) {
    NSDate *now = [NSDate date];
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy_MM_dd_HH_mm_ss"];
    NSString *dateTimeString = [dateFormatter stringFromDate:now];
    
    NSArray *paths = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    NSURL *documentsURL = [paths lastObject];
    NSURL *outputFolderURL = [documentsURL URLByAppendingPathComponent:dateTimeString isDirectory:YES];

    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtURL:outputFolderURL
                              withIntermediateDirectories:NO
                                               attributes:nil
                                                    error:&error];
    if (error != nil) {
        NSLog(@"Error creating directory: %@", error);
        outputFolderURL = nil;
    }
    return outputFolderURL;
}
