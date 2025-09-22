
/*
 Copyright (C) 2016 Apple Inc. All Rights Reserved.
 See LICENSE.txt for this sample’s licensing information
 
 Abstract:
 View controller for camera interface
 */


#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

@interface InertialRecorder : NSObject <CLLocationManagerDelegate>

- (void)switchRecording;

@property NSURL *fileURL;
@property BOOL isRecording;

@end


@interface NodeWrapper : NSObject
@property NSTimeInterval time;
@property double x;
@property double y;
@property double z;
@property BOOL isGyro;

- (NSComparisonResult)compare:(NodeWrapper *)otherObject;

@end

@interface GPSNodeWrapper : NSObject
@property NSTimeInterval time;
@property double latitude;
@property double longitude;
@property double speed;

- (NSComparisonResult)compare:(GPSNodeWrapper *)otherObject;

@end

NSURL *getFileURL(const NSString *filename);

NSURL *createOutputFolderURL(void);
