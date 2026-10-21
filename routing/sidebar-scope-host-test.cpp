// clang++ -std=c++17 -pthread sidebar-scope-host-test.cpp -o /tmp/esm-sidebar-test
#include "sidebar-scope-policy.h"
#include <cassert>
#include <thread>
#include <atomic>
using namespace esm_sidebar;
static thread_local Scope *active;
struct Invocation {
    Scope frame;
    explicit Invocation(void *recognizer) : frame{recognizer, active} { active = &frame; }
    ~Invocation() { active = frame.previous; }
};
int main() {
    int first, nested, explicitDisplay;
    constexpr uintptr_t expected = 0x1234;
    auto match = [&](const void *display = nullptr, uintptr_t caller = expected) {
        return ShouldSubstitute(active, display, caller, expected);
    };
    assert(!match()); // Unrelated calls never change, even at expected address.
    {
        Invocation outer(&first);
        assert(match());
        assert(!match(&explicitDisplay));
        assert(!match(nullptr, expected + 4));
        assert(!ShouldSubstitute(active, nullptr, expected, 0));
        std::atomic<bool> otherThreadPassed{false};
        std::thread other([&] {
            assert(!match());
            Invocation independent(&nested);
            assert(match());
            assert(active->recognizer == &nested);
            otherThreadPassed = true;
        });
        other.join();
        assert(otherThreadPassed && active->recognizer == &first);
        try {
            Invocation inner(&nested);
            assert(match() && active->recognizer == &nested);
            throw 1;
        } catch (int) {}
        assert(match() && active->recognizer == &first);
    }
    assert(!match());
    Scope empty{nullptr, nullptr};
    assert(!ShouldSubstitute(&empty, nullptr, expected, expected));
}
