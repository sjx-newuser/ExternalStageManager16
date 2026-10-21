// 20B82 only. See sidebar-scope.md for the binary and UIKit contracts.
#import <Foundation/Foundation.h>
#include <substrate.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <cstring>
#include <cstdlib>
#include <unistd.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif
#include "sidebar-scope-policy.h"

namespace {
using HoverMoved = void (*)(id, SEL, id, id);
using CancelDisplay = void (*)(CFStringRef);
static HoverMoved originalHover;
static CancelDisplay originalCancel;
static uintptr_t expectedReturn;
static bool installed;
static thread_local esm_sidebar::Scope *currentScope;

static uintptr_t CodeAddress(const void *p) {
#if __has_feature(ptrauth_calls)
    p = ptrauth_strip(p, ptrauth_key_function_pointer);
#endif
    return reinterpret_cast<uintptr_t>(p);
}
static bool HasObjectReturn(id object, SEL selector) {
    if (!object) return false;
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return false;
    char *type = method_copyReturnType(method);
    const bool ok = type && type[0] == '@';
    free(type);
    return ok;
}
static id ObjectGetter(id object, const char *name, bool *valid) {
    SEL selector = sel_registerName(name);
    if (!HasObjectReturn(object, selector)) { *valid = false; return nil; }
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

[[noreturn]] static void FatalHookFailure() {
    // An altered entry without a trampoline is an installation failure, not a
    // rejected guard. Continuing could recurse or call NULL; fail explicitly.
    static const char message[] = "[ExternalStageManager16] FATAL: sidebar BKS hook has no original trampoline\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    abort();
}

__attribute__((noinline)) static void ScopedCancel(CFStringRef display) {
    // MainDisplay and its SpringBoard stub are tail branches, so LR remains
    // _hoverMoved+0x428. Read LR here, never in a helper's stack frame.
    const uintptr_t caller = CodeAddress(__builtin_extract_return_addr(
                                         __builtin_return_address(0)));
    if (!originalCancel) FatalHookFailure();
    if (!esm_sidebar::ShouldSubstitute(currentScope, display, caller, expectedReturn)) {
        originalCancel(display);
        return;
    }
    // Resolve at the actual cancellation point, matching 16.2's ordering.
    // Getter failure preserves 16.1's original request. nil configuration or
    // identifier has the same BKS main-display meaning as the old nil argument.
    bool valid = true;
    id recognizer = (__bridge id)currentScope->recognizer;
    id view = ObjectGetter(recognizer, "containerView", &valid);
    id config = view ? ObjectGetter(view, "_fbsDisplayConfiguration", &valid) : nil;
    id identifier = config ? ObjectGetter(config, "hardwareIdentifier", &valid) : nil;
    if (identifier && ![identifier isKindOfClass:[NSString class]]) valid = false;
    if (valid) originalCancel((__bridge CFStringRef)identifier);
    else originalCancel(display);
}

static void ScopedHoverMoved(id self, SEL cmd, id touch, id event) {
    esm_sidebar::Scope scope{(__bridge void *)self, currentScope};
    currentScope = &scope;
    @try {
        originalHover(self, cmd, touch, event);
    } @finally {
        // Restore enclosing invocation on same-thread reentry and exceptions.
        currentScope = scope.previous;
    }
}

struct Image { intptr_t slide; const mach_header_64 *header; };
static bool FindImage(const char *suffix, const uint8_t uuid[16], Image *out) {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t n = strlen(name), s = strlen(suffix);
        if (n < s || strcmp(name + n - s, suffix)) continue;
        const auto *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        if (!header || header->magic != MH_MAGIC_64) return false;
        const uint8_t *p = reinterpret_cast<const uint8_t *>(header + 1);
        const uint8_t *end = p + header->sizeofcmds;
        for (uint32_t j = 0; j < header->ncmds; ++j) {
            if (end - p < (ptrdiff_t)sizeof(load_command)) return false;
            const auto *cmd = reinterpret_cast<const load_command *>(p);
            if (cmd->cmdsize < sizeof(load_command) || cmd->cmdsize > size_t(end - p)) return false;
            if (cmd->cmd == LC_UUID && cmd->cmdsize >= sizeof(uuid_command)) {
                if (memcmp(reinterpret_cast<const uuid_command *>(p)->uuid, uuid, 16)) return false;
                *out = {_dyld_get_image_vmaddr_slide(i), header};
                return true;
            }
            p += cmd->cmdsize;
        }
        return false;
    }
    return false;
}
static bool Bytes(uintptr_t address, const uint8_t *expected, size_t count) {
    return memcmp(reinterpret_cast<const void *>(address), expected, count) == 0;
}
static bool Hash(uintptr_t address, size_t size, const char *expected) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(reinterpret_cast<const void *>(address), (CC_LONG)size, digest);
    static const char hex[] = "0123456789abcdef";
    char actual[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < sizeof(digest); ++i) {
        actual[i * 2] = hex[digest[i] >> 4]; actual[i * 2 + 1] = hex[digest[i] & 15];
    }
    actual[sizeof(actual) - 1] = 0;
    return strcmp(actual, expected) == 0;
}
static bool HoverSignature(Method method) {
    if (!method || method_getNumberOfArguments(method) != 4) return false;
    char *result = method_copyReturnType(method);
    bool ok = result && !strcmp(result, "v"); free(result);
    for (unsigned i = 0; i < 4 && ok; ++i) {
        char *arg = method_copyArgumentType(method, i);
        ok = arg && arg[0] == (i == 1 ? ':' : '@'); free(arg);
    }
    return ok;
}
} // namespace

