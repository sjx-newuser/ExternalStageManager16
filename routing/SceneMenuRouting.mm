// 20C65 transient-menu behavior, adapted to the 20B82 scene/context lifecycle.
#import <Foundation/Foundation.h>
#ifdef ESM_HOST_TEST
#import "tests/FakeUIKit.h"
#else
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#include <sys/sysctl.h>
#endif
#import <objc/message.h>
#import <objc/runtime.h>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

namespace {
enum ESMParticipantKind : NSUInteger { ESMDismiss = 0, ESMUnhide = 1, ESMPan = 2 };
using ParticipantFn = void (*)(id, SEL, __unsafe_unretained id);
static ParticipantFn originalRegister[3], originalUnregister[3];
static __weak id knownLegacyManager;
static __weak id knownMainGM;
static SEL ParticipantSelector(ESMParticipantKind kind, bool unregister) {
    static const char *registerNames[] = {"registerParticipantForTapToDismiss:", "registerParticipantForTapToUnhide:", "registerParticipantForIndirectPanToDismiss:"};
    static const char *unregisterNames[] = {"unregisterParticipantForTapToDismiss:", "unregisterParticipantForTapToUnhide:", "unregisterParticipantForIndirectPanToDismiss:"};
    return sel_registerName(unregister ? unregisterNames[kind] : registerNames[kind]);
}
static id Object(id object, const char *name) {
    return ((id (*)(id, SEL))objc_msgSend)(object, sel_registerName(name));
}
static void Notify(id participant, const char *selector, id manager, id recognizer) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(participant, sel_registerName(selector), manager, recognizer);
}
static void Add(id gm, id recognizer, NSUInteger type) {
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(gm,
        sel_registerName("addGestureRecognizer:withType:"), recognizer, type);
}
static void Remove(id gm, id recognizer) {
    if (recognizer) ((void (*)(id, SEL, id))objc_msgSend)(gm,
        sel_registerName("removeGestureRecognizer:"), recognizer);
}
} // namespace

@interface ESMSceneTransientManager : NSObject <UIGestureRecognizerDelegate> {
    __weak id _systemGestureManager, _legacyMainManager;
    BOOL _usesLegacyMainManager;
    NSHashTable *_tapParticipants, *_unhideParticipants, *_panParticipants;
    UIGestureRecognizer *_tapToDismissGestureRecognizer;
    UITapGestureRecognizer *_tapToUnhideGestureRecognizer, *_doubleTapToUnhideGestureRecognizer;
    UIPanGestureRecognizer *_indirectPanToDismissGestureRecognizer;
    BOOL _invalidated;
}
- (instancetype)initWithSystemGestureManager:(id)manager;
- (void)useLegacyMainManager:(id)manager;
- (id)systemGestureManager;
- (id)window;
- (id)viewForSystemGestureRecognizer:(id)recognizer;
- (void)addParticipant:(__unsafe_unretained id)participant kind:(ESMParticipantKind)kind;
- (void)removeParticipant:(__unsafe_unretained id)participant kind:(ESMParticipantKind)kind;
- (void)invalidate;
- (NSArray *)participantSnapshotForKind:(ESMParticipantKind)kind;
@end

