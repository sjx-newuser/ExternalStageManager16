# Sidebar cancellation contract

The sidebar hook is restricted to the validated 20B82 hover-cancellation
callsite and system-image/code/layout contracts in `SidebarScope.mm`.
Within that call, cancellation uses the gesture recognizer's owning display.
Other callers keep their original behavior. The scope is thread-local and
is cleared on exit, including exception cleanup. Failure to verify a
contract prevents installation of this module.

This is not a global active-display override. It does not replace the whole
UIKit hover-filter pipeline. The per-screen menu and backboardd modules
handle separate parts of the input path. See the root README for module
configuration, validation limits, and recovery.