extern "C" bool ESMInstallSidebarScope(void) {
    // Entry owner must serialize startup on SpringBoard's main thread.
    if (![NSThread isMainThread]) return false;
    if (installed) return true;
    if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return false;
    char build[64] = {}; size_t length = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &length, nullptr, 0) || strcmp(build, "20B82")) return false;
    static const uint8_t sbUUID[] = {0xec,0xd3,0xe9,0xa8,0xc6,0x38,0x36,0x74,0xba,0x49,0x61,0x55,0xd8,0xdc,0x97,0x35};
    static const uint8_t bksUUID[] = {0xdd,0xa5,0x58,0x7e,0xe1,0xdc,0x33,0x9b,0xb1,0xae,0x85,0x43,0xb4,0xb3,0x30,0xa6};
    Image sb{}, bks{};
    if (!FindImage("/SpringBoard.framework/SpringBoard", sbUUID, &sb) ||
        !FindImage("/BackBoardServices.framework/BackBoardServices", bksUUID, &bks)) return false;
    const uintptr_t hover = 0x1c69fad14ULL + sb.slide;
    const uintptr_t cancel = 0x18e3cdb78ULL + bks.slide;
    Class cls = objc_getClass("SBIndirectPanGestureRecognizer");
    SEL selector = sel_registerName("_hoverMoved:withEvent:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : nullptr;
    if (!HoverSignature(method) || CodeAddress((const void *)method_getImplementation(method)) != hover) return false;
    void *exported = dlsym(RTLD_DEFAULT, "BKSHIDServicesCancelTouchesOnDisplay");
    if (CodeAddress(exported) != cancel) return false;
    static const uint8_t stub[] = {0xd0,0x54,0xe2,0x90,0x10,0x32,0x39,0x91,0x00,0x02,0x1f,0xd6};
    static const uint8_t wrapper[] = {0x00,0x00,0x80,0xd2,0x4a,0x1b,0x00,0x14};
    static const uint8_t call[] = {0x06,0xcc,0xbc,0x94};
    if (!Bytes(0x1c992e150ULL + sb.slide, stub, sizeof(stub)) ||
        !Bytes(0x18e3c6e4cULL + bks.slide, wrapper, sizeof(wrapper)) ||
        !Bytes(0x1c69fb138ULL + sb.slide, call, sizeof(call)) ||
        !Hash(hover, 1808, "1185b4b978bdc4360bc88568608374839e185db7dd0957cd4b9cae4cae5dccf7") ||
        !Hash(cancel, 188, "49312e6ea05da17e1f1721280d471f8047dc32ab7156d089e5637e6e637a8761")) return false;
    originalHover = reinterpret_cast<HoverMoved>(method_getImplementation(method));
    expectedReturn = 0x1c69fb13cULL + sb.slide;
    // The method is untouched until the original BKS trampoline exists.
    // Hook engine is required to preserve LR across its entry branch.
    MSHookFunction(exported, reinterpret_cast<void *>(&ScopedCancel), reinterpret_cast<void **>(&originalCancel));
    if (!originalCancel) {
        // A no-op engine refusal is recoverable only while the complete
        // original function remains intact. Do not invent a recursive fallback.
        if (Hash(cancel, 188, "49312e6ea05da17e1f1721280d471f8047dc32ab7156d089e5637e6e637a8761")) return false;
        FatalHookFailure();
    }
    method_setImplementation(method, reinterpret_cast<IMP>(&ScopedHoverMoved));
    installed = true;
    NSLog(@"[ExternalStageManager16] Sidebar cancellation scope installed (20B82)");
    return true;
}
