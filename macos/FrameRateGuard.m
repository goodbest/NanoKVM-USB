#import "FrameRateGuard.h"

BOOL NanoKVMSetFrameRate(AVCaptureDevice *device, CMTime duration, NSError **error) {
    NSError *lockError = nil;
    if (![device lockForConfiguration:&lockError]) {
        if (error != NULL) {
            *error = lockError;
        }
        return NO;
    }

    BOOL succeeded = YES;
    @try {
        device.activeVideoMinFrameDuration = duration;
        device.activeVideoMaxFrameDuration = duration;
    } @catch (NSException *exception) {
        succeeded = NO;
        if (error != NULL) {
            NSString *message = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"NanoKVM.FrameRate"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
        }
    } @finally {
        [device unlockForConfiguration];
    }
    return succeeded;
}
