//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

#import "UIViewController+CameraPermissions.h"
#import "Signal-Swift.h"
#import "UIUtil.h"
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@implementation UIViewController (CameraPermissions)

- (void)ows_askForCameraPermissions:(void (^)(void))permissionsGrantedCallback
{
    [self ows_askForCameraPermissions:permissionsGrantedCallback failureCallback:nil];
}

- (void)ows_askForCameraPermissions:(void (^)(void))permissionsGrantedCallback
                    failureCallback:(nullable void (^)(void))failureCallback
{
    DDLogVerbose(@"%@ ows_askForCameraPermissions", NSStringFromClass(self.class));

    // Avoid nil tests below.
    if (!failureCallback) {
        failureCallback = ^{
        };
    }

    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        DDLogError(@"Skipping camera permissions request when app is not active.");
        failureCallback();
        return;
    }

    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
        DDLogError(@"Camera ImagePicker source not available");
        failureCallback();
        return;
    }

    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusDenied) {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"MISSING_CAMERA_PERMISSION_TITLE", @"Alert title")
                                                                       message:NSLocalizedString(@"MISSING_CAMERA_PERMISSION_MESSAGE", @"Alert body")
                                                                preferredStyle:UIAlertControllerStyleAlert];

        NSString *settingsTitle = NSLocalizedString(@"OPEN_SETTINGS_BUTTON", @"Button text which opens the settings app");
        UIAlertAction *openSettingsAction = [UIAlertAction actionWithTitle:settingsTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [[UIApplication sharedApplication] openSystemSettings];
            failureCallback();
        }];
        [alert addAction:openSettingsAction];

        UIAlertAction *dismissAction = [UIAlertAction actionWithTitle:CommonStrings.dismissButton
                                                                style:UIAlertActionStyleCancel
                                                              handler:^(UIAlertAction *action) {
                                                                  failureCallback();
                                                              }];
        [alert addAction:dismissAction];

        [self presentViewController:alert animated:YES completion:nil];
    } else if (status == AVAuthorizationStatusAuthorized) {
        permissionsGrantedCallback();
    } else if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                 completionHandler:^(BOOL granted) {
                                     dispatch_async(dispatch_get_main_queue(), ^{
                                         if (granted) {
                                             permissionsGrantedCallback();
                                         } else {
                                             failureCallback();
                                         }
                                     });
                                 }];
    } else {
        DDLogError(@"Unknown AVAuthorizationStatus: %ld", (long)status);
        failureCallback();
    }
}

@end

NS_ASSUME_NONNULL_END
