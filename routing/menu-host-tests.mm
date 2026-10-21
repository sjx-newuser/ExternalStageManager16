#define ESM_HOST_TEST 1
#import "SceneMenuRouting.mm"
#include <cstdio>
#include <cstdlib>

static void Check(bool condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); abort(); }
}
@implementation UIGestureRecognizer
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super init])) { _target = target; _action = action; }
    return self;
}
- (void)requireGestureRecognizerToFail:(UIGestureRecognizer *)other { _requiredFailure = other; }
@end
@implementation UITapGestureRecognizer
@end
@implementation UIPanGestureRecognizer
@end
@implementation UITouch
@end
@interface SBFailingSystemGestureRecognizer : UIGestureRecognizer
@end
@implementation SBFailingSystemGestureRecognizer
@end

@interface FakeGM : NSObject
@property(nonatomic, strong) NSMutableDictionary *recognizers;
@property(nonatomic, strong) NSObject *windowForSystemGestures;
@property(nonatomic) NSUInteger adds, removes;
- (void)addGestureRecognizer:(id)recognizer withType:(NSUInteger)type;
- (void)removeGestureRecognizer:(id)recognizer;
@end
@implementation FakeGM
- (instancetype)init {
    if ((self = [super init])) { _recognizers = [NSMutableDictionary new]; _windowForSystemGestures = [NSObject new]; }
    return self;
}
- (void)addGestureRecognizer:(id)recognizer withType:(NSUInteger)type {
    Check(recognizer != nil, "register has recognizer");
    Check(_recognizers[@(type)] == nil, "no duplicate gesture type");
    _recognizers[@(type)] = recognizer; _adds++;
}
- (void)removeGestureRecognizer:(id)recognizer {
    NSArray *keys = [_recognizers allKeysForObject:recognizer];
    Check(keys.count == 1, "remove gesture belongs to this GM exactly once");
    [_recognizers removeObjectForKey:keys.firstObject]; _removes++;
}
@end
@interface FakeContext : NSObject
@property(nonatomic, strong) FakeGM *systemGestureManager;
@end
@implementation FakeContext
@end
@interface FakeSceneDelegate : NSObject
@property(nonatomic, strong) FakeContext *context;
- (FakeContext *)_sbWindowSceneContext;
@end
@implementation FakeSceneDelegate
- (FakeContext *)_sbWindowSceneContext { return _context; }
@end
@interface FakeScene : NSObject
@property(nonatomic, strong) FakeSceneDelegate *sceneDelegate;
- (FakeSceneDelegate *)_abstractWindowSceneDelegate;
@end
@implementation FakeScene
- (FakeSceneDelegate *)_abstractWindowSceneDelegate { return _sceneDelegate; }
@end
@interface FakeHandle : NSObject
@property(nonatomic, strong) FakeScene *scene;
- (FakeScene *)_windowScene;
@end
@implementation FakeHandle
- (FakeScene *)_windowScene { return _scene; }
@end
static NSUInteger touches, unhides, pans, globalRegisters, globalUnregisters, originalDisconnects;
static bool touchResult;
@interface FakeTopAffordance : NSObject
@property(nonatomic, strong) FakeHandle *sceneHandle;
- (BOOL)transientUIHandledTouch:(id)touch withSystemGestureRecognizer:(id)recognizer;
- (void)transientUI:(id)manager wasIndirectPannedToDismissFromGestureRecognizer:(id)recognizer;
@end
@implementation FakeTopAffordance
- (BOOL)transientUIHandledTouch:(__unused id)touch withSystemGestureRecognizer:(__unused id)recognizer { touches++; return touchResult; }
- (void)transientUI:(__unused id)manager wasIndirectPannedToDismissFromGestureRecognizer:(__unused id)recognizer { pans++; }
@end
@interface FakePresence : NSObject
@property(nonatomic, weak) FakeTopAffordance *delegate;
@property(nonatomic) BOOL unregisterWhenDeallocated;
- (void)transientUI:(id)manager wasTappedToUnhideFromGestureRecognizer:(id)recognizer;
@end
@implementation FakePresence
- (void)transientUI:(__unused id)manager wasTappedToUnhideFromGestureRecognizer:(__unused id)recognizer { unhides++; }
- (void)dealloc {
    // Models real presence dealloc after TopAffordance's weak delegate dies.
    if (_unregisterWhenDeallocated) UnregisterUnhide(nil, nullptr, self);
}
@end
static FakeGM *hostMainGM;
static id hostLegacy;
static ESMSceneTransientManager *hostNativeBackend;
static id hostOldWindow;
static NSUInteger legacyGetterCalls;
@interface SBSystemGestureManager : NSObject
+ (id)mainDisplayManager;
@end
@implementation SBSystemGestureManager
+ (id)mainDisplayManager { return hostMainGM; }
@end
@interface HostApplication : NSObject
- (id)systemTransientUIInteractionManager;
@end
@implementation HostApplication
- (id)systemTransientUIInteractionManager { legacyGetterCalls++; return hostLegacy; }
@end
@interface UIApplication : NSObject
+ (id)sharedApplication;
@end
@implementation UIApplication
+ (id)sharedApplication { static HostApplication *app = [HostApplication new]; return app; }
@end
static ESMParticipantKind NativeKind(SEL command, bool unregister) {
    for (NSUInteger i = 0; i < 3; ++i) if (command == ParticipantSelector(static_cast<ESMParticipantKind>(i), unregister)) return static_cast<ESMParticipantKind>(i);
    Check(false, "native selector carries registration group"); return ESMDismiss;
}
static void NativeRegister(id self, SEL command, __unsafe_unretained id participant) {
    globalRegisters++;
    if (self && self == hostLegacy) [hostNativeBackend addParticipant:participant kind:NativeKind(command, false)];
}
static void NativeUnregister(id self, SEL command, __unsafe_unretained id participant) {
    globalUnregisters++;
    if (self && self == hostLegacy) [hostNativeBackend removeParticipant:participant kind:NativeKind(command, true)];
}
static id NativeView(__unused id self, __unused SEL command, __unused id recognizer) { return hostOldWindow; }
static void NativeSetGM(id self, __unused SEL command, id gm) { [(FakeContext *)self setSystemGestureManager:gm]; }
static void NativeDestructor(__unused __unsafe_unretained id self, __unused SEL command) {}
static void NativeDisconnect(__unused id self, __unused SEL command, __unused id scene) { originalDisconnects++; }
static FakeScene *Scene(FakeContext *context) {
    FakeScene *scene = [FakeScene new]; scene.sceneDelegate = [FakeSceneDelegate new]; scene.sceneDelegate.context = context; return scene;
}
static FakeTopAffordance *Top(FakeScene *scene) {
    FakeTopAffordance *top = [FakeTopAffordance new]; top.sceneHandle = [FakeHandle new]; top.sceneHandle.scene = scene; return top;
}
static ESMSceneTransientManager *Manager(FakeContext *context) { return objc_getAssociatedObject(context, &managerKey); }
static void Setup() {
    topAffordanceClass = [FakeTopAffordance class]; presenceClass = [FakePresence class];
    for (NSUInteger i = 0; i < 3; ++i) { originalRegister[i] = NativeRegister; originalUnregister[i] = NativeUnregister; }
    originalView = NativeView;
    originalSetGM = NativeSetGM; originalContextDestructor = NativeDestructor; originalDisconnect = NativeDisconnect;
}
static void TestManager() {
    FakeGM *gm = [FakeGM new]; ESMSceneTransientManager *manager = [[ESMSceneTransientManager alloc] initWithSystemGestureManager:gm];
    FakeTopAffordance *a = Top(nil), *b = Top(nil);
    [manager addParticipant:a kind:ESMDismiss]; [manager addParticipant:b kind:ESMDismiss]; [manager addParticipant:a kind:ESMDismiss];
    Check(gm.adds == 1, "tap participants share one recognizer");
    UIGestureRecognizer *tap = gm.recognizers[@30];
    Check([tap.allowedTouchTypes isEqual:@[@0, @2]], "dismiss allowed touch types");
    Check([manager window] == gm.windowForSystemGestures, "window follows owning GM");
    NSObject *nextWindow = [NSObject new]; gm.windowForSystemGestures = nextWindow;
    Check([manager viewForSystemGestureRecognizer:tap] == nextWindow, "gesture window lookup is dynamic");
    touches = 0; touchResult = true;
    Check([manager gestureRecognizer:tap shouldReceiveTouch:nil] && touches == 2, "all dismiss callbacks run even after handled");
    touchResult = false; Check(![manager gestureRecognizer:tap shouldReceiveTouch:nil], "all-false callback result");
    Check(![manager gestureRecognizer:[UIGestureRecognizer new] shouldReceiveTouch:nil], "unknown recognizer ignored");
    FakePresence *presence = [FakePresence new];
    [manager addParticipant:presence kind:ESMUnhide];
    UITapGestureRecognizer *single = gm.recognizers[@32], *twice = gm.recognizers[@33];
    Check([single.allowedTouchTypes isEqual:@[@0]] && [twice.allowedTouchTypes isEqual:@[@0]], "unhide direct touch types");
    Check(single.requiredFailure == twice && twice.numberOfTapsRequired == 2 && !twice.action, "single waits for actionless double tap");
    Check(!single.cancelsTouchesInView && !single.delaysTouchesBegan && !single.delaysTouchesEnded, "unhide delivery flags");
    Check([manager gestureRecognizer:single shouldReceiveTouch:nil] && [manager gestureRecognizer:twice shouldReceiveTouch:nil], "both unhide recognizers accept touch");
    unhides = 0; [manager _screenWasTappedToUnhide:twice]; Check(unhides == 0, "double tap does not notify");
    [manager _screenWasTappedToUnhide:single]; Check(unhides == 1, "single tap notifies");
    [manager addParticipant:a kind:ESMPan]; UIPanGestureRecognizer *pan = gm.recognizers[@31];
    Check(pan.allowedTouchTypes.count == 0 && pan.allowedScrollTypesMask == 3, "indirect pan is scroll only");
    pans = 0; pan.state = UIGestureRecognizerStateChanged; [manager _screenWasIndirectPannedToDismiss:pan]; Check(pans == 0, "pan changed ignored");
    pan.state = UIGestureRecognizerStateBegan; [manager _screenWasIndirectPannedToDismiss:pan]; Check(pans == 1, "pan began notifies");
    Check([manager gestureRecognizer:tap shouldRecognizeSimultaneouslyWithGestureRecognizer:pan], "simultaneous recognition");
    [manager removeParticipant:a kind:ESMDismiss]; Check(gm.recognizers[@30] != nil, "tap retained for remaining participant");
    [manager removeParticipant:b kind:ESMDismiss]; Check(gm.recognizers[@30] == nil, "last tap unregister detaches");
    [manager invalidate]; [manager invalidate]; Check(gm.recognizers.count == 0 && gm.adds == gm.removes, "invalidate removes exactly four recognizer kinds");
    [manager addParticipant:a kind:ESMDismiss]; Check(gm.recognizers.count == 0, "invalidated manager rejects registration");
}
static void TestRoutingAndReplacement() {
    FakeGM *aGM = [FakeGM new], *bGM = [FakeGM new]; FakeContext *a = [FakeContext new], *b = [FakeContext new];
    FakeScene *aScene = Scene(a), *bScene = Scene(b);
    SetSystemGestureManager(a, nullptr, aGM); SetSystemGestureManager(b, nullptr, bGM);
    FakeTopAffordance *top = Top(aScene); FakePresence *presence = [FakePresence new]; presence.delegate = top;
    RegisterTap(nil, nullptr, top); RegisterPan(nil, nullptr, top); RegisterUnhide(nil, nullptr, presence);
    Check(aGM.recognizers.count == 4 && bGM.recognizers.count == 0, "scene-local registration");
    ESMSceneTransientManager *same = Manager(a); SetSystemGestureManager(a, nullptr, aGM);
    Check(Manager(a) == same && aGM.adds == 4 && aGM.removes == 0, "same-GM setter preserves participant manager");
    FakeGM *replacement = [FakeGM new]; SetSystemGestureManager(a, nullptr, replacement);
    Check(aGM.recognizers.count == 0 && aGM.adds == aGM.removes && replacement.recognizers.count == 4, "new GM rebinds all live participants");
    top.sceneHandle.scene = bScene;
    RegisterTap(nil, nullptr, top); RegisterPan(nil, nullptr, top); RegisterUnhide(nil, nullptr, presence);
    Check(replacement.recognizers.count == 0 && bGM.recognizers.count == 4, "re-register after migration detaches old scene");
    // Make current scene differ again: unregister must use recorded manager.
    top.sceneHandle.scene = aScene; presence.delegate = nil;
    NSUInteger beforeNilDelegate = globalRegisters;
    RegisterUnhide(nil, nullptr, presence);
    Check(globalRegisters == beforeNilDelegate, "managed presence without delegate cannot fall back to global");
    UnregisterTap(nil, nullptr, top); UnregisterPan(nil, nullptr, top); UnregisterUnhide(nil, nullptr, presence);
    Check(bGM.recognizers.count == 0 && bGM.adds == bGM.removes, "unregister uses recorded manager even with dead delegate");
    NSObject *other = [NSObject new]; NSUInteger reg = globalRegisters, unreg = globalUnregisters;
    RegisterTap(nil, nullptr, other); UnregisterTap(nil, nullptr, other);
    RegisterUnhide(nil, nullptr, other); UnregisterUnhide(nil, nullptr, other);
    RegisterPan(nil, nullptr, other); UnregisterPan(nil, nullptr, other);
    Check(globalRegisters == reg + 3 && globalUnregisters == unreg + 3, "other consumers preserve native calls");
    RegisterTap(nil, nullptr, top); CloseContext(a); UnregisterTap(nil, nullptr, top);
    Check(globalUnregisters == unreg + 3, "dead manager binding never unregisters global");
    RegisterTap(nil, nullptr, top); Check(replacement.recognizers.count == 0, "closed scene rejects late register");
    SceneDidDisconnect(bScene.sceneDelegate, nullptr, bScene); Check(originalDisconnects == 1, "disconnect preserves native callback");
    ContextDestructor(a, nullptr); ContextDestructor(b, nullptr);
}
static void TestWeakDeallocAndLazyOwner() {
    FakeGM *gm = [FakeGM new]; FakeContext *context = [FakeContext new]; context.systemGestureManager = gm;
    FakeScene *scene = Scene(context); FakeTopAffordance *top = Top(scene);
    __weak FakePresence *weakPresence;
    @autoreleasepool {
        FakePresence *presence = [FakePresence new]; presence.delegate = top; presence.unregisterWhenDeallocated = YES; weakPresence = presence;
        RegisterUnhide(nil, nullptr, presence); Check(Manager(context) && gm.recognizers.count == 2, "preexisting context lazily creates owner");
        presence.delegate = nil; presence = nil;
    }
    Check(!weakPresence && gm.recognizers.count == 0 && gm.adds == gm.removes, "presence dealloc unregisters with weak delegate gone");
    // A weak participant can disappear before explicit cleanup checks the count.
    ESMSceneTransientManager *manager = Manager(context);
    @autoreleasepool { FakeTopAffordance *temporary = Top(scene); [manager addParticipant:temporary kind:ESMDismiss]; }
    Check([manager participantSnapshotForKind:ESMDismiss].count == 0, "manager does not retain participant");
    [manager removeParticipant:nil kind:ESMDismiss]; Check(gm.recognizers.count == 0, "weak disappearance still detaches empty group");
    RegisterTap(nil, nullptr, top); SetSystemGestureManager(context, nullptr, nil);
    Check(gm.recognizers.count == 0 && !Manager(context), "nil GM invalidates before native release");
    NSUInteger before = globalUnregisters; UnregisterTap(nil, nullptr, top); Check(globalUnregisters == before, "nil GM preserves managed marker");
    RegisterTap(nil, nullptr, top); Check(!Manager(context), "nil GM cannot create owner");
    __weak FakeGM *weakGM;
    ESMSceneTransientManager *weakOwner;
    @autoreleasepool { FakeGM *temporary = [FakeGM new]; weakGM = temporary; weakOwner = [[ESMSceneTransientManager alloc] initWithSystemGestureManager:temporary]; }
    Check(!weakGM && ![weakOwner systemGestureManager], "manager does not retain GM");
    [weakOwner invalidate];
}
static void TestSharedMainSlots() {
    hostMainGM = [FakeGM new]; hostLegacy = [NSObject new]; hostOldWindow = [NSObject new];
    hostNativeBackend = [[ESMSceneTransientManager alloc] initWithSystemGestureManager:hostMainGM];
    FakeContext *context = [FakeContext new]; FakeScene *scene = Scene(context);
    NSObject *ordinary = [NSObject new];
    // Ordinary native consumers own all four slots before target registration.
    RegisterTap(hostLegacy, ParticipantSelector(ESMDismiss, false), ordinary);
    RegisterPan(hostLegacy, ParticipantSelector(ESMPan, false), ordinary);
    RegisterUnhide(hostLegacy, ParticipantSelector(ESMUnhide, false), ordinary);
    Check(hostMainGM.recognizers.count == 4 && hostMainGM.adds == 4, "native consumers already occupy main-display type slots");
    NSUInteger getterCalls = legacyGetterCalls;
    SetSystemGestureManager(context, nullptr, hostMainGM);
    Check(legacyGetterCalls == getterCalls, "main context setup does not eagerly create legacy gesture window");
    FakeTopAffordance *top = Top(scene); FakePresence *presence = [FakePresence new]; presence.delegate = top;
    RegisterTap(hostLegacy, ParticipantSelector(ESMDismiss, false), top);
    RegisterPan(hostLegacy, ParticipantSelector(ESMPan, false), top);
    RegisterUnhide(hostLegacy, ParticipantSelector(ESMUnhide, false), presence);
    Check(hostMainGM.recognizers.count == 4 && hostMainGM.adds == 4 && legacyGetterCalls == getterCalls + 1, "main target lazily shares native slots without duplicate registration");
    NSObject *newWindow = [NSObject new]; hostMainGM.windowForSystemGestures = newWindow;
    Check(LegacyView(hostLegacy, nullptr, nil) == newWindow, "known native singleton follows current main GM window");
    Check(LegacyView([NSObject new], nullptr, nil) == hostOldWindow, "other native managers preserve old view getter");
    ContextDestructor(context, nullptr);
    Check(hostMainGM.recognizers.count == 4 && hostMainGM.removes == 0, "context cleanup retains recognizers owned by ordinary native consumers");
    Check([hostNativeBackend participantSnapshotForKind:ESMDismiss].count == 1 &&
          [hostNativeBackend participantSnapshotForKind:ESMUnhide].count == 1 &&
          [hostNativeBackend participantSnapshotForKind:ESMPan].count == 1, "context cleanup removes only its own tracked participants");
    UnregisterTap(hostLegacy, ParticipantSelector(ESMDismiss, true), ordinary);
    UnregisterPan(hostLegacy, ParticipantSelector(ESMPan, true), ordinary);
    UnregisterUnhide(hostLegacy, ParticipantSelector(ESMUnhide, true), ordinary);
    Check(hostMainGM.recognizers.count == 0 && hostMainGM.adds == hostMainGM.removes, "native consumers retain final removal ownership");
    hostNativeBackend = nil; hostLegacy = nil; hostMainGM = nil; hostOldWindow = nil;
}
int main() {
    @autoreleasepool {
        Setup(); TestManager(); TestRoutingAndReplacement(); TestWeakDeallocAndLazyOwner(); TestSharedMainSlots();
        Check(!ESMInstallSceneMenuRouting(), "host build cannot install device hooks");
        printf("PASS: actual SceneMenuRouting manager, callbacks, routing, replacement, dealloc and weak lifecycle\n");
    }
    return 0;
}
