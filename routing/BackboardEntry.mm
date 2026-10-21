#import "ModuleOptions.h"
extern "C" bool ESMInstallBackboardRouting(void);

__attribute__((constructor)) static void ESMBackboardEntry(void) {
    @autoreleasepool {
        NSDictionary *options = ESMReadOptions((const void *)&ESMBackboardEntry);
        if (ESMOption(options, @"PointerRouting"))
            NSLog(@"[ESMRouting] PointerRouting %@", ESMInstallBackboardRouting() ? @"installed" : @"guard rejected");
    }
}