@implementation ESMSceneTransientManager
- (instancetype)initWithSystemGestureManager:(id)manager {
    if ((self = [super init])) {
        _systemGestureManager = manager;
        _tapParticipants = [NSHashTable weakObjectsHashTable];
        _unhideParticipants = [NSHashTable weakObjectsHashTable];
        _panParticipants = [NSHashTable weakObjectsHashTable];
    }
    return self;
}
- (void)useLegacyMainManager:(id)manager {
    _usesLegacyMainManager = YES;
    _legacyMainManager = manager;
}
- (id)systemGestureManager { return _systemGestureManager; }
- (id)window { return Object(_systemGestureManager, "windowForSystemGestures"); }
- (id)viewForSystemGestureRecognizer:(__unused id)recognizer { return [self window]; }
- (NSHashTable *)participantsForKind:(ESMParticipantKind)kind {
    switch (kind) {
        case ESMDismiss: return _tapParticipants;
        case ESMUnhide: return _unhideParticipants;
        case ESMPan: return _panParticipants;
    }
    return nil;
}
- (NSArray *)participantSnapshotForKind:(ESMParticipantKind)kind {
    return [[self participantsForKind:kind] allObjects];
}
- (void)configureUnhideRecognizer:(UITapGestureRecognizer *)recognizer name:(NSString *)name {
    recognizer.name = name;
    recognizer.cancelsTouchesInView = NO;
    recognizer.delaysTouchesBegan = NO;
    recognizer.delaysTouchesEnded = NO;
    recognizer.allowedTouchTypes = @[@0];
    recognizer.delegate = self;
}
- (void)addParticipant:(__unsafe_unretained id)participant kind:(ESMParticipantKind)kind {
    // All call sites are synchronous main-thread SpringBoard callbacks.
    if (_invalidated || !participant) return;
    id gm = _systemGestureManager;
    if (!gm) return;
    NSHashTable *participants = [self participantsForKind:kind];
    if (![participants containsObject:participant]) [participants addObject:participant];
    if (![participants count]) return;
    if (_usesLegacyMainManager) {
        id legacy = _legacyMainManager;
        if (!legacy) {
            // Registration's native caller already requested this getter. Do
            // not create the legacy gesture window during context setup.
            legacy = Object(Object(NSClassFromString(@"UIApplication"), "sharedApplication"),
                            "systemTransientUIInteractionManager");
            _legacyMainManager = legacy;
            knownLegacyManager = legacy;
        }
        if (legacy) originalRegister[kind](legacy, ParticipantSelector(kind, false), participant);
        return;
    }
    switch (kind) {
        case ESMDismiss:
            if (!_tapToDismissGestureRecognizer) {
                _tapToDismissGestureRecognizer = [[NSClassFromString(@"SBFailingSystemGestureRecognizer") alloc] init];
                _tapToDismissGestureRecognizer.name = @"transientUI.dismiss.tap";
                _tapToDismissGestureRecognizer.allowedTouchTypes = @[@0, @2];
                _tapToDismissGestureRecognizer.delegate = self;
                Add(gm, _tapToDismissGestureRecognizer, 30);
            }
            break;
        case ESMUnhide:
            if (!_tapToUnhideGestureRecognizer) {
                _tapToUnhideGestureRecognizer = [[UITapGestureRecognizer alloc]
                    initWithTarget:self action:@selector(_screenWasTappedToUnhide:)];
                [self configureUnhideRecognizer:_tapToUnhideGestureRecognizer name:@"transientUI.unhide.tap"];
                Add(gm, _tapToUnhideGestureRecognizer, 32);
            }
            if (!_doubleTapToUnhideGestureRecognizer) {
                // Native double tap has no action; it gates the single tap.
                _doubleTapToUnhideGestureRecognizer = [[UITapGestureRecognizer alloc] init];
                [self configureUnhideRecognizer:_doubleTapToUnhideGestureRecognizer name:@"transientUI.unhide.doubleTap"];
                _doubleTapToUnhideGestureRecognizer.numberOfTapsRequired = 2;
                [_tapToUnhideGestureRecognizer requireGestureRecognizerToFail:_doubleTapToUnhideGestureRecognizer];
                Add(gm, _doubleTapToUnhideGestureRecognizer, 33);
            }
            break;
        case ESMPan:
            if (!_indirectPanToDismissGestureRecognizer) {
                _indirectPanToDismissGestureRecognizer = [[UIPanGestureRecognizer alloc]
                    initWithTarget:self action:@selector(_screenWasIndirectPannedToDismiss:)];
                _indirectPanToDismissGestureRecognizer.name = @"transientUI.dismiss.indirectPan";
                _indirectPanToDismissGestureRecognizer.delegate = self;
                // Both native cache slots resolve to __NSArray0, not a guessed touch enum.
                _indirectPanToDismissGestureRecognizer.allowedTouchTypes = @[];
                _indirectPanToDismissGestureRecognizer.allowedScrollTypesMask = 3;
                Add(gm, _indirectPanToDismissGestureRecognizer, 31);
            }
            break;
    }
}
- (void)removeParticipant:(__unsafe_unretained id)participant kind:(ESMParticipantKind)kind {
    NSHashTable *participants = [self participantsForKind:kind];
    if (_usesLegacyMainManager && participant) {
        id legacy = _legacyMainManager;
        if (legacy) originalUnregister[kind](legacy, ParticipantSelector(kind, true), participant);
    }
    // Weak tables may already have removed a participant entering dealloc.
    // Always inspect the count, even when containsObject: is false.
    if (participant && [participants containsObject:participant]) [participants removeObject:participant];
    // NSHashTable count can include zeroed weak buckets during dealloc.
    // allObjects observes live entries without retaining the deallocating object.
    if (_usesLegacyMainManager || [[participants allObjects] count]) return;
    id gm = _systemGestureManager;
    switch (kind) {
        case ESMDismiss:
            Remove(gm, _tapToDismissGestureRecognizer);
            _tapToDismissGestureRecognizer.delegate = nil;
            _tapToDismissGestureRecognizer = nil;
            break;
        case ESMUnhide:
            Remove(gm, _tapToUnhideGestureRecognizer);
            Remove(gm, _doubleTapToUnhideGestureRecognizer);
            _tapToUnhideGestureRecognizer.delegate = nil;
            _doubleTapToUnhideGestureRecognizer.delegate = nil;
            _tapToUnhideGestureRecognizer = nil;
            _doubleTapToUnhideGestureRecognizer = nil;
            break;
        case ESMPan:
            Remove(gm, _indirectPanToDismissGestureRecognizer);
            _indirectPanToDismissGestureRecognizer.delegate = nil;
            _indirectPanToDismissGestureRecognizer = nil;
            break;
    }
}
- (void)invalidate {
    if (_invalidated) return;
    _invalidated = YES;
    if (_usesLegacyMainManager) {
        id legacy = _legacyMainManager;
        if (legacy) for (NSUInteger i = 0; i < 3; ++i) {
            const auto kind = static_cast<ESMParticipantKind>(i);
            for (id participant in [self participantSnapshotForKind:kind])
                originalUnregister[i](legacy, ParticipantSelector(kind, true), participant);
        }
    }
    [_tapParticipants removeAllObjects];
    [_unhideParticipants removeAllObjects];
    [_panParticipants removeAllObjects];
    [self removeParticipant:nil kind:ESMDismiss];
    [self removeParticipant:nil kind:ESMUnhide];
    [self removeParticipant:nil kind:ESMPan];
    _systemGestureManager = nil;
}
- (void)dealloc { [self invalidate]; }
- (void)_screenWasTappedToUnhide:(id)recognizer {
    if (_invalidated || recognizer != _tapToUnhideGestureRecognizer) return;
    for (id participant in [_unhideParticipants copy])
        Notify(participant, "transientUI:wasTappedToUnhideFromGestureRecognizer:", self, recognizer);
}
- (void)_screenWasIndirectPannedToDismiss:(UIPanGestureRecognizer *)recognizer {
    if (_invalidated || recognizer != _indirectPanToDismissGestureRecognizer ||
        recognizer.state != UIGestureRecognizerStateBegan) return;
    for (id participant in [_panParticipants copy])
        Notify(participant, "transientUI:wasIndirectPannedToDismissFromGestureRecognizer:", self, recognizer);
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if (_invalidated) return NO;
    if (recognizer == _tapToUnhideGestureRecognizer || recognizer == _doubleTapToUnhideGestureRecognizer) return YES;
    if (recognizer != _tapToDismissGestureRecognizer) return NO;
    BOOL handled = NO;
    for (id participant in [_tapParticipants copy]) {
        BOOL current = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(participant,
            sel_registerName("transientUIHandledTouch:withSystemGestureRecognizer:"), touch, recognizer);
        // Do not short-circuit: every native participant receives the touch.
        handled = current || handled;
    }
    return handled;
}
- (BOOL)gestureRecognizer:(__unused UIGestureRecognizer *)recognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(__unused UIGestureRecognizer *)other { return YES; }
@end

