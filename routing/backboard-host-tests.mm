// Executes production exit/bridge/scope code with local Objective-C fixtures.
// Does not claim to execute the arm64e private ABI or run an iPad regression.
#include "BackboardRouting.mm"
#include <cassert>
#include <vector>
#include <string>

static std::vector<std::string> calls;
@interface TestDestination : NSObject { @public id _senderInfo; NSString *_displayUUID; }
@end
@implementation TestDestination
@end
@interface TestRoute : NSObject { @public bool _withinContext; TestDestination *_destination; }
@end
@implementation TestRoute
@end
@interface TestPins : NSMutableSet { NSMutableSet *_backing; }
@end
@implementation TestPins
- (instancetype)init { if ((self = [super init])) _backing = [NSMutableSet set]; return self; }
- (NSUInteger)count { return _backing.count; }
- (NSEnumerator *)objectEnumerator { return _backing.objectEnumerator; }
- (id)member:(id)object { return [_backing member:object]; }
- (void)addObject:(id)object { [_backing addObject:object]; }
- (void)removeObject:(id)object { calls.push_back("unpin"); [_backing removeObject:object]; }
@end
@interface TestAccumulator : NSObject { @public int64_t reason; }
@end
@implementation TestAccumulator
- (int64_t)hitTestReason { calls.push_back("reason"); return reason; }
- (void)appendSubeventsForEventTypeMask:(uint64_t)mask toTopLevelEvent:(void *)event
                 interfaceOrientation:(int64_t)orientation getEventSummary:(uint64_t *)summary {
    assert(mask == 0x8f4 && event == (void *)1 && orientation == 3 && !summary);
    calls.push_back("append");
}
@end
@interface TestController : NSObject {
@public TestAccumulator *_eventAccumulator; NSDictionary *_globalEventRoutesByDisplayID;
    TestPins *_globalContextsPinnedByMouse;
}
@end
@implementation TestController
- (int64_t)_locked_orientationForDisplayUUID:(NSString *)display {
    assert([display isEqual:@"external"] || [display isEqual:@"<main>"]);
    calls.push_back("orientation"); return 3;
}
- (void *)_locked_eventWithContextType:(int64_t)type contextMove:(int64_t)move
 timestamp:(uint64_t)timestamp eventContext:(TestDestination *)destination
 unacceleratedRelativePoint:(CGPoint)unaccelerated acceleratedRelativePoint:(CGPoint)accelerated
 poster:(id)poster {
    assert(type == 2 && move == 2 && timestamp == 100 && destination->_senderInfo);
    assert(CGPointEqualToPoint(unaccelerated, CGPointZero) && CGPointEqualToPoint(accelerated, CGPointZero));
    TestRoute *route = [_globalEventRoutesByDisplayID[@"external"] anyObject];
    assert(!route->_withinContext);
    assert(poster == nil); calls.push_back("exit"); return (void *)1;
}
@end
static void Clear(id destination, id value) {
    assert(value == nil); calls.push_back("clear"); ((TestDestination *)destination)->_senderInfo = nil;
}
static TestController *Fixture(bool pinned, bool within = true, bool sender = true) {
    TestDestination *destination = [TestDestination new];
    destination->_displayUUID = @"external"; destination->_senderInfo = sender ? [NSObject new] : nil;
    TestRoute *route = [TestRoute new]; route->_withinContext = within; route->_destination = destination;
    TestController *controller = [TestController new];
    controller->_eventAccumulator = [TestAccumulator new];
    controller->_globalEventRoutesByDisplayID = @{@"external": [NSSet setWithObject:route]};
    controller->_globalContextsPinnedByMouse = [TestPins new];
    if (pinned) [controller->_globalContextsPinnedByMouse addObject:destination];
    return controller;
}
static TestRoute *Route(TestController *controller) {
    return [controller->_globalEventRoutesByDisplayID[@"external"] anyObject];
}
static void BindFixtureIvars() {
    accumulatorIvar = class_getInstanceVariable([TestController class], "_eventAccumulator");
    routesIvar = class_getInstanceVariable([TestController class], "_globalEventRoutesByDisplayID");
    pinnedIvar = class_getInstanceVariable([TestController class], "_globalContextsPinnedByMouse");
    destinationIvar = class_getInstanceVariable([TestRoute class], "_destination");
    senderIvar = class_getInstanceVariable([TestDestination class], "_senderInfo");
    displayIvar = class_getInstanceVariable([TestDestination class], "_displayUUID");
    withinOffset = ivar_getOffset(class_getInstanceVariable([TestRoute class], "_withinContext"));
    clearSender = Clear; reasonReturnAddress = 0x1234;
}
static void TestRebasedLayout() {
    Class base = objc_allocateClassPair([NSObject class], "BackboardTestBase", 0);
    assert(base);
    assert(class_addIvar(base,"_contextID",4,2,"I"));
    assert(class_addIvar(base,"_clientPort",4,2,"I"));
    assert(class_addIvar(base,"_inheritedSceneHostSettings",8,3,"@\"BKSSceneHostSettings\""));
    objc_registerClassPair(base);
    Class destination = objc_allocateClassPair(base,"BackboardTestDestination",0);
    assert(destination);
    assert(class_addIvar(destination,"_suppressContinuingScrollEvents",1,0,"B"));
    assert(class_addIvar(destination,"_slotID",4,2,"I"));
    assert(class_addIvar(destination,"_cachedPID",4,2,"i"));
    assert(class_addIvar(destination,"_displayUUID",8,3,"@\"NSString\""));
    assert(class_addIvar(destination,"_senderInfo",8,3,"@\"<BKHIDEventSenderInfo>\""));
    assert(class_addIvar(destination,"_hitTestInformationAtButtonDown",8,3,"@\"BKSHIDEventHitTestLayerInformation\""));
    assert(class_addIvar(destination,"_configuration",8,3,"@\"BKMousePointerControllerConfiguration\""));
    assert(class_addIvar(destination,"_hitTestPoint",16,3,"{CGPoint=\"x\"d\"y\"d}"));
    objc_registerClassPair(destination);
    assert(CheckDestinationLayout(destination,base));
    assert(ivar_getOffset(displayIvar) == 0x28 && ivar_getOffset(senderIvar) == 0x30);
    assert(!CheckDestinationLayout(destination,[NSObject class]));
    Class wrong = objc_allocateClassPair(base,"BackboardWrongDestination",0);
    assert(class_addIvar(wrong,"_unexpectedPadding",16,3,"{CGPoint=dd}"));
    objc_registerClassPair(wrong);
    assert(!CheckDestinationLayout(wrong,base));
}
static void AssertRejection(GuardStage stage, uint32_t index, GuardReason reason) {
    const auto &d = ESMBackboardGuardDiagnostic;
    assert(d.version == 1 && d.size == sizeof(GuardDiagnostic));
    assert(d.state == GuardRejected && d.stage == stage && d.index == index && d.reason == reason);
}
static void TestGuardDiagnostic() {
    // Exercise production guard helpers. No duplicate model of their comparisons.
    mach_header_64 header{};
    assert(!CheckImage(nullptr, "backboardd"));
    AssertRejection(GuardImage, 0, GuardHeaderMissing);
    assert(!CheckImage(reinterpret_cast<mach_header *>(&header), "backboardd"));
    AssertRejection(GuardImage, 0, GuardHeaderMagic);
    assert(ESMBackboardGuardDiagnostic.expected == MH_MAGIC_64);
    header.magic = MH_MAGIC_64;
    header.filetype = MH_EXECUTE;
    assert(!CheckImage(reinterpret_cast<mach_header *>(&header), nullptr));
    AssertRejection(GuardImage, 0, GuardImageNameMissing);
    assert(!CheckImage(reinterpret_cast<mach_header *>(&header), "/usr/libexec/wrong"));
    AssertRejection(GuardImage, 0, GuardImageNameMismatch);
    assert(!strcmp(ESMBackboardGuardDiagnostic.actualType, "wrong"));
    assert(CheckImage(reinterpret_cast<mach_header *>(&header), "/usr/libexec/backboardd"));
    assert(!CheckUUID(reinterpret_cast<mach_header *>(&header)));
    AssertRejection(GuardUUID, 0, GuardUUIDMissing);
    struct { mach_header_64 header; uuid_command command; } image{};
    image.header.magic = MH_MAGIC_64; image.header.ncmds = 1;
    image.header.sizeofcmds = sizeof(image.command); image.command.cmd = LC_UUID;
    image.command.cmdsize = sizeof(image.command);
    assert(!CheckUUID(reinterpret_cast<mach_header *>(&image.header)));
    AssertRejection(GuardUUID, 0, GuardUUIDMismatch);
    assert(ESMBackboardGuardDiagnostic.expectedUUID[0] == 0x6e);
    memcpy(image.command.uuid, ESMBackboardGuardDiagnostic.expectedUUID, 16);
    assert(CheckUUID(reinterpret_cast<mach_header *>(&image.header)));
    image.header.sizeofcmds = 4;
    assert(!CheckUUID(reinterpret_cast<mach_header *>(&image.header)));
    AssertRejection(GuardUUID, 0, GuardCommandBounds);
    image.header.sizeofcmds = sizeof(image.command); image.command.cmdsize = 4;
    assert(!CheckUUID(reinterpret_cast<mach_header *>(&image.header)));
    AssertRejection(GuardUUID, 0, GuardCommandSize);
    image.command.cmdsize = sizeof(image.command) + 4;
    assert(!CheckUUID(reinterpret_cast<mach_header *>(&image.header)));
    AssertRejection(GuardUUID, 0, GuardCommandBounds);

    Class klass = [TestAccumulator class];
    Ivar ivar = class_getInstanceVariable(klass, "reason");
    const ptrdiff_t offset = ivar_getOffset(ivar);
    const char *type = ivar_getTypeEncoding(ivar);
    Ivar out = nullptr;
    assert(!CheckIvar(klass, "missing", offset, type, &out, 17) && !out);
    AssertRejection(GuardIvar, 17, GuardIvarMissing);
    assert(!CheckIvar(klass, "reason", offset + 8, type, &out, 18) && !out);
    AssertRejection(GuardIvar, 18, GuardIvarOffset);
    assert(ESMBackboardGuardDiagnostic.actual == (uint64_t)offset);
    assert(ESMBackboardGuardDiagnostic.expected == (uint64_t)offset + 8);
    assert(!CheckIvar(klass, "reason", offset, "wrong", &out, 19) && !out);
    AssertRejection(GuardIvar, 19, GuardIvarType);
    assert(!strcmp(ESMBackboardGuardDiagnostic.actualType, type));
    assert(!strcmp(ESMBackboardGuardDiagnostic.expectedType, "wrong"));
    assert(CheckIvar(klass, "reason", offset, type, &out, 20) && out == ivar);
    assert(ESMBackboardGuardDiagnostic.reason == GuardOK);
    assert(ESMBackboardGuardDiagnostic.actualType[0] == 0); // no stale prior failure
    assert(!CheckClassSize(klass, "TestAccumulator", class_getInstanceSize(klass) + 8, 3));
    AssertRejection(GuardClass, 3, GuardClassSize);
    assert(!CheckClassSize(Nil, "MissingClass", 8, 4));
    AssertRejection(GuardClass, 4, GuardClassMissing);
    assert(!CheckSuperclass(klass, [TestController class], "TestAccumulator", 3));
    AssertRejection(GuardClass, 3, GuardSuperclass);
    assert(!strcmp(ESMBackboardGuardDiagnostic.actualType, "NSObject"));

    Method method = class_getInstanceMethod(klass, @selector(hitTestReason));
    const uintptr_t address = CodeAddress(reinterpret_cast<const void *>(method_getImplementation(method)));
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    CC_SHA256(reinterpret_cast<const void *>(address), 4, digest);
    for (size_t i = 0; i < sizeof(digest); ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    MethodContract contract{"ESMDefinitelyMissingGuardFixture", "missingMethod", method_getTypeEncoding(method), address, 4, hex};
    assert(!CheckMethod(contract, 0, 6)); AssertRejection(GuardMethod, 6, GuardClassMissing);
    contract.className = "TestAccumulator";
    assert(!CheckMethod(contract, 0, 6)); AssertRejection(GuardMethod, 6, GuardMethodMissing);
    contract.selector = "hitTestReason"; contract.encoding = "wrong";
    assert(!CheckMethod(contract, 0, 6)); AssertRejection(GuardMethod, 6, GuardMethodEncoding);
    contract.encoding = method_getTypeEncoding(method); contract.address = address + 4;
    assert(!CheckMethod(contract, 0, 6)); AssertRejection(GuardMethod, 6, GuardMethodIMP);
    assert(ESMBackboardGuardDiagnostic.actual == address);
    contract.address = address; contract.sha256 = "wrong";
    assert(!CheckMethod(contract, 0, 6)); AssertRejection(GuardMethod, 6, GuardDigestMismatch);
    assert(!strcmp(ESMBackboardGuardDiagnostic.actualType, hex));
    assert(ESMBackboardGuardDiagnostic.address == address);
    contract.sha256 = hex; assert(CheckMethod(contract, 0, 6));
    GuardBegin(GuardHelper, 0, "TestAccumulator", "clearSender");
    assert(!DigestMatches(address, 4, "wrong"));
    AssertRejection(GuardHelper, 0, GuardDigestMismatch);
    char large[400]; memset(large, 'x', sizeof(large) - 1); large[sizeof(large) - 1] = 0;
    GuardBegin(GuardMethod, 1, large, large);
    assert(!GuardReject(GuardMethodEncoding, 0, 0, large, large));
    assert(ESMBackboardGuardDiagnostic.className[63] == 0);
    assert(ESMBackboardGuardDiagnostic.name[191] == 0);
    assert(ESMBackboardGuardDiagnostic.actualType[191] == 0);
    assert(ESMBackboardGuardDiagnostic.expectedType[191] == 0);
}
static int64_t resultReason;
static void SimulateProcess(id controller, SEL, uint64_t timestamp, bool) {
    ProcessingInfo info{}; info.timestamp = timestamp; info.reason = 4; info.needsHitTest = true;
    BridgeReasonIfEligible(controller, &info, reasonReturnAddress);
    resultReason = info.reason;
    calls.push_back("final-input");
    if (info.reason == 1) Exit(controller, nullptr, nil, @"main", true, timestamp, nil);
}
struct ImageFixture { mach_header_64 header; const char *name; intptr_t slide; };
static std::vector<ImageFixture> imageFixtures;
static const mach_header *FixtureHeader(uint32_t i) {
    return reinterpret_cast<const mach_header *>(&imageFixtures.at(i).header);
}
static const char *FixtureName(uint32_t i) { return imageFixtures.at(i).name; }
static intptr_t FixtureSlide(uint32_t i) { return imageFixtures.at(i).slide; }
static void TestImageSelection() {
    mach_header_64 executable{}; executable.magic = MH_MAGIC_64; executable.filetype = MH_EXECUTE;
    mach_header_64 injected = executable; injected.filetype = MH_DYLIB;
    imageFixtures = {{injected, "/preboot/basebin/systemhook.dylib", 0x9000},
                     {injected, nullptr, 0x8000},
                     {executable, "/usr/libexec/backboardd", 0x7000}};
    NativeImage result{};
    auto find = [&] { return FindBackboardImage((uint32_t)imageFixtures.size(),
                           FixtureHeader, FixtureName, FixtureSlide, &result); };
    assert(find());
    assert(result.header == FixtureHeader(2) && result.slide == 0x7000);
    // Resolve reordered tables without retaining the previous index or slide.
    std::swap(imageFixtures[0], imageFixtures[2]);
    assert(find());
    assert(result.header == FixtureHeader(0) && result.slide == 0x7000);
    imageFixtures.push_back(imageFixtures[0]);
    assert(!find()); AssertRejection(GuardImage, 0, GuardImageAmbiguous);
    imageFixtures.pop_back();
    imageFixtures[0].header.filetype = MH_DYLIB;
    assert(!find()); AssertRejection(GuardImage, 0, GuardImageFileType);
    imageFixtures[0].name = "/usr/libexec/backboardd.backup";
    assert(!find()); AssertRejection(GuardImage, 0, GuardImageNotFound);
    imageFixtures.clear();
    assert(!find()); AssertRejection(GuardImage, 0, GuardImageNotFound);
}
int main() { @autoreleasepool {
    const GuardDiagnostic zero{};
    assert(!memcmp(&ESMBackboardGuardDiagnostic, &zero, sizeof(zero)));
    assert(!ESMInstallBackboardRouting()); // host executable must be refused without mutation
    AssertRejection(GuardImage, 0, GuardImageNotFound);
    assert(!originalExit && !originalProcess && !originalDetermine && !clearSender);
    TestGuardDiagnostic();
    TestImageSelection();
    TestRebasedLayout();
    BindFixtureIvars();
    for (bool pin : {false, true}) for (bool exitPin : {false, true}) {
        TestController *c = Fixture(pin); calls.clear();
        Exit(c, nullptr, nil, nil, exitPin, 100, nil);
        const bool allowed = !pin || exitPin;
        assert(Route(c)->_withinContext == !allowed);
        assert((Route(c)->_destination->_senderInfo != nil) == !allowed);
        assert(c->_globalContextsPinnedByMouse.count == (pin && !allowed ? 1 : 0));
        const std::vector<std::string> expected = allowed ? (pin ?
          std::vector<std::string>{"orientation","exit","append","clear","unpin"} :
          std::vector<std::string>{"orientation","exit","append","clear"}) : std::vector<std::string>{};
        assert(calls == expected);
    }
    for (int mode = 0; mode < 4; ++mode) {
        TestController *c = Fixture(true, mode != 0, mode != 1); calls.clear();
        Exit(c, nullptr, mode == 2 ? @"main" : nil, mode == 3 ? @"external" : nil, true, 100, nil);
        assert(calls.empty() && c->_globalContextsPinnedByMouse.count == 1);
    }
    TestController *main = Fixture(true); Route(main)->_destination->_displayUUID = @""; calls.clear();
    Exit(main, nullptr, @"<main>", nil, true, 100, nil); assert(!Route(main)->_withinContext);
    TestController *c = Fixture(true); c->_eventAccumulator->reason = 1; calls.clear();
    originalProcess = SimulateProcess; Process(c, nullptr, 100, false);
    assert(resultReason == 1 && !activeProcess && c->_globalContextsPinnedByMouse.count == 0);
    assert((calls == std::vector<std::string>{"reason","final-input","orientation","exit","append","clear","unpin"}));
    for (int64_t reason : {0,1,2,3}) {
        c = Fixture(true); c->_eventAccumulator->reason = reason;
        Process(c, nullptr, 100, false); assert(resultReason == (reason ? reason : 4));
    }
    for (int64_t fallback : {4,5}) {
        TestController *zero = Fixture(true); zero->_eventAccumulator->reason = 0;
        ProcessingInfo fallbackInfo{}; fallbackInfo.timestamp = 100; fallbackInfo.reason = fallback;
        ProcessScope fallbackScope{zero,100,false,nullptr}; activeProcess = &fallbackScope;
        BridgeReasonIfEligible(zero,&fallbackInfo,reasonReturnAddress);
        assert(fallbackInfo.reason == fallback && !fallbackInfo.needsHitTest);
        activeProcess = nullptr;
    }
    ProcessingInfo info{}; info.timestamp = 100; info.reason = 5;
    c = Fixture(true); c->_eventAccumulator->reason = 1;
    BridgeReasonIfEligible(c, &info, reasonReturnAddress); assert(info.reason == 5);
    ProcessScope scope{c,100,false,nullptr}; activeProcess = &scope;
    BridgeReasonIfEligible(c, &info, reasonReturnAddress + 4); assert(info.reason == 5 && !scope.bridged);
    info.timestamp = 99; BridgeReasonIfEligible(c,&info,reasonReturnAddress); assert(info.reason == 5);
    info.timestamp = 100; BridgeReasonIfEligible(Fixture(true),&info,reasonReturnAddress); assert(info.reason == 5);
    BridgeReasonIfEligible(c,&info,reasonReturnAddress); assert(info.reason == 1 && info.needsHitTest);
    info.reason = 5; BridgeReasonIfEligible(c,&info,reasonReturnAddress); assert(info.reason == 5);
    activeProcess = nullptr;
    static int nestedDepth;
    originalProcess = [](id receiver,SEL command,uint64_t time,bool disabled) {
        ProcessScope *outer = activeProcess;
        assert(outer && outer->controller == receiver);
        if (!nestedDepth++) {
            Process(receiver,command,time,disabled);
            assert(activeProcess == outer);
        }
        --nestedDepth;
    };
    Process(c,nullptr,100,false); assert(!activeProcess && !nestedDepth);
    originalProcess = [](id,SEL,uint64_t,bool) { @throw [NSException exceptionWithName:@"test" reason:nil userInfo:nil]; };
    @try { Process(c,nullptr,100,false); assert(false); } @catch (NSException *) {}
    assert(!activeProcess);
    puts("backboard host behavior: PASS (production guard diagnostics, conditions, filters, ordering, reason scope, exception cleanup)");
} }
