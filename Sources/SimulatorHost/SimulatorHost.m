#import "SimulatorHost.h"
#import <dlfcn.h>
#import <math.h>

// These are Swift method dispatch thunks in Xcode's SimulatorKit, not C functions.
// swift_context and swift_error_result put self and the throwing result in their ABI registers.
#define SWIFT __attribute__((swiftcall))
#define SELF __attribute__((swift_context))
#define ERROR_RESULT __attribute__((swift_error_result))
typedef void *(*ObjectGetter)(void * SELF) SWIFT;
typedef void (*Connect)(void *, const uintptr_t *, void * SELF, void ** ERROR_RESULT) SWIFT;
typedef void (*Disconnect)(void *, void *, void * SELF) SWIFT;
typedef CGFloat (*FitScale)(CGSize, void * SELF) SWIFT;
typedef CGSize (*ScaledSize)(CGFloat, void * SELF) SWIFT;
typedef void (*SetScale)(CGFloat, void * SELF) SWIFT;
typedef void (*SetChrome)(bool, void * SELF) SWIFT;

static ObjectGetter adapterForDevice, screensForAdapter;
static Connect connectScreen;
static Disconnect disconnectScreen;
static FitScale fitScale;
static ScaledSize scaledSize;
static SetScale setScale;
static SetChrome setChrome;
static void *(*buttonMessage)(uint32_t, uint32_t, uint32_t);

@protocol WBButtonClient <NSObject>
- (instancetype)initWithDevice:(id)device error:(NSError **)error;
- (void)sendWithMessage:(void *)message freeWhenDone:(BOOL)freeWhenDone
        completionQueue:(dispatch_queue_t)queue completion:(void (^)(NSError *))completion;
@end
extern void swift_release(void *);
extern void swift_bridgeObjectRelease(void *);
extern void swift_errorRelease(void *);

@protocol WBService <NSObject>
+ (id)sharedServiceContextForDeveloperDir:(NSString *)path error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSDictionary *)devicesByUDID;
@end

static BOOL fail(NSError **error, NSString *reason) {
    if (error) *error = [NSError errorWithDomain:@"Workbench.Simulator" code:1
                                        userInfo:@{NSLocalizedDescriptionKey:reason}];
    return NO;
}

BOOL WBLoadSimulatorKit(NSString *developerDirectory, NSError **error) {
    static NSString *loadedDirectory;
    @synchronized (WBDisplayHost.class) {
        if (loadedDirectory) {
            if ([developerDirectory isEqualToString:loadedDirectory]) return YES;
            return fail(error, @"Xcode changed during this session. Reopen Workbench to use the new Xcode.");
        }
        NSString *path = [developerDirectory stringByAppendingPathComponent:@"Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"];
        if (!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW | RTLD_GLOBAL))
            return fail(error, @"CoreSimulator could not load. Open Xcode and finish installing its components.");
        void *kit = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!kit) return fail(error, @"SimulatorKit could not load from the selected Xcode.");
#define VIEW "$s12SimulatorKit14SimDisplayViewC"
        adapterForDevice = dlsym(kit, "$sSo9SimDeviceC12SimulatorKitE13screenAdapterAC0ab6ScreenF0CSgvg");
        screensForAdapter = dlsym(kit, "$s12SimulatorKit22SimDeviceScreenAdapterC7screensSDys6UInt32VAA0cdE0CGvg");
        connectScreen = dlsym(kit, VIEW "7connect6screen6inputsyAA0C12DeviceScreenC_AC0j5InputI0VtKFTj");
        disconnectScreen = dlsym(kit, VIEW "10disconnect10completionyyycSg_tFTj");
        fitScale = dlsym(kit, VIEW "5scale3for12CoreGraphics7CGFloatVSo6CGSizeV_tFTj");
        scaledSize = dlsym(kit, VIEW "4size3forSo6CGSizeV12CoreGraphics7CGFloatV_tFTj");
        setScale = dlsym(kit, VIEW "11renderScale12CoreGraphics7CGFloatVvsTj");
        buttonMessage = dlsym(kit, "IndigoHIDMessageForButton");
        setChrome = dlsym(kit, VIEW "16showDeviceChromeSbvsTj");
        if (!adapterForDevice || !screensForAdapter || !connectScreen || !disconnectScreen || !fitScale ||
            !scaledSize || !setScale || !setChrome || ![NSClassFromString(@"SimulatorKit.SimDisplayView") isSubclassOfClass:NSView.class] ||
            ![NSClassFromString(@"SimulatorKit.SimDeviceScreen") instancesRespondToSelector:@selector(isDefault)] ||
            ![NSClassFromString(@"SimServiceContext") respondsToSelector:@selector(sharedServiceContextForDeveloperDir:error:)])
            return fail(error, @"This Xcode version does not expose the simulator display interface Workbench requires.");
        loadedDirectory = [developerDirectory copy];
        return YES;
    }
}

id WBDevice(NSUUID *udid, NSString *directory, NSError **error) {
    if (!WBLoadSimulatorKit(directory, error)) return nil;
    Class<WBService> cls = NSClassFromString(@"SimServiceContext");
    id<WBService> service = [cls sharedServiceContextForDeveloperDir:directory error:error];
    if (!service) return nil;
    if (![service respondsToSelector:@selector(defaultDeviceSetWithError:)]) { fail(error, @"Unsupported simulator service interface."); return nil; }
    id<WBService> set = [service defaultDeviceSetWithError:error];
    if (!set) return nil;
    if (![set respondsToSelector:@selector(devicesByUDID)]) { fail(error, @"Unsupported simulator device set."); return nil; }
    id device = [set devicesByUDID][udid];
    if (!device) fail(error, @"The selected simulator is no longer available. Refresh the device list.");
    return device;
}

