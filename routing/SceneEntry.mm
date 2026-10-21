#import "ModuleOptions.h"
extern "C" bool ESMInstallSceneMenuRouting(void);
extern "C" bool ESMInstallSidebarScope(void);

__attribute__((constructor)) static void ESMSceneEntry(void) {
    @autoreleasepool {
        NSDictionary *options = ESMReadOptions((const void *)&ESMSceneEntry);
        if (ESMOption(options, @"SceneMenus"))
            NSLog(@"[ESMRouting] SceneMenus %@", ESMInstallSceneMenuRouting() ? @"installed" : @"guard rejected");
        if (ESMOption(options, @"SidebarDisplayScope"))
            NSLog(@"[ESMRouting] SidebarDisplayScope %@", ESMInstallSidebarScope() ? @"installed" : @"guard rejected");
    }
}
