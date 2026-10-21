// Local behavior backport from 20C65, deliberately restricted to 20B82 backboardd.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <CommonCrypto/CommonDigest.h>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// Stable, zero-initialized C data symbol for bounded debugger memory reads.
// No pointers or Foundation objects occur in this diagnostic ABI.
extern "C" {
struct GuardDiagnostic {
    uint32_t version, size, state, stage, index, reason;
    uint64_t actual, expected, address;
    char className[64], name[192], actualType[192], expectedType[192];
    uint8_t actualUUID[16], expectedUUID[16];
};
__attribute__((visibility("default"), used)) GuardDiagnostic ESMBackboardGuardDiagnostic;
}
static_assert(sizeof(GuardDiagnostic) == 720, "diagnostic ABI size");
static_assert(offsetof(GuardDiagnostic, actual) == 24, "diagnostic ABI values");
static_assert(offsetof(GuardDiagnostic, className) == 48, "diagnostic ABI strings");
static_assert(offsetof(GuardDiagnostic, actualUUID) == 688, "diagnostic ABI UUIDs");

namespace {
enum GuardState : uint32_t { GuardUntouched, GuardChecking, GuardRejected, GuardInstalled };
enum GuardStage : uint32_t { GuardImage = 1, GuardUUID, GuardMethod, GuardClass,
                             GuardIvar, GuardHelper, GuardComplete };
enum GuardReason : uint32_t {
    GuardOK, GuardHeaderMissing, GuardHeaderMagic, GuardImageNameMissing,
    GuardImageNameMismatch, GuardCommandBounds, GuardCommandSize,
    GuardUUIDMissing, GuardUUIDMismatch, GuardMethodMissing, GuardMethodEncoding,
    GuardMethodIMP, GuardDigestMismatch, GuardClassMissing, GuardClassSize,
    GuardSuperclass, GuardIvarMissing, GuardIvarOffset, GuardIvarType, GuardRebaseDelta,
    GuardImageNotFound, GuardImageAmbiguous, GuardImageFileType
};
template <size_t N> static void GuardCopy(char (&out)[N], const char *value) {
    size_t i = 0;
    if (value) for (; i + 1 < N && value[i]; ++i) out[i] = value[i];
    for (; i < N; ++i) out[i] = 0;
}
static void GuardBegin(GuardStage stage, uint32_t index, const char *klass, const char *name) {
    auto &d = ESMBackboardGuardDiagnostic;
    d.version = 1; d.size = sizeof(d); d.state = GuardChecking;
    d.stage = stage; d.index = index; d.reason = GuardOK;
    d.actual = d.expected = d.address = 0;
    GuardCopy(d.className, klass); GuardCopy(d.name, name);
    GuardCopy(d.actualType, nullptr); GuardCopy(d.expectedType, nullptr);
    memset(d.actualUUID, 0, sizeof(d.actualUUID));
    memset(d.expectedUUID, 0, sizeof(d.expectedUUID));
}
static bool GuardReject(GuardReason reason, uint64_t actual = 0, uint64_t expected = 0,
                        const char *actualType = nullptr, const char *expectedType = nullptr) {
    auto &d = ESMBackboardGuardDiagnostic;
    d.actual = actual; d.expected = expected;
    GuardCopy(d.actualType, actualType); GuardCopy(d.expectedType, expectedType);
    d.reason = reason;
    d.state = GuardRejected;
    return false;
}
struct ProcessingInfo {
    int64_t reason, orientation;
    uint64_t timestamp, scrollTimestamp;
    CGPoint unaccelerated, accelerated;
    __unsafe_unretained id sender, deliveryPolicy;
    bool needsHitTest;
};
static_assert(offsetof(ProcessingInfo, timestamp) == 0x10, "20B82 timestamp");
static_assert(offsetof(ProcessingInfo, needsHitTest) == 0x50, "20B82 hit test flag");
static_assert(sizeof(ProcessingInfo) == 0x58, "20B82 processing ABI");
using ProcessFn = void (*)(id, SEL, uint64_t, bool);
using DetermineFn = void (*)(id, SEL, CGPoint, id, ProcessingInfo *, id *, id *, id *);
using ExitFn = void (*)(id, SEL, id, id, bool, uint64_t, id);
using ClearSenderFn = void (*)(id, id);
static ProcessFn originalProcess;
static DetermineFn originalDetermine;
static ExitFn originalExit;
static ClearSenderFn clearSender;
static uintptr_t reasonReturnAddress;
static Ivar accumulatorIvar, routesIvar, pinnedIvar, destinationIvar, senderIvar, displayIvar;
static ptrdiff_t withinOffset;

static uintptr_t CodeAddress(const void *p) {
#if __has_feature(ptrauth_calls)
    return reinterpret_cast<uintptr_t>(ptrauth_strip(p, ptrauth_key_function_pointer));
#else
    return reinterpret_cast<uintptr_t>(p);
#endif
}
struct ProcessScope {
    __unsafe_unretained id controller;
    uint64_t timestamp;
    bool bridged;
    ProcessScope *previous;
};
static thread_local ProcessScope *activeProcess;

static void Process(id self, SEL command, uint64_t timestamp, bool disableDelta) {
    ProcessScope scope{self, timestamp, false, activeProcess};
    activeProcess = &scope;
    @try {
        // Native code asserts the lock, computes hit test point, sends global and
        // pinned end input, then calls exit when the corrected reason is 1.
        originalProcess(self, command, timestamp, disableDelta);
    } @finally {
        activeProcess = scope.previous;
    }
}

static void BridgeReasonIfEligible(id self, ProcessingInfo *info, uintptr_t caller) {
    ProcessScope *scope = activeProcess;
    if (scope && scope->controller == self && !scope->bridged && info &&
        info->timestamp == scope->timestamp && caller == reasonReturnAddress) {
        scope->bridged = true;
        id accumulator = object_getIvar(self, accumulatorIvar);
        // hitTestReason is a pure native getter; its sender lock and button
        // conditions remain authoritative. Zero keeps the original 4/5 fallback.
        int64_t reason = ((int64_t (*)(id, SEL))objc_msgSend)(accumulator,
                                                        @selector(hitTestReason));
        if (reason != 0) {
            info->reason = reason;
            info->needsHitTest = true;
        }
    }
}

static void Determine(id self, SEL command, CGPoint point, id display,
                      ProcessingInfo *info, id *entered, id *within, id *exited) {
    BridgeReasonIfEligible(self, info, CodeAddress(__builtin_return_address(0)));
    originalDetermine(self, command, point, display, info, entered, within, exited);
}

static void Exit(id self, SEL command, id onlyDisplay, id exceptDisplay,
                 bool exitPinned, uint64_t timestamp, id poster) {
    // Preserve the native fatal precondition, including its diagnostic.
    if (onlyDisplay && exceptDisplay) {
        originalExit(self, command, onlyDisplay, exceptDisplay, exitPinned, timestamp, poster);
        return;
    }
    NSDictionary *routes = object_getIvar(self, routesIvar);
    for (id routeSet in [routes allValues]) {
        for (id route in routeSet) {
            if (!route) continue;
            bool *within = reinterpret_cast<bool *>(
                reinterpret_cast<uint8_t *>((__bridge void *)route) + withinOffset);
            // Both native versions check this BEFORE checking pin membership.
            if (!*within) continue;
            id destination = object_getIvar(route, destinationIvar);
            const bool wasPinned = [(NSSet *)object_getIvar(self, pinnedIvar) containsObject:destination];
            if (wasPinned && !exitPinned) continue;
            if (!destination || !object_getIvar(destination, senderIvar)) continue;
            NSString *displayUUID = object_getIvar(destination, displayIvar);
            NSString *effectiveDisplay = [displayUUID length] ? displayUUID : @"<main>";
            if (onlyDisplay && ![effectiveDisplay isEqual:onlyDisplay]) continue;
            if (exceptDisplay && [effectiveDisplay isEqual:exceptDisplay]) continue;
            int64_t orientation = ((int64_t (*)(id, SEL, id))objc_msgSend)(
                self, @selector(_locked_orientationForDisplayUUID:), effectiveDisplay);
            *within = false;
            using EventFn = void *(*)(id, SEL, int64_t, int64_t, uint64_t, id,
                                      CGPoint, CGPoint, id);
            void *event = ((EventFn)objc_msgSend)(self, sel_registerName(
                "_locked_eventWithContextType:contextMove:timestamp:eventContext:unacceleratedRelativePoint:acceleratedRelativePoint:poster:"),
                2, 2, timestamp, destination, CGPointZero, CGPointZero, poster);
            id accumulator = object_getIvar(self, accumulatorIvar);
            using AppendFn = void (*)(id, SEL, uint64_t, void *, int64_t, uint64_t *);
            ((AppendFn)objc_msgSend)(accumulator, sel_registerName(
                "appendSubeventsForEventTypeMask:toTopLevelEvent:interfaceOrientation:getEventSummary:"),
                0x8f4, event, orientation, nullptr);
            // Same strong-store helper used by the 20B82 original implementation.
            clearSender(destination, nil);
            if (wasPinned) {
                // Read controller's current collection again, as 20C65 does.
                [(NSMutableSet *)object_getIvar(self, pinnedIvar) removeObject:destination];
            }
        }
    }
}

struct MethodContract {
    const char *className, *selector, *encoding;
    uintptr_t address;
    size_t size;
    const char *sha256;
};
static const MethodContract methodContracts[] = {
    {"BKMousePointerController", "_locked_exitGlobalContextsOnlyOnDisplayUUID:exceptDisplayUUID:exitPinned:timestamp:eventPoster:",
     "v52@0:8@16@24B32Q36@44", 0x100053328, 0x3dc,
     "b401faa5b801812885e22c6162026170448225b0da5588cb068633490deb50c0"},
    {"BKMousePointerController", "_locked_processOneAccumulatedEventAtTimestamp:shouldDisableDeltaPointerLocationUpdate:",
     "v28@0:8Q16B24", 0x10004f6a0, 0x308,
     "36aded30c92f459b57556d2ecc796d89ef832bdbf6e2a2551054aa9901cc926d"},
    {"BKMousePointerController", "_determineContextsAtHitTestPoint:display:processingInfo:entered:within:exited:",
     "v72@0:8{CGPoint=dd}16@32^{?=qqQQ{CGPoint=dd}{CGPoint=dd}@@B}40^@48^@56^@64", 0x100050cdc, 0x15c,
     "b073253f8ccf72421b159f9af0d99cdea0c1413229178a19e4232a86a5d57697"},
    {"BKMousePointerController", "_locked_orientationForDisplayUUID:", "q24@0:8@16", 0x100052340, 0x74,
     "31123732c568b44c1ca35e3bd774d2478a800faa654d14f83d92ded79162bcf0"},
    {"BKMousePointerController", "_locked_eventWithContextType:contextMove:timestamp:eventContext:unacceleratedRelativePoint:acceleratedRelativePoint:poster:",
     "^{__IOHIDEvent=}88@0:8q16q24Q32@40{CGPoint=dd}48{CGPoint=dd}64@80", 0x100051c4c, 0xe4,
     "d7c72f23bf642de2ac9191c8ac2ae81630928aa97761fbd8423c7ef8204313db"},
    {"BKMouseEventAccumulator", "hitTestReason", "q16@0:8", 0x10006c660, 0x60,
     "82d6cea4ea212fdb74da8bdd4ea8147dedbd6aa829ebdfd6a366c6da9419e563"},
    {"BKMouseEventAccumulator", "appendSubeventsForEventTypeMask:toTopLevelEvent:interfaceOrientation:getEventSummary:",
     "v48@0:8Q16^{__IOHIDEvent=}24q32^Q40", 0x10006ae50, 0x5a8,
     "99b50a68f8c43ac0ffb7721ade1618795d3ddf885007c87c6219421b72615f97"},
};
static bool DigestMatches(uintptr_t address, size_t size, const char *expected) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(reinterpret_cast<const void *>(address), (CC_LONG)size, digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < sizeof(digest); ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    if (strcmp(hex, expected)) {
        ESMBackboardGuardDiagnostic.address = address;
        return GuardReject(GuardDigestMismatch, size, size, hex, expected);
    }
    return true;
}
static bool CheckIvar(Class klass, const char *name, ptrdiff_t offset,
                      const char *type, Ivar *out = nullptr, uint32_t index = 0) {
    GuardBegin(GuardIvar, index, class_getName(klass), name);
    Ivar ivar = class_getInstanceVariable(klass, name);
    if (!ivar) return GuardReject(GuardIvarMissing, 0, offset, nullptr, type);
    const ptrdiff_t actualOffset = ivar_getOffset(ivar);
    if (actualOffset != offset) return GuardReject(GuardIvarOffset, actualOffset, offset,
                                                 ivar_getTypeEncoding(ivar), type);
    const char *actualType = ivar_getTypeEncoding(ivar);
    if (!actualType || strcmp(actualType, type))
        return GuardReject(GuardIvarType, actualOffset, offset, actualType, type);
    if (out) *out = ivar;
    return true;
}
static bool CheckClassSize(Class klass, const char *name, size_t expected, uint32_t index) {
    GuardBegin(GuardClass, index, name, "instanceSize");
    if (!klass) return GuardReject(GuardClassMissing, 0, expected);
    const size_t actual = class_getInstanceSize(klass);
    if (actual != expected) return GuardReject(GuardClassSize, actual, expected);
    return true;
}
static bool CheckSuperclass(Class klass, Class expected, const char *name, uint32_t index) {
    GuardBegin(GuardClass, index, name, "superclass");
    Class actual = class_getSuperclass(klass);
    if (actual != expected)
        return GuardReject(GuardSuperclass, reinterpret_cast<uintptr_t>(actual),
                           reinterpret_cast<uintptr_t>(expected), class_getName(actual),
                           class_getName(expected));
    return true;
}
static bool CheckMethod(const MethodContract &c, intptr_t slide, uint32_t index) {
    GuardBegin(GuardMethod, index, c.className, c.selector);
    Class klass = objc_getClass(c.className);
    if (!klass) return GuardReject(GuardClassMissing, 0, c.address + slide, nullptr, c.encoding);
    Method m = class_getInstanceMethod(klass, sel_registerName(c.selector));
    if (!m) return GuardReject(GuardMethodMissing, 0, c.address + slide, nullptr, c.encoding);
    const char *encoding = method_getTypeEncoding(m);
    if (!encoding || strcmp(encoding, c.encoding))
        return GuardReject(GuardMethodEncoding, 0, 0, encoding, c.encoding);
    const uintptr_t actual = CodeAddress(reinterpret_cast<const void *>(method_getImplementation(m)));
    if (actual != c.address + slide)
        return GuardReject(GuardMethodIMP, actual, c.address + slide, encoding, c.encoding);
    return DigestMatches(c.address + slide, c.size, c.sha256);
}
// BKMouseDestination was compiled with instanceStart=0x8 although its runtime
// superclass occupies 0x18. objc realizes/rebases its declared ivars by +0x10.
// Live 20B82 evidence independently observed display=0x28, sender=0x30, point=0x48.
static bool CheckDestinationLayout(Class destination, Class base) {
    Class object = objc_getClass("NSObject");
    if (!destination) {
        GuardBegin(GuardClass, 2, "BKMouseDestination", "class");
        return GuardReject(GuardClassMissing);
    }
    if (!base) {
        GuardBegin(GuardClass, 4, "BKCAContextDestination", "class");
        return GuardReject(GuardClassMissing);
    }
    if (!CheckSuperclass(destination, base, "BKMouseDestination", 2)) return false;
    if (!CheckSuperclass(base, object, "BKCAContextDestination", 4)) return false;
    if (!CheckClassSize(object, "NSObject", 0x8, 5)) return false;
    if (!CheckClassSize(base, "BKCAContextDestination", 0x18, 4)) return false;
    if (!CheckClassSize(destination, "BKMouseDestination", 0x58, 2)) return false;
    if (!CheckIvar(base,"_contextID",0x8,"I",nullptr,0)) return false;
    if (!CheckIvar(base,"_clientPort",0xc,"I",nullptr,1)) return false;
    if (!CheckIvar(base,"_inheritedSceneHostSettings",0x10,"@\"BKSSceneHostSettings\"",nullptr,2)) return false;
    // Permit precisely the evidenced +0x10 rebasing, never arbitrary offsets.
    const ptrdiff_t delta = (ptrdiff_t)class_getInstanceSize(base) - 0x8;
    if (!(delta == 0x10)) {
        GuardBegin(GuardClass, 2, "BKMouseDestination", "rebaseDelta");
        return GuardReject(GuardRebaseDelta, delta, 0x10);
    }
    return CheckIvar(destination,"_suppressContinuingScrollEvents",0x8 + delta,"B",nullptr,3) &&
        CheckIvar(destination,"_slotID",0xc + delta,"I",nullptr,4) &&
        CheckIvar(destination,"_cachedPID",0x10 + delta,"i",nullptr,5) &&
        CheckIvar(destination,"_displayUUID",0x18 + delta,"@\"NSString\"",&displayIvar,6) &&
        CheckIvar(destination,"_senderInfo",0x20 + delta,"@\"<BKHIDEventSenderInfo>\"",&senderIvar,7) &&
        CheckIvar(destination,"_hitTestInformationAtButtonDown",0x28 + delta,"@\"BKSHIDEventHitTestLayerInformation\"",nullptr,8) &&
        CheckIvar(destination,"_configuration",0x30 + delta,"@\"BKMousePointerControllerConfiguration\"",nullptr,9) &&
        CheckIvar(destination,"_hitTestPoint",0x38 + delta,"{CGPoint=\"x\"d\"y\"d}",nullptr,10);
}
static bool CheckImage(const mach_header *header, const char *imageName) {
    GuardBegin(GuardImage, 0, nullptr, imageName);
    if (!header) return GuardReject(GuardHeaderMissing);
    if (header->magic != MH_MAGIC_64)
        return GuardReject(GuardHeaderMagic, header->magic, MH_MAGIC_64);
    if (!imageName) return GuardReject(GuardImageNameMissing, 0, 0, nullptr, "backboardd");
    const char *basename = strrchr(imageName, '/') ? strrchr(imageName, '/') + 1 : imageName;
    if (strcmp(basename, "backboardd"))
        return GuardReject(GuardImageNameMismatch, 0, 0, basename, "backboardd");
    if (header->filetype != MH_EXECUTE)
        return GuardReject(GuardImageFileType, header->filetype, MH_EXECUTE);
    return true;
}
struct NativeImage {
    const mach_header *header;
    intptr_t slide;
};
// Injected images can occupy index zero. Always take header and slide from
// the same uniquely named executable entry; UUID/code guards still follow.
static bool FindBackboardImage(uint32_t count,
                               const mach_header *(*headerAt)(uint32_t),
                               const char *(*nameAt)(uint32_t),
                               intptr_t (*slideAt)(uint32_t), NativeImage *out) {
    GuardBegin(GuardImage, 0, nullptr, "backboardd");
    uint32_t selected = UINT32_MAX;
    for (uint32_t i = 0; i < count; ++i) {
        const char *name = nameAt(i);
        if (!name) continue;
        const char *base = strrchr(name, '/');
        if (strcmp(base ? base + 1 : name, "backboardd")) continue;
        if (selected != UINT32_MAX)
            return GuardReject(GuardImageAmbiguous, i, selected);
        selected = i;
    }
    if (selected == UINT32_MAX) return GuardReject(GuardImageNotFound, count);
    const mach_header *header = headerAt(selected);
    if (!CheckImage(header, nameAt(selected))) return false;
    *out = {header, slideAt(selected)};
    return true;
}
static bool CheckUUID(const mach_header *header) {
    GuardBegin(GuardUUID, 0, nullptr, "LC_UUID");
    const uint8_t expectedUUID[16] = {0x6e,0x8e,0x86,0x88,0xd4,0xd8,0x3c,0x7e,0x97,0xcf,0x05,0x1a,0x20,0x38,0x95,0x2d};
    memcpy(ESMBackboardGuardDiagnostic.expectedUUID, expectedUUID, sizeof(expectedUUID));
    const mach_header_64 *h = reinterpret_cast<const mach_header_64 *>(header);
    const uint8_t *command = reinterpret_cast<const uint8_t *>(h + 1);
    const uint8_t *end = command + h->sizeofcmds;
    bool uuidMatches = false;
    bool uuidFound = false;
    uint32_t uuidIndex = 0;
    uintptr_t uuidAddress = 0;
    for (uint32_t i = 0; i < h->ncmds; ++i) {
        ESMBackboardGuardDiagnostic.index = i;
        if (size_t(end - command) < sizeof(load_command))
            return GuardReject(GuardCommandBounds, size_t(end - command), sizeof(load_command));
        const load_command *lc = reinterpret_cast<const load_command *>(command);
        ESMBackboardGuardDiagnostic.address = reinterpret_cast<uintptr_t>(command);
        if (lc->cmdsize < sizeof(*lc))
            return GuardReject(GuardCommandSize, lc->cmdsize, sizeof(*lc));
        if (size_t(end - command) < lc->cmdsize)
            return GuardReject(GuardCommandBounds, size_t(end - command), lc->cmdsize);
        if (lc->cmd == LC_UUID && lc->cmdsize == sizeof(uuid_command)) {
            uuidFound = true;
            uuidIndex = i;
            uuidAddress = reinterpret_cast<uintptr_t>(command);
            memcpy(ESMBackboardGuardDiagnostic.actualUUID,
                   reinterpret_cast<const uuid_command *>(lc)->uuid, sizeof(expectedUUID));
            uuidMatches = !memcmp(reinterpret_cast<const uuid_command *>(lc)->uuid, expectedUUID, 16);
        }
        command += lc->cmdsize;
    }
    if (!uuidMatches) {
        ESMBackboardGuardDiagnostic.index = uuidIndex;
        ESMBackboardGuardDiagnostic.address = uuidAddress;
        return GuardReject(uuidFound ? GuardUUIDMismatch : GuardUUIDMissing);
    }
    return true;
}
static bool Install() {
    NativeImage image{};
    if (!FindBackboardImage(_dyld_image_count(), _dyld_get_image_header,
                           _dyld_get_image_name, _dyld_get_image_vmaddr_slide, &image)) return false;
    if (!CheckUUID(image.header)) return false;
    const intptr_t slide = image.slide;
    for (uint32_t i = 0; i < sizeof(methodContracts) / sizeof(methodContracts[0]); ++i)
        if (!CheckMethod(methodContracts[i], slide, i)) return false;
    Class controller = objc_getClass("BKMousePointerController");
    Class route = objc_getClass("_BKMouseEventGlobalRoute");
    Class destination = objc_getClass("BKMouseDestination");
    Class accumulator = objc_getClass("BKMouseEventAccumulator");
    if (!CheckClassSize(controller, "BKMousePointerController", 0x170, 0)) return false;
    if (!CheckClassSize(route, "_BKMouseEventGlobalRoute", 0x20, 1)) return false;
    if (!CheckClassSize(accumulator, "BKMouseEventAccumulator", 0x2d0, 3)) return false;
    if (!CheckSuperclass(controller, objc_getClass("NSObject"), "BKMousePointerController", 0)) return false;
    if (!CheckSuperclass(route, objc_getClass("NSObject"), "_BKMouseEventGlobalRoute", 1)) return false;
    if (!CheckSuperclass(accumulator, objc_getClass("NSObject"), "BKMouseEventAccumulator", 3)) return false;
    if (!CheckDestinationLayout(destination, objc_getClass("BKCAContextDestination"))) return false;
    if (!CheckIvar(controller,"_eventAccumulator",0x98,"@\"BKMouseEventAccumulator\"",&accumulatorIvar,11)) return false;
    if (!CheckIvar(controller,"_globalEventRoutesByDisplayID",0x138,"@\"NSMutableDictionary\"",&routesIvar,12)) return false;
    if (!CheckIvar(controller,"_globalContextsPinnedByMouse",0x140,"@\"NSMutableSet\"",&pinnedIvar,13)) return false;
    if (!CheckIvar(route,"_destination",0x18,"@\"BKMouseDestination\"",&destinationIvar,14)) return false;
    if (!CheckIvar(route,"_withinContext",0x8,"B",nullptr,15)) return false;
    if (!CheckIvar(accumulator,"_buttonMask",0x2a0,"I",nullptr,16)) return false;
    if (!CheckIvar(accumulator,"_previousButtonMask",0x2bc,"I",nullptr,17)) return false;
    if (!CheckIvar(accumulator,"_mostRecentSender",0x2c8,"@\"<BKHIDEventSenderInfo>\"",nullptr,18)) return false;
    GuardBegin(GuardHelper, 0, "BKMouseDestination", "clearSender");
    if (!DigestMatches(0x100010810 + slide, 0x18,
                       "df1501555f69a665832b52a3c72c131746d38c37cf24e724552c8e8d64f9f212")) return false;
    withinOffset = 0x8;
    void *helper = reinterpret_cast<void *>(0x100010810 + slide);
#if __has_feature(ptrauth_calls)
    helper = ptrauth_sign_unauthenticated(helper, ptrauth_key_function_pointer, 0);
#endif
    clearSender = reinterpret_cast<ClearSenderFn>(helper);
    reasonReturnAddress = 0x10004f820 + slide;
    // All rejection paths precede hook/native-state mutation. Methods are owned by this class.
    Method exit = class_getInstanceMethod(controller, sel_registerName(methodContracts[0].selector));
    Method process = class_getInstanceMethod(controller, sel_registerName(methodContracts[1].selector));
    Method determine = class_getInstanceMethod(controller, sel_registerName(methodContracts[2].selector));
    originalExit = reinterpret_cast<ExitFn>(method_getImplementation(exit));
    originalProcess = reinterpret_cast<ProcessFn>(method_getImplementation(process));
    originalDetermine = reinterpret_cast<DetermineFn>(method_getImplementation(determine));
    method_setImplementation(exit, reinterpret_cast<IMP>(Exit));
    method_setImplementation(determine, reinterpret_cast<IMP>(Determine));
    method_setImplementation(process, reinterpret_cast<IMP>(Process));
    GuardBegin(GuardComplete, 0, nullptr, "installed");
    ESMBackboardGuardDiagnostic.state = GuardInstalled;
    return true;
}
} // namespace

extern "C" bool ESMInstallBackboardRouting(void) {
    static bool installed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ installed = Install(); });
    return installed;
}