@interface ESMSceneParticipantBinding : NSObject {
@public
    __weak ESMSceneTransientManager *_tap, *_unhide, *_pan;
    unsigned _managed;
}
@end
@implementation ESMSceneParticipantBinding
@end

namespace {
static char managerKey, bindingKey, disconnectedKey;
static Class topAffordanceClass, presenceClass;
using SetterFn = void (*)(id, SEL, id);
using DestructorFn = void (*)(__unsafe_unretained id, SEL);
static SetterFn originalSetGM, originalDisconnect;
static DestructorFn originalContextDestructor;
using ViewFn = id (*)(id, SEL, id);
static ViewFn originalView;
static id LegacyView(id self, SEL command, id recognizer) {
    // The old native manager remains the single owner of main-display slots.
    // Match 16.2's dynamic window lookup only for this known singleton.
    if (self == knownLegacyManager) return Object(knownMainGM, "windowForSystemGestures");
    return originalView(self, command, recognizer);
}
static ESMSceneTransientManager *CreateManager(id gm) {
    ESMSceneTransientManager *manager = [[ESMSceneTransientManager alloc] initWithSystemGestureManager:gm];
    id mainGM = Object(NSClassFromString(@"SBSystemGestureManager"), "mainDisplayManager");
    if (gm && gm == mainGM) {
        knownMainGM = gm;
        // Select the backend now; resolve its native singleton only at actual
        // target registration, after the caller's original getter has run.
        [manager useLegacyMainManager:nil];
    }
    return manager;
}

static ESMSceneTransientManager *Bound(ESMSceneParticipantBinding *binding, ESMParticipantKind kind) {
    switch (kind) { case ESMDismiss: return binding->_tap; case ESMUnhide: return binding->_unhide; case ESMPan: return binding->_pan; }
    return nil;
}
static void Bind(ESMSceneParticipantBinding *binding, ESMParticipantKind kind, ESMSceneTransientManager *manager) {
    switch (kind) { case ESMDismiss: binding->_tap = manager; break; case ESMUnhide: binding->_unhide = manager; break; case ESMPan: binding->_pan = manager; break; }
}
static id ContextForScene(id scene) {
    id delegate = Object(scene, "_abstractWindowSceneDelegate");
    return Object(delegate, "_sbWindowSceneContext");
}
static id ParticipantScene(__unsafe_unretained id participant, ESMParticipantKind kind, bool *eligible) {
    id controller = nil;
    if (kind == ESMUnhide && [participant isKindOfClass:presenceClass]) controller = Object(participant, "delegate");
    else if (kind != ESMUnhide) controller = participant;
    *eligible = [controller isKindOfClass:topAffordanceClass];
    return *eligible ? Object(Object(controller, "sceneHandle"), "_windowScene") : nil;
}
static ESMSceneTransientManager *ManagerForContext(id context) {
    if (!context || [objc_getAssociatedObject(context, &disconnectedKey) boolValue]) return nil;
    ESMSceneTransientManager *manager = objc_getAssociatedObject(context, &managerKey);
    if (!manager) {
        // An already-connected scene can predate tweak injection. This uses the
        // same context-owned GM and constructor as the synchronous setter hook.
        id gm = Object(context, "systemGestureManager");
        if (gm) {
            manager = CreateManager(gm);
            objc_setAssociatedObject(context, &managerKey, manager, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    return manager;
}
static void Register(id self, SEL command, __unsafe_unretained id participant, ESMParticipantKind kind) {
    ESMSceneParticipantBinding *binding = objc_getAssociatedObject(participant, &bindingKey);
    bool eligible = false;
    id scene = ParticipantScene(participant, kind, &eligible);
    if (!eligible) {
        if (binding && (binding->_managed & (1u << kind))) {
            [Bound(binding, kind) removeParticipant:participant kind:kind];
            Bind(binding, kind, nil);
        } else originalRegister[kind](self, command, participant);
        return;
    }
    if (!binding) {
        binding = [ESMSceneParticipantBinding new];
        objc_setAssociatedObject(participant, &bindingKey, binding, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    id context = ContextForScene(scene);
    ESMSceneTransientManager *manager = ManagerForContext(context);
    ESMSceneTransientManager *old = Bound(binding, kind);
    if (old && old != manager) [old removeParticipant:participant kind:kind];
    // The marker survives manager destruction, so unregister never falls back
    // to global registration when weak manager has already become nil.
    binding->_managed |= 1u << kind;
    Bind(binding, kind, manager);
    [manager addParticipant:participant kind:kind];
}
static void Unregister(id self, SEL command, __unsafe_unretained id participant, ESMParticipantKind kind) {
    ESMSceneParticipantBinding *binding = objc_getAssociatedObject(participant, &bindingKey);
    if (binding && (binding->_managed & (1u << kind))) {
        [Bound(binding, kind) removeParticipant:participant kind:kind];
        Bind(binding, kind, nil);
        // Keep marker until the participant itself goes away.
        return;
    }
    originalUnregister[kind](self, command, participant);
}
#define ESM_PARTICIPANT_HOOKS(Name, Kind) \
static void Register##Name(id self, SEL command, __unsafe_unretained id participant) { Register(self, command, participant, Kind); } \
static void Unregister##Name(id self, SEL command, __unsafe_unretained id participant) { Unregister(self, command, participant, Kind); }
ESM_PARTICIPANT_HOOKS(Tap, ESMDismiss)
ESM_PARTICIPANT_HOOKS(Unhide, ESMUnhide)
ESM_PARTICIPANT_HOOKS(Pan, ESMPan)
#undef ESM_PARTICIPANT_HOOKS

static void SetSystemGestureManager(id self, SEL command, id gm) {
    ESMSceneTransientManager *old = objc_getAssociatedObject(self, &managerKey);
    id oldGM = Object(self, "systemGestureManager");
    const bool same = old && oldGM == gm && ![objc_getAssociatedObject(self, &disconnectedKey) boolValue];
    // Setter replacement is a normal live lifecycle event; snapshots keep
    // participants alive only during this synchronous transfer, never dealloc.
    NSArray *snapshots[3];
    if (!same && gm) for (NSUInteger i = 0; i < 3; ++i)
        snapshots[i] = [old participantSnapshotForKind:static_cast<ESMParticipantKind>(i)];
    if (!same) {
        // Context still owns oldGM while all recognizers are detached.
        [old invalidate];
        objc_setAssociatedObject(self, &managerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    originalSetGM(self, command, gm);
    if (!same) {
        objc_setAssociatedObject(self, &disconnectedKey, gm ? nil : @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (gm) objc_setAssociatedObject(self, &managerKey,
            CreateManager(gm), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (gm) for (NSUInteger i = 0; i < 3; ++i) {
            const auto kind = static_cast<ESMParticipantKind>(i);
            for (id participant in snapshots[i]) {
                bool eligible = false;
                id scene = ParticipantScene(participant, kind, &eligible);
                // A participant may have moved to another scene while old GM
                // teardown ran. Never transfer it into this context blindly.
                if (eligible && ContextForScene(scene) == self)
                    Register(nil, nullptr, participant, kind);
            }
        }
    }
}
static void CloseContext(__unsafe_unretained id context) {
    if (!context) return;
    objc_setAssociatedObject(context, &disconnectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ESMSceneTransientManager *manager = objc_getAssociatedObject(context, &managerKey);
    [manager invalidate];
    objc_setAssociatedObject(context, &managerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void ContextDestructor(__unsafe_unretained id self, SEL command) {
    CloseContext(self);
    originalContextDestructor(self, command);
}
static void SceneDidDisconnect(id self, SEL command, id scene) {
    // The native implementation invalidates GM later in this same invocation.
    CloseContext(Object(self, "_sbWindowSceneContext"));
    originalDisconnect(self, command, scene);
}
#ifndef ESM_HOST_TEST
struct Contract { const char *cls, *selector, *encoding; uintptr_t address; size_t size; const char *hash; };
static const Contract contracts[] = {
    {"SpringBoard", "systemTransientUIInteractionManager", "@16@0:8", 0x1c65134ecULL, 148, "04c56d2cd1f12965619cd3b2349d592e653fd9c52e9e0721c1e9258bed8cc7bc"},
    {"+SBSystemGestureManager", "mainDisplayManager", "@16@0:8", 0x1c648d06cULL, 12, "b6e8f4533652e989b9a1742a39e218fc8cecb3f1ae8579c74a23b422eaa1e233"},
    {"SBTransientUIInteractionManager", "viewForSystemGestureRecognizer:", "@24@0:8@16", 0x1c66bb144ULL, 8, "7e996318448459b7444116496c8a97c422d5a2b4d1d126e2f5456fa6250bfa4f"},
    {"SBTransientUIInteractionManager", "registerParticipantForTapToDismiss:", "v24@0:8@16", 0x1c66bb14cULL, 220, "e2ded4267f88fa1603b34c825254403ee76d66cccbdb9413ec1c2d5162931967"},
    {"SBTransientUIInteractionManager", "unregisterParticipantForTapToDismiss:", "v24@0:8@16", 0x1c66bb228ULL, 160, "9d5b9914859e85cd068ee2ca24331cf28541218b77f4d9ede4b171f270698ee7"},
    {"SBTransientUIInteractionManager", "registerParticipantForTapToUnhide:", "v24@0:8@16", 0x1c66bb2c8ULL, 440, "6170d2a354e191069124ee940fe61cb200d1b0237035682d450a3ee4dec95b7b"},
    {"SBTransientUIInteractionManager", "unregisterParticipantForTapToUnhide:", "v24@0:8@16", 0x1c66bb480ULL, 200, "e52991144d724035d5597d68de181368fd899eda8c0118f0eb26a5903e5011e4"},
    {"SBTransientUIInteractionManager", "registerParticipantForIndirectPanToDismiss:", "v24@0:8@16", 0x1c66bb548ULL, 248, "1dcd128ee644a8b79bbd2229181511618d7bc387e94698247288a07024c15d46"},
    {"SBTransientUIInteractionManager", "unregisterParticipantForIndirectPanToDismiss:", "v24@0:8@16", 0x1c66bb640ULL, 160, "df7bf5f7fbb5c2e78e7e3ad92fd6bad0d5755e8a20ab3a5f46125df8ab7363ad"},
    {"SBWindowSceneContext", ".cxx_destruct", "v16@0:8", 0x1c6b6f31cULL, 340, "1a413d54e9a8d9136176d19f7dc96166350116bd296b6892270ec261b3f791b3"},
    {"SBWindowSceneContext", "setSystemGestureManager:", "v24@0:8@16", 0x1c6b6f284ULL, 12, "596eafbebf481d0460e0955cd4a2ef948601b265004bec3d2a9eb1e78f9247c3"},
    {"SBWindowSceneContext", "systemGestureManager", "@16@0:8", 0x1c6b6f27cULL, 8, "ac1915dbf8ae56825a9e0c79c21190a655d4b32b9c10f299546aad7c9ecadc66"},
    {"SBExternalDisplayWindowSceneDelegate", "sceneDidDisconnect:", "v24@0:8@16", 0x1c662f888ULL, 568, "970bf18e3042d0686f9bb9dfdc50b662e147690b2a87706ec82e3cea30c0e6c1"},
    {"SBTopAffordanceViewController", "sceneHandle", "@16@0:8", 0x1c6ac3bd4ULL, 16, "69713e042135631c28b81e43d1c0a661acb14f9c5fbc0c7cd11942f1a648bcf9"},
    {"SBTopAffordanceViewController", "transientUIHandledTouch:withSystemGestureRecognizer:", "B32@0:8@16@24", 0x1c6ac1b50ULL, 212, "d1d11f0ee521c00b512df6225646d0f65eb626feb1a3143aaa5e6a2bbbfcb1d9"},
    {"SBTopAffordanceViewController", "transientUI:wasIndirectPannedToDismissFromGestureRecognizer:", "v32@0:8@16@24", 0x1c6ac1c24ULL, 256, "b7f8eed28ef18efd6b67c2abe15e50548f0e615099557c5d03299522158462c6"},
    {"SBAffordancePresenceController", "delegate", "@16@0:8", 0x1c64f9db8ULL, 44, "5b2cf7700a53051c255b831f80f8d27603afa0a1e98b9f97b27ff59e9099bdf7"},
    {"SBAffordancePresenceController", "transientUI:wasTappedToUnhideFromGestureRecognizer:", "v32@0:8@16@24", 0x1c64f9db0ULL, 4, "85e69f28f786021202cf3513f5f392f1a10187ec6e4cb1c7aa66b247fa7c1fe7"},
    {"SBDeviceApplicationSceneHandle", "_windowScene", "@16@0:8", 0x1c6873c2cULL, 96, "e4982589122429a6438870c05287a13e942ec75d142ac4e5f80242fe67459a49"},
    {"SBSystemGestureManager", "removeGestureRecognizer:", "v24@0:8@16", 0x1c64a3350ULL, 352, "6ae13b3b72a075cf9cdb9896002ca4abe631a92f90d8d255a6455f23c1d3e8d3"},
    {"SBSystemGestureManager", "windowForSystemGestures", "@16@0:8", 0x1c64cbf10ULL, 100, "f1f2cb6e988d729d78e367f5ce9d93054d34dab10f78a83f97378fbcc55aa65a"},
    {"SBSystemGestureManager", "addGestureRecognizer:withType:", "v32@0:8@16Q24", 0x1c64b29b4ULL, 572, "377799555db393cdfe48f98849a3fa7ae870873a751f73c1edc86b27b2cb1f6a"},
    {"SBWindowScene", "_abstractWindowSceneDelegate", "@16@0:8", 0x1c69b0b88ULL, 188, "51b61526d4adc354aa0496f3bbbe78647fd564e76d0adddf7da236473e32ccda"},
    {"SBWindowScene", "systemGestureManager", "@16@0:8", 0x1c69b1318ULL, 76, "5cc73a7a190e4fb1ac4356a71726b7260eb953556f68f0cd016c7df0dd567695"},
    {"SBAbstractWindowSceneDelegate", "_sbWindowSceneContext", "@16@0:8", 0x1c664ebb8ULL, 8, "604286874435be764e76f375d17e53f2236891f75ca45d244627e2ab6417cc24"},
};
static uintptr_t CodeAddress(IMP imp) {
#if __has_feature(ptrauth_calls)
    return reinterpret_cast<uintptr_t>(ptrauth_strip(reinterpret_cast<void *>(imp), ptrauth_key_function_pointer));
#else
    return reinterpret_cast<uintptr_t>(imp);
#endif
}
static bool ImageSlide(intptr_t *slide) {
    static const uint8_t uuid[] = {0xec,0xd3,0xe9,0xa8,0xc6,0x38,0x36,0x74,0xba,0x49,0x61,0x55,0xd8,0xdc,0x97,0x35};
    const char *suffix = "/SpringBoard.framework/SpringBoard";
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name || strlen(name) < strlen(suffix) || strcmp(name + strlen(name) - strlen(suffix), suffix)) continue;
        const auto *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        if (!header || header->magic != MH_MAGIC_64) return false;
        const uint8_t *cursor = reinterpret_cast<const uint8_t *>(header + 1);
        const uint8_t *end = cursor + header->sizeofcmds;
        for (uint32_t j = 0; j < header->ncmds; ++j) {
            if (size_t(end - cursor) < sizeof(load_command)) return false;
            const auto *command = reinterpret_cast<const load_command *>(cursor);
            if (command->cmdsize < sizeof(load_command) || command->cmdsize > size_t(end - cursor)) return false;
            if (command->cmd == LC_UUID && command->cmdsize == sizeof(uuid_command)) {
                if (memcmp(reinterpret_cast<const uuid_command *>(cursor)->uuid, uuid, sizeof(uuid))) return false;
                *slide = _dyld_get_image_vmaddr_slide(i);
                return true;
            }
            cursor += command->cmdsize;
        }
        return false;
    }
    return false;
}
static bool Digest(uintptr_t address, size_t size, const char *expected) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(reinterpret_cast<const void *>(address), (CC_LONG)size, digest);
    char actual[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (size_t i = 0; i < sizeof(digest); ++i) snprintf(actual + i * 2, 3, "%02x", digest[i]);
    return !strcmp(actual, expected);
}
static bool Signature(const char *cls, const char *selector, const char *encoding) {
    Method method = class_getInstanceMethod(objc_getClass(cls), sel_registerName(selector));
    return method && !strcmp(method_getTypeEncoding(method), encoding);
}
static bool Install() {
    // Validate every hook and dependency before mutating even one IMP.
    if (![NSThread isMainThread] || ![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return false;
    char build[64] = {}; size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, nullptr, 0) || strcmp(build, "20B82")) return false;
    intptr_t slide = 0;
    if (!ImageSlide(&slide)) return false;
    for (const auto &contract : contracts) {
        Class cls = objc_getClass(contract.cls[0] == '+' ? contract.cls + 1 : contract.cls);
        Method method = contract.cls[0] == '+' ? class_getClassMethod(cls, sel_registerName(contract.selector))
                                              : class_getInstanceMethod(cls, sel_registerName(contract.selector));
        if (!method || strcmp(method_getTypeEncoding(method), contract.encoding) ||
            CodeAddress(method_getImplementation(method)) != contract.address + slide ||
            !Digest(contract.address + slide, contract.size, contract.hash)) return false;
    }
    Method sharedApplication = class_getClassMethod(objc_getClass("UIApplication"), sel_registerName("sharedApplication"));
    if (!sharedApplication || strcmp(method_getTypeEncoding(sharedApplication), "@16@0:8")) return false;
    // Public UIKit ABI, plus the native failing recognizer's own initializer.
    if (!Signature("SBFailingSystemGestureRecognizer", "init", "@16@0:8") ||
        !Signature("UIGestureRecognizer", "initWithTarget:action:", "@32@0:8@16:24") ||
        !Signature("UIGestureRecognizer", "setDelegate:", "v24@0:8@16") ||
        !Signature("UIGestureRecognizer", "setName:", "v24@0:8@16") ||
        !Signature("UIGestureRecognizer", "setAllowedTouchTypes:", "v24@0:8@16") ||
        !Signature("UIGestureRecognizer", "setCancelsTouchesInView:", "v20@0:8B16") ||
        !Signature("UIGestureRecognizer", "setDelaysTouchesBegan:", "v20@0:8B16") ||
        !Signature("UIGestureRecognizer", "setDelaysTouchesEnded:", "v20@0:8B16") ||
        !Signature("UIGestureRecognizer", "requireGestureRecognizerToFail:", "v24@0:8@16") ||
        !Signature("UITapGestureRecognizer", "setNumberOfTapsRequired:", "v24@0:8Q16") ||
        !Signature("UIPanGestureRecognizer", "setAllowedScrollTypesMask:", "v24@0:8q16") ||
        !Signature("UIGestureRecognizer", "state", "q16@0:8")) return false;
    topAffordanceClass = objc_getClass("SBTopAffordanceViewController");
    presenceClass = objc_getClass("SBAffordancePresenceController");
    Class oldManager = objc_getClass("SBTransientUIInteractionManager");
    Class context = objc_getClass("SBWindowSceneContext");
    Class external = objc_getClass("SBExternalDisplayWindowSceneDelegate");
    if (!topAffordanceClass || !presenceClass || !oldManager || !context || !external) return false;
    static const char *registerNames[] = {"registerParticipantForTapToDismiss:", "registerParticipantForTapToUnhide:", "registerParticipantForIndirectPanToDismiss:"};
    static const char *unregisterNames[] = {"unregisterParticipantForTapToDismiss:", "unregisterParticipantForTapToUnhide:", "unregisterParticipantForIndirectPanToDismiss:"};
    const IMP registerHooks[] = {reinterpret_cast<IMP>(RegisterTap), reinterpret_cast<IMP>(RegisterUnhide), reinterpret_cast<IMP>(RegisterPan)};
    const IMP unregisterHooks[] = {reinterpret_cast<IMP>(UnregisterTap), reinterpret_cast<IMP>(UnregisterUnhide), reinterpret_cast<IMP>(UnregisterPan)};
    Method reg[3], unreg[3];
    for (NSUInteger i = 0; i < 3; ++i) {
        reg[i] = class_getInstanceMethod(oldManager, sel_registerName(registerNames[i]));
        unreg[i] = class_getInstanceMethod(oldManager, sel_registerName(unregisterNames[i]));
        originalRegister[i] = reinterpret_cast<ParticipantFn>(method_getImplementation(reg[i]));
        originalUnregister[i] = reinterpret_cast<ParticipantFn>(method_getImplementation(unreg[i]));
    }
    Method view = class_getInstanceMethod(oldManager, sel_registerName("viewForSystemGestureRecognizer:"));
    originalView = reinterpret_cast<ViewFn>(method_getImplementation(view));
    Method setter = class_getInstanceMethod(context, sel_registerName("setSystemGestureManager:"));
    Method destructor = class_getInstanceMethod(context, sel_registerName(".cxx_destruct"));
    Method disconnect = class_getInstanceMethod(external, sel_registerName("sceneDidDisconnect:"));
    originalSetGM = reinterpret_cast<SetterFn>(method_getImplementation(setter));
    originalContextDestructor = reinterpret_cast<DestructorFn>(method_getImplementation(destructor));
    originalDisconnect = reinterpret_cast<SetterFn>(method_getImplementation(disconnect));
    method_setImplementation(view, reinterpret_cast<IMP>(LegacyView));
    method_setImplementation(setter, reinterpret_cast<IMP>(SetSystemGestureManager));
    method_setImplementation(destructor, reinterpret_cast<IMP>(ContextDestructor));
    method_setImplementation(disconnect, reinterpret_cast<IMP>(SceneDidDisconnect));
    for (NSUInteger i = 0; i < 3; ++i) {
        method_setImplementation(reg[i], registerHooks[i]);
        method_setImplementation(unreg[i], unregisterHooks[i]);
    }
    return true;
}
#endif // ESM_HOST_TEST
} // namespace

extern "C" bool ESMInstallSceneMenuRouting(void) {
#ifndef ESM_HOST_TEST
    static bool installed;
    if (![NSThread isMainThread]) return false;
    if (!installed) installed = Install();
    return installed;
#else
    return false;
#endif
}
