# ExternalStageManager16

Experimental external Stage Manager support and input fixes for iPadOS 16.1.
The validated target is **iPadOS 16.1, build 20B82, on an M1 iPad with a
Dopamine rootless jailbreak**. Other devices and builds are unverified.

## Components

- `availability-resize/`: enables external Stage Manager availability and
  bottom-right window resizing on the external screen. This package includes
  the availability hook; a separate unlock-only package is unnecessary.
- `routing/`: the experimental4 per-screen menu, sidebar, and pointer fixes.
  It includes separate SpringBoard and backboardd payloads.

The routing package checks OS build, system-image UUIDs, method signatures,
code hashes, and layout contracts before enabling the affected hooks.
These compatibility constants identify system software, not individual devices.
Keep these checks intact when building or adapting the code.

## Build and check

Use Theos, an iPhoneOS 16.5 SDK, and the framework dependencies declared in the
Makefiles. Set `THEOS` to your checkout. In each component directory run:

```sh
FINALPACKAGE=1 make package
```

On macOS, run the routing tests from `routing/`:

```sh
sh run-host-tests.sh
```

The tests use host doubles and exercise configuration, lifecycle, routing,
and compatibility guards. They do not simulate UIKit, PAC, or tweak injection
on a real iPad. No Apple firmware or extracted system binaries are included.

## Use and recovery

Install the two built rootless packages using your package manager. Apply them
through the jailbreak's normal userspace restart process. Routing configuration
is in `/var/jb/Library/Application Support/ExternalStageManager16Routing/Modules.plist`.
`SceneMenus`, `PointerRouting`, and `SidebarDisplayScope` can be disabled
individually; configuration is read when the corresponding process starts.

The availability/resize package and routing package are separate. Uninstalling
routing leaves availability/resize installed. If normal interaction becomes
unavailable, fully reboot, disable tweak injection in Dopamine before
re-jailbreaking, and remove the affected package through the package manager.
A reboot into the unjailbroken state stops injection; it does not uninstall it.

## Validation scope

The three routing modules were confirmed enabled on the tested device. The
reported sequence (external app fullscreen, internal app fullscreen, reveal
sidebars, switch apps, then minimize the external app) stopped reproducing the
failure after experimental4. Subsequent everyday use was reported without new
issues. These are limited observations, not a complete regression suite.

Before a wider release, check minimize/close, both sidebars, Dock hiding,
native Stage Manager settings, Settings appearance, menu dismissal, pointer
dragging across screens, window migration, display reconnection, and picture
in picture. Initial Settings-window stretching is outside this fix's scope.
This implements selected behaviors compared with 16.2; it is not a complete
replacement of the window manager.

## Credits and licensing

This project uses the [MIT License](LICENSE) for its original contributions.
The availability unlock, arm64e/PAC workaround, and external-display resize
hook in `availability-resize/Tweak.xm` derive from
[TrollPad](https://github.com/khanhduytran0/TrollPad) by khanhduytran0
(Duy Tran) and contributors. See [CREDITS.md](CREDITS.md) for the exact scope
and source snapshot. The routing fixes were developed separately.

The MIT grant covers rights held by this project's contributors; it does not
relicense third-party code. No explicit TrollPad license was found in the
referenced snapshot, so permission for the derived portions remains unconfirmed.
