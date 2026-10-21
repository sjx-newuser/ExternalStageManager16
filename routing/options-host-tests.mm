#import "ModuleOptions.h"
#include <cassert>
#include <cstdio>

static void CheckRoot(NSString *root) {
    NSString *expected = [root stringByAppendingPathComponent:
        @"Library/Application Support/ExternalStageManager16Routing/Modules.plist"];
    for (NSString *directory in @[@"Library/MobileSubstrate/DynamicLibraries", @"usr/lib/TweakInject"])
        for (NSString *name in @[@"ESMSceneRouting.dylib", @"ESMBackboardRouting.dylib"])
            assert([ESMOptionsPathForImage([[root stringByAppendingPathComponent:directory]
                stringByAppendingPathComponent:name]) isEqual:expected]);
}

int main() {
    @autoreleasepool {
        CheckRoot(@"/var/jb");
        CheckRoot(@"/private/preboot/example-boot-id/dopamine-random/procursus");
        CheckRoot(@"/");
        assert(!ESMOptionsPathForImage(nil));
        assert(!ESMOptionsPathForImage(@"relative/usr/lib/TweakInject/a.dylib"));
        assert(!ESMOptionsPathForImage(@"/var/jb/usr/lib/TweakInject-extra/a.dylib"));
        assert(!ESMOptionsPathForImage(@"/tmp/a.dylib"));

        // Reproduce the real package alias -> loader path transformation on disk.
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *root = [[NSTemporaryDirectory() stringByResolvingSymlinksInPath]
            stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        NSString *loader = [root stringByAppendingPathComponent:@"usr/lib/TweakInject"];
        NSString *alias = [root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries"];
        assert([fm createDirectoryAtPath:loader withIntermediateDirectories:YES attributes:nil error:nil]);
        assert([fm createDirectoryAtPath:[alias stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES attributes:nil error:nil]);
        assert([fm createSymbolicLinkAtPath:alias withDestinationPath:@"../../usr/lib/TweakInject" error:nil]);
        NSString *image = [alias stringByAppendingPathComponent:@"ESMSceneRouting.dylib"];
        assert([fm createFileAtPath:image contents:[NSData data] attributes:nil]);
        NSString *resolved = [image stringByResolvingSymlinksInPath];
        assert([resolved isEqual:[loader stringByAppendingPathComponent:@"ESMSceneRouting.dylib"]]);
        NSString *config = ESMOptionsPathForImage(resolved);
        assert([fm createDirectoryAtPath:[config stringByDeletingLastPathComponent]
            withIntermediateDirectories:YES attributes:nil error:nil]);
        NSDictionary *fixture = @{@"SceneMenus": @YES, @"PointerRouting": @YES,
                                   @"SidebarDisplayScope": @NO, @"WrongType": @1};
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:fixture
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        assert(data && [data writeToFile:config atomically:YES]);
        NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:config];
        assert(ESMOption(loaded, @"SceneMenus") && ESMOption(loaded, @"PointerRouting"));
        assert(!ESMOption(loaded, @"SidebarDisplayScope"));
        assert(!ESMOption(loaded, @"WrongType") && !ESMOption(loaded, @"Absent"));
        NSString *oldPath = [[[resolved stringByDeletingLastPathComponent] stringByAppendingPathComponent:
            @"../../Application Support/ExternalStageManager16Routing/Modules.plist"] stringByStandardizingPath];
        assert(![fm fileExistsAtPath:oldPath]);
        assert([fm removeItemAtPath:root error:nil]);
        puts("options host: PASS (package alias, canonical loader path, binary plist, fail-closed options)");
    }
}
