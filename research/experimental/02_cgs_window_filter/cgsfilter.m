// Test 2: CGS / SkyLight per-window Core Image filter probe.
//
// Empirically answers: on macOS 26 Tahoe / Apple Silicon, does the private
// WindowServer window-filter path (CGSNewCIFilterByName + CGSAddWindowFilter)
// still composite a Core Image filter onto a window, for:
//   - built-in non-blur filters (CIColorInvert, CIPixellate, CITwirlDistortion, CIColorMonochrome)
//   - built-in blur (CIGaussianBlur) and CGSSetWindowBackgroundBlurRadius
//   - a CUSTOM in-process CIFilter referenced by name (expected to FAIL: runs server-side)
//
// Renders a recognizable test card so a screenshot makes the effect unambiguous.
// Applies to the window's OWN content ("opaque" mode) or as a Tranquility-style
// full-screen click-through overlay filtering content BEHIND it ("overlay" mode).
//
// Symbols are resolved via dlsym so the binary always links/runs even if a future
// SDK drops the .tbd entries.
//
// Build: clang -fobjc-arc -framework Cocoa -framework QuartzCore -framework CoreImage cgsfilter.m -o cgsfilter
// Run:   ./cgsfilter <CIFilterName|none|blurradius|custom> [flag=1] [opaque|overlay]

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <dlfcn.h>

typedef int CGSConnectionID;
typedef int CGSCIFilterID;
typedef CGSConnectionID (*CGSMainConnectionID_t)(void);
typedef CGError (*CGSNewCIFilterByName_t)(CGSConnectionID, CFStringRef, CGSCIFilterID *);
typedef CGError (*CGSSetCIFilterValuesFromDictionary_t)(CGSConnectionID, CGSCIFilterID, CFDictionaryRef);
typedef CGError (*CGSAddWindowFilter_t)(CGSConnectionID, CGWindowID, CGSCIFilterID, int);
typedef CGError (*CGSRemoveWindowFilter_t)(CGSConnectionID, CGWindowID, CGSCIFilterID);
typedef CGError (*CGSReleaseCIFilter_t)(CGSConnectionID, CGSCIFilterID);
typedef CGError (*CGSSetWindowBackgroundBlurRadius_t)(CGSConnectionID, CGWindowID, int);

static void *cgs(void) {
    static void *h;
    if (!h) {
        h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
        if (!h) h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    }
    return h;
}
#define FN(t,n) ((t)dlsym(cgs(), n))