void *WBCopyScreens(id device) {
    void *adapter = adapterForDevice((__bridge void *)device);
    if (!adapter) return NULL;
    void *screens = screensForAdapter(adapter);
    swift_release(adapter);
    return screens;
}
void WBReleaseScreens(void *storage) { swift_bridgeObjectRelease(storage); }

@interface WBDisplayHost ()
@property(nonatomic, strong) NSView *display;
@property(nonatomic, strong) id device;
@property(nonatomic, strong) id screen;
@property(nonatomic) BOOL attached;
@property(nonatomic) CGFloat appliedScale;
@property(nonatomic) BOOL routingKey;
@property(nonatomic, strong) id<WBButtonClient> buttonClient;
@end

@implementation WBDisplayHost
- (instancetype)initWithDevice:(id)device screen:(id)screen error:(NSError **)error {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, 320, 600)])) return nil;
    self.device = device;
    self.screen = screen;
    self.display = [[NSClassFromString(@"SimulatorKit.SimDisplayView") alloc] initWithFrame:self.bounds];
    [self addSubview:self.display];
    setChrome(true, (__bridge void *)self.display);
    // ScreenInputDevice is a resilient, single-word OptionSet passed indirectly.
    // Bits 0, 1 and 2 select the digitizer, hardware buttons and keyboard.
    uintptr_t inputs = 7;
    void *swiftError = NULL;
    connectScreen((__bridge void *)screen, &inputs, (__bridge void *)self.display, &swiftError);
    if (swiftError) {
        swift_errorRelease(swiftError);
        fail(error, @"Xcode could not attach display and input to this device. Disconnect and try again.");
        return nil;
    }
    self.attached = YES;
    return self;
}
// Keep pointer dispatch in SimulatorKit's digitizer view. Give its keyboard
// handler a responder in the Workbench window after the user clicks the device.
- (BOOL)acceptsFirstResponder { return YES; }
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    if (hit && self.attached && NSApp.currentEvent.type == NSEventTypeLeftMouseDown &&
        self.window.firstResponder != self) [self.window makeFirstResponder:self];
    return hit;
}
- (void)keyDown:(NSEvent *)event {
    if (self.routingKey || !self.attached) { [super keyDown:event]; return; }
    self.routingKey = YES;
    [self.display keyDown:event];
    self.routingKey = NO;
}
- (void)keyUp:(NSEvent *)event {
    if (self.routingKey || !self.attached) { [super keyUp:event]; return; }
    self.routingKey = YES;
    [self.display keyUp:event];
    self.routingKey = NO;
}
- (void)layout {
    [super layout];
    if (!self.attached || NSIsEmptyRect(self.bounds)) return;
    void *view = (__bridge void *)self.display;
    CGFloat scale = fitScale(self.bounds.size, view);
    if (!isfinite(scale) || scale <= 0) return;
    CGSize size = scaledSize(scale, view);
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0) return;
    if (fabs(scale - self.appliedScale) > 0.00001) {
        self.appliedScale = scale;
        setScale(scale, view);
    }
    self.display.frame = NSMakeRect((NSWidth(self.bounds)-size.width)/2, (NSHeight(self.bounds)-size.height)/2, size.width, size.height);
}
- (void)pressHomeWithReply:(void (^)(NSError *))reply {
    Class cls = NSClassFromString(@"SimulatorKit.SimDeviceLegacyHIDClient");
    NSError *error = nil;
    if (!self.attached || !buttonMessage || ![cls instancesRespondToSelector:@selector(initWithDevice:error:)] ||
        ![cls instancesRespondToSelector:@selector(sendWithMessage:freeWhenDone:completionQueue:completion:)]) {
        fail(&error, @"Home is unavailable for this simulator connection.");
        reply(error); return;
    }
    if (!self.buttonClient) self.buttonClient = [(id<WBButtonClient>)[cls alloc] initWithDevice:self.device error:&error];
    id<WBButtonClient> client = self.buttonClient;
    if (!client) {
        if (!error) fail(&error, @"Could not connect the Home control to this device.");
        reply(error); return;
    }
    // SimulatorKit Indigo Home source, button-down/up, guest hardware service.
    // See facebook/idb PrivateHeaders/SimulatorApp/Indigo.h.
    void *down = buttonMessage(0, 1, 0x33);
    void *up = buttonMessage(0, 2, 0x33);
    if (!down || !up) {
        free(down); free(up);
        fail(&error, @"Could not create the Home button event."); reply(error); return;
    }
    [client sendWithMessage:down freeWhenDone:YES completionQueue:dispatch_get_main_queue() completion:^(NSError *downError) {
        [client sendWithMessage:up freeWhenDone:YES completionQueue:dispatch_get_main_queue() completion:^(NSError *upError) {
            reply(downError ?: upError);
        }];
    }];
}
- (void)detach {
    if (!self.attached) return;
    self.attached = NO;
    disconnectScreen(NULL, NULL, (__bridge void *)self.display);
}
- (void)dealloc { [self detach]; }
@end
