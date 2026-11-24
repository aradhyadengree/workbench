#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN

/// Loads the host frameworks from the Xcode selected by xcrun.
BOOL WBLoadSimulatorKit(NSString *developerDirectory, NSError **error);
id _Nullable WBDevice(NSUUID *udid, NSString *developerDirectory, NSError **error);
/// Retained native Swift [UInt32: SimDeviceScreen] storage. Release after inspection.
void * _Nullable WBCopyScreens(id device);
void WBReleaseScreens(void *storage);

@interface WBDisplayHost : NSView
- (nullable instancetype)initWithDevice:(id)device screen:(id)screen error:(NSError **)error;
- (void)pressHomeWithReply:(void (^)(NSError * _Nullable error))reply;
- (void)detach;
@end

NS_ASSUME_NONNULL_END
