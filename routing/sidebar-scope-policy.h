#pragma once
#include <cstdint>

namespace esm_sidebar {
// Stack storage is valid only during the synchronous original method call.
struct Scope {
    void *recognizer;
    Scope *previous;
};
inline bool ShouldSubstitute(const Scope *scope, const void *display,
                             uintptr_t caller, uintptr_t expectedCaller) {
    return scope && scope->recognizer && !display && expectedCaller &&
           caller == expectedCaller;
}
}
