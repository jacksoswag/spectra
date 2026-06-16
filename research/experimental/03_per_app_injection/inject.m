// Test 3 injected dylib: proves code execution inside another process and hooks
// -[CAMetalLayer nextDrawable] — the exact site where a per-app shader pass would
// wrap the target's present. Loaded via DYLD_INSERT_LIBRARIES.
// Build: clang -fobjc-arc -dynamiclib -framework Foundation -framework QuartzCore inject.m -o inject.dylib
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <stdio.h>

static IMP gOrig;
static int gCount;
static id swz_nextDrawable(id self, SEL _cmd) {
    id d = ((id (*)(id, SEL))gOrig)(self, _cmd);
    fprintf(stderr, "[inject] HOOK -[CAMetalLayer nextDrawable] #%d -> %p  (a Metal shader pass would be inserted here)\n",
            ++gCount, (__bridge void *)d);
    return d;
}
__attribute__((constructor))
static void onload(void) {
    fprintf(stderr, "[inject] *** dylib executing inside pid=%d ***\n", getpid());
    Class c = objc_getClass("CAMetalLayer");
    if (!c) { fprintf(stderr, "[inject] CAMetalLayer not loaded in this process\n"); return; }
    Method m = class_getInstanceMethod(c, sel_registerName("nextDrawable"));
    if (m) {
        gOrig = method_getImplementation(m);
        method_setImplementation(m, (IMP)swz_nextDrawable);
        fprintf(stderr, "[inject] swizzled -[CAMetalLayer nextDrawable] — present path is now under our control\n");
    }
}
