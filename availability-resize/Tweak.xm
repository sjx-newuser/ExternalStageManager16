// TrollPad-derived availability/PAC and resize hooks; original authors:
// khanhduytran0 (Duy Tran) and TrollPad contributors.
// Source: https://github.com/khanhduytran0/TrollPad/blob/3a841b3aa26d96df2acbcdb129dcfddf69a62b06/TweakSB.x
// See ../CREDITS.md for attribution scope and third-party licensing status.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>

#include <dlfcn.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <substrate.h>

@interface UIView (ExternalStageManager16PrivateScreen)
- (UIScreen *)_screen;
@end

@interface SBFluidSwitcherItemContainer : UIView
@end

// Inferred from TrollPad's verified 0b1100 bottom-corners mask combined
// with UIKit's UIRectCorner bit ordering. No public declaration of the
// SBFluidSwitcherItemContainer private mask enum was found.
static const NSUInteger kBottomRightResizeCorner = 0b1000;

static const char * const kSpringBoardFoundationPath =
    "/System/Library/PrivateFrameworks/SpringBoardFoundation.framework/SpringBoardFoundation";
static const char * const kAvailabilitySymbol =
    "SBFIsChamoisExternalDisplayControllerAvailable";

int hookedExtDisplayEnabledFunc() {
    // TrollPad's arm64e/PAC workaround: keep this exactly in the replacement.
    // clang forgets to PAC this function, so we need this ugly line
    int hack = 0; if (hack) { printf(""); }

    return 1;
}

%group ExternalBottomRightResize

%hook SBFluidSwitcherItemContainer

- (void)setAllowedTouchResizeCorners:(NSUInteger)cornerMask {
    if ([self _screen] != UIScreen.mainScreen) {
        %orig(kBottomRightResizeCorner);
    } else {
        %orig;
    }
}

%end

%end

%ctor {
    @autoreleasepool {
        NSOperatingSystemVersion version = NSProcessInfo.processInfo.operatingSystemVersion;
        if (version.majorVersion != 16 || version.minorVersion != 1) {
            return;
        }

        void *sbFoundationHandle = dlopen(kSpringBoardFoundationPath, RTLD_GLOBAL);
        if (!sbFoundationHandle) {
            os_log_error(OS_LOG_DEFAULT,
                         "ExternalStageManager16: SpringBoardFoundation unavailable; no hook installed");
            return;
        }

        void *availabilityFunction = dlsym(sbFoundationHandle, kAvailabilitySymbol);
        if (!availabilityFunction) {
            os_log_error(OS_LOG_DEFAULT,
                         "ExternalStageManager16: availability symbol unavailable; no hook installed");
            return;
        }

        MSHookFunction(availabilityFunction, (void *)hookedExtDisplayEnabledFunc, NULL);

        Class containerClass = NSClassFromString(@"SBFluidSwitcherItemContainer");
        SEL resizeSelector = NSSelectorFromString(@"setAllowedTouchResizeCorners:");
        if (!containerClass || !class_getInstanceMethod(containerClass, resizeSelector)) {
            os_log_error(OS_LOG_DEFAULT,
                         "ExternalStageManager16: resize class or selector unavailable; resize hook not installed");
            return;
        }

        %init(ExternalBottomRightResize);
    }
}