// ---- recognizable test card ----
@interface CardView : NSView
@property(copy) NSString *label;
@property(assign) BOOL overlay;
@end
@implementation CardView
- (void)drawRect:(NSRect)r {
    NSRect b = self.bounds;
    if (self.overlay) {
        // translucent so the filtered desktop behind shows through
        [[NSColor colorWithWhite:0 alpha:0.0] set]; NSRectFill(b);
        [[NSColor colorWithRed:0 green:1 blue:0 alpha:0.9] setStroke];
        NSBezierPath *p = [NSBezierPath bezierPathWithRect:NSInsetRect(b, 4, 4)];
        p.lineWidth = 4; [p stroke];
    } else {
        // left half red, right half blue
        [[NSColor redColor] set];  NSRectFill(NSMakeRect(0, 0, b.size.width/2, b.size.height));
        [[NSColor blueColor] set]; NSRectFill(NSMakeRect(b.size.width/2, 0, b.size.width/2, b.size.height));
        // green concentric circles, center
        [[NSColor greenColor] setStroke];
        for (int i = 1; i <= 5; i++) {
            CGFloat rad = i * 22.0;
            NSBezierPath *c = [NSBezierPath bezierPathWithOvalInRect:
                NSMakeRect(b.size.width/2 - rad, b.size.height/2 - rad, rad*2, rad*2)];
            c.lineWidth = 3; [c stroke];
        }
        // black/white checkerboard strip along the bottom
        CGFloat sq = b.size.width / 12.0;
        for (int i = 0; i < 12; i++) {
            [(i % 2 ? [NSColor whiteColor] : [NSColor blackColor]) set];
            NSRectFill(NSMakeRect(i*sq, 0, sq, sq));
        }
    }
    // big label
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize:26],
                             NSForegroundColorAttributeName: [NSColor whiteColor],
                             NSStrokeColorAttributeName: [NSColor blackColor],
                             NSStrokeWidthAttributeName: @(-4.0) };
    [self.label drawAtPoint:NSMakePoint(16, b.size.height - 44) withAttributes:attrs];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *filterName = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"none";
        int flag = argc > 2 ? atoi(argv[2]) : 1;
        BOOL overlay = argc > 3 && strcmp(argv[3], "overlay") == 0;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSRect frame = overlay ? NSMakeRect(80, 200, 900, 600) : NSMakeRect(80, 360, 560, 380);
        NSUInteger style = overlay ? NSWindowStyleMaskBorderless
                                   : (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:frame styleMask:style
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = [NSString stringWithFormat:@"CGS filter: %@ flag=%d", filterName, flag];
        if (overlay) {
            win.opaque = NO; win.backgroundColor = [NSColor clearColor];
            win.level = CGWindowLevelForKey(kCGOverlayWindowLevelKey);
            [win setIgnoresMouseEvents:YES];
        }
        CardView *v = [[CardView alloc] initWithFrame:frame];
        v.label = [NSString stringWithFormat:@"%@ (flag %d%@)", filterName, flag, overlay?@", overlay":@""];
        v.overlay = overlay;
        win.contentView = v;
        [win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];

        CGWindowID wid = (CGWindowID)win.windowNumber;
        CGSConnectionID cid = FN(CGSMainConnectionID_t, "CGSMainConnectionID")();
        printf("connection=%d  windowID=%u  filter=%s  flag=%d  mode=%s\n",
               cid, wid, argv[1] ? argv[1] : "none", flag, overlay ? "overlay" : "opaque");

        // Give the window one runloop turn to register with WindowServer.
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];

        if ([filterName isEqualToString:@"blurradius"]) {
            CGError e = FN(CGSSetWindowBackgroundBlurRadius_t, "CGSSetWindowBackgroundBlurRadius")(cid, wid, 30);
            printf("CGSSetWindowBackgroundBlurRadius(30) -> CGError=%d %s\n", e, e==0?"OK":"FAIL");
        } else if (![filterName isEqualToString:@"none"]) {
            CFStringRef name = (__bridge CFStringRef)filterName;

            if ([filterName isEqualToString:@"custom"]) {
                // Register a custom CIFilter name in THIS process, then ask WindowServer
                // to instantiate it by name. Expected to fail: the server has no such filter.
                name = CFSTR("SpectraCustomInvertKernel");
                printf("(custom test: name only exists in this process; server should not resolve it)\n");
            }

            CGSCIFilterID fid = 0;
            CGError e1 = FN(CGSNewCIFilterByName_t, "CGSNewCIFilterByName")(cid, name, &fid);
            printf("CGSNewCIFilterByName(%s) -> CGError=%d  fid=%d  %s\n",
                   [(__bridge NSString*)name UTF8String], e1, fid, e1==0?"OK":"FAIL");

            if (e1 == 0) {
                NSDictionary *params = @{};
                if ([filterName isEqualToString:@"CIGaussianBlur"]) params = @{ @"inputRadius": @18.0 };
                else if ([filterName isEqualToString:@"CIPixellate"]) params = @{ @"inputScale": @18.0, @"inputCenter": [CIVector vectorWithX:280 Y:190] };
                else if ([filterName isEqualToString:@"CITwirlDistortion"]) params = @{ @"inputCenter": [CIVector vectorWithX:280 Y:190], @"inputRadius": @260.0, @"inputAngle": @3.14159 };
                else if ([filterName isEqualToString:@"CIColorMonochrome"]) params = @{ @"inputColor": [CIColor colorWithRed:0.6 green:0.45 blue:0.3 alpha:1.0], @"inputIntensity": @1.0 };
                if (params.count) {
                    CGError e2 = FN(CGSSetCIFilterValuesFromDictionary_t, "CGSSetCIFilterValuesFromDictionary")(cid, fid, (__bridge CFDictionaryRef)params);
                    printf("CGSSetCIFilterValuesFromDictionary -> CGError=%d %s\n", e2, e2==0?"OK":"FAIL");
                }
                CGError e3 = FN(CGSAddWindowFilter_t, "CGSAddWindowFilter")(cid, wid, fid, flag);
                printf("CGSAddWindowFilter(flag=%d) -> CGError=%d  %s\n", flag, e3, e3==0?"OK":"FAIL");
            }
        }
        fflush(stdout);
        printf("WINDOW UP. Run loop active; send SIGTERM to exit.\n"); fflush(stdout);
        [NSApp run];
    }
    return 0;
}
