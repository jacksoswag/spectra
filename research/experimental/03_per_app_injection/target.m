// Test 3 target: a NON-hardened app that uses a CAMetalLayer, so an injected
// dylib can hook -[CAMetalLayer nextDrawable] (the per-app shader insertion point).
// Build: clang -fobjc-arc -framework Foundation -framework QuartzCore -framework Metal target.m -o target
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

int main(void) {
    @autoreleasepool {
        printf("[target] pid=%d starting\n", getpid()); fflush(stdout);
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = dev;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize = CGSizeMake(256, 256);
        layer.framebufferOnly = NO;
        for (int i = 0; i < 5; i++) {
            @autoreleasepool {
                id<CAMetalDrawable> d = [layer nextDrawable];
                printf("[target] frame %d nextDrawable=%p\n", i, (__bridge void *)d); fflush(stdout);
                [NSThread sleepForTimeInterval:0.15];
            }
        }
        printf("[target] done\n");
    }
    return 0;
}
