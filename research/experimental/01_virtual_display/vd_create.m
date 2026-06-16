// Test 1: create a HEADLESS SECONDARY virtual display via the private
// CGVirtualDisplay API, confirm it registers in the display list / NSScreen,
// capture what WindowServer composites onto it, then tear it down on exit.
//
// SAFETY: never made main, never mirrored, real panel untouched. Equivalent to
// briefly attaching an extra monitor for a few seconds.
//
// Build: clang -fobjc-arc -framework Cocoa -framework CoreGraphics vd_create.m -o vd_create
// Run:   ./vd_create [seconds=8]

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

@class CGVirtualDisplay;
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)w height:(unsigned int)h refreshRate:(double)r;
@property(readonly,nonatomic) unsigned int width, height; @property(readonly,nonatomic) double refreshRate;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) unsigned int vendorID, productID, serialNum;
@property(strong,nonatomic) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong,nonatomic) dispatch_queue_t queue;
@property(copy,nonatomic) void (^terminationHandler)(CGVirtualDisplay *);
- (instancetype)init;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(strong,nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property(nonatomic) unsigned int hiDPI;
- (instancetype)init;
@end
@interface CGVirtualDisplay : NSObject
@property(readonly,nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@end

static CGVirtualDisplay *gVD = nil; // keep alive

static void printDisplays(const char *label) {
    uint32_t n = 0; CGGetActiveDisplayList(0, NULL, &n);
    CGDirectDisplayID ids[16]; CGGetActiveDisplayList(16, ids, &n);
    printf("[%s] active displays = %u: ", label, n);
    for (uint32_t i = 0; i < n; i++)
        printf("%u%s%s ", ids[i],
               CGDisplayIsMain(ids[i]) ? "(main)" : "",
               CGDisplayIsBuiltin(ids[i]) ? "(builtin)" : "");
    printf("\n  NSScreen.screens = %lu\n", (unsigned long)NSScreen.screens.count);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        double secs = argc > 1 ? atof(argv[1]) : 8.0;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        printDisplays("before");

        CGVirtualDisplayDescriptor *d = [CGVirtualDisplayDescriptor new];
        d.name = @"Spectra Test VD";
        d.vendorID = 0x1234; d.productID = 0x0001; d.serialNum = 0x0001;
        d.sizeInMillimeters = CGSizeMake(597.0, 336.0); // 27" trick
        d.maxPixelsWide = 1920; d.maxPixelsHigh = 1080;
        d.redPrimary   = CGPointMake(0.6797, 0.3203);
        d.greenPrimary = CGPointMake(0.2559, 0.6983);
        d.bluePrimary  = CGPointMake(0.1494, 0.0557);
        d.whitePoint   = CGPointMake(0.3125, 0.3291);
        d.queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
        d.terminationHandler = ^(CGVirtualDisplay *vd){ printf("  [terminationHandler fired]\n"); };

        gVD = [[CGVirtualDisplay alloc] initWithDescriptor:d];
        printf("CGVirtualDisplay alloc = %p\n", (__bridge void *)gVD);

        CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
        s.modes = @[ [[CGVirtualDisplayMode alloc] initWithWidth:1920 height:1080 refreshRate:60.0] ];
        s.hiDPI = 0;
        BOOL ok = [gVD applySettings:s];
        printf("applySettings -> %s\n", ok ? "YES" : "NO");

        // let it register
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
        CGDirectDisplayID did = gVD.displayID;
        printf("VD displayID = %u  isMain=%d isBuiltin=%d isOnline=%d  bounds=%@\n",
               did, CGDisplayIsMain(did), CGDisplayIsBuiltin(did), CGDisplayIsOnline(did),
               NSStringFromRect(CGDisplayBounds(did)));
        printDisplays("after applySettings");

        // If it did not appear, try SkyLight activation (Lumen path).
        uint32_t n=0; CGGetActiveDisplayList(0,NULL,&n);
        CGDirectDisplayID ids[16]; CGGetActiveDisplayList(16, ids, &n);
        BOOL present = NO; for (uint32_t i=0;i<n;i++) if (ids[i]==did) present=YES;
        if (!present && did != 0) {
            void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
            int (*SLSMainConnectionID)(void) = dlsym(sl, "SLSMainConnectionID");
            CGError (*SLSConfigureDisplayEnabled)(int, CGDirectDisplayID, bool) = dlsym(sl, "SLSConfigureDisplayEnabled");
            if (SLSMainConnectionID && SLSConfigureDisplayEnabled) {
                CGError e = SLSConfigureDisplayEnabled(SLSMainConnectionID(), did, true);
                printf("SLSConfigureDisplayEnabled -> %d\n", e);
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
                printDisplays("after SLS activation");
            }
        }

        // Dump the modes CoreGraphics actually registered for the VD.
        CFArrayRef modes = CGDisplayCopyAllDisplayModes(did, NULL);
        if (modes) {
            printf("registered modes (%ld):\n", CFArrayGetCount(modes));
            for (CFIndex i=0;i<CFArrayGetCount(modes) && i<8;i++) {
                CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
                printf("  %zux%zu @%.0f\n", CGDisplayModeGetPixelWidth(m), CGDisplayModeGetPixelHeight(m),
                       CGDisplayModeGetRefreshRate(m));
            }
            CFRelease(modes);
        }

        printf("VD ALIVE for %.0fs (capture window now)...\n", secs); fflush(stdout);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:secs]];

        printf("releasing VD...\n");
        gVD = nil; // teardown
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
        printDisplays("after release");
    }
    return 0;
}
