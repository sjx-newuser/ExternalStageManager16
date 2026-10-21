#pragma once
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <cstring>

// The package's MobileSubstrate directory can be a symlink to usr/lib/TweakInject.
// dladdr reports the loader's path, not necessarily the package's install path.
// Preserve the actual rootless prefix; never embed a particular preboot UUID.
static inline NSString *ESMOptionsPathForImage(NSString *imagePath) {
    if (![imagePath isAbsolutePath]) return nil;
    NSString *directory = [[imagePath stringByStandardizingPath] stringByDeletingLastPathComponent];
    for (NSString *suffix in @[@"/Library/MobileSubstrate/DynamicLibraries", @"/usr/lib/TweakInject"]) {
        if ([directory hasSuffix:suffix]) {
            NSString *root = [directory substringToIndex:directory.length - suffix.length];
            if (!root.length) root = @"/";
            return [root stringByAppendingPathComponent:
                @"Library/Application Support/ExternalStageManager16Routing/Modules.plist"];
        }
    }
    return nil;
}

// Read-only, once at process start. Missing/malformed options fail closed.
static inline NSDictionary *ESMReadOptions(const void *imageAnchor) {
    char build[64] = {};
    size_t count = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &count, nullptr, 0) != 0 ||
        count == 0 || count > sizeof(build) || build[count - 1] != '\0' ||
        strcmp(build, "20B82") != 0) {
        NSLog(@"[ESMRouting] unsupported build; no module enabled");
        return nil;
    }
    Dl_info info = {};
    if (!dladdr(imageAnchor, &info) || !info.dli_fname) return nil;
    NSString *path = ESMOptionsPathForImage([NSString stringWithUTF8String:info.dli_fname]);
    if (!path) {
        NSLog(@"[ESMRouting] unrecognized image location; no module enabled");
        return nil;
    }
    NSDictionary *options = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![options isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ESMRouting] options absent/invalid at %@; no module enabled", path);
        return nil;
    }
    NSLog(@"[ESMRouting] options loaded from %@", path);
    return options;
}

static inline bool ESMOption(NSDictionary *options, NSString *name) {
    id value = options[name];
    return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() &&
           [value boolValue];
}
