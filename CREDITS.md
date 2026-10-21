# Credits and source provenance

## TrollPad — khanhduytran0 (Duy Tran) and contributors

Project: https://github.com/khanhduytran0/TrollPad

Reference snapshot: `3a841b3aa26d96df2acbcdb129dcfddf69a62b06` (inspected during publication preparation).

Source: https://github.com/khanhduytran0/TrollPad/blob/3a841b3aa26d96df2acbcdb129dcfddf69a62b06/TweakSB.x

`availability-resize/Tweak.xm` derives these parts from TrollPad:

- Hooking `SBFIsChamoisExternalDisplayControllerAvailable` to enable external
  Stage Manager on early iOS 16.
- The replacement function's arm64e/PAC workaround, including the retained
  code comment and conditional `printf` statement.
- The external-screen `SBFluidSwitcherItemContainer` resize hook approach.
  This package selects only the bottom-right corner; its mask was inferred
  from TrollPad's documented bottom-corner mask and UIKit corner ordering.

The `routing/` implementation was developed separately by comparing the
16.1/16.2 system behavior. Its per-screen menu management, sidebar cancellation
scope, and backboardd pointer-exit handling are not taken from TrollPad.
TrollPad is not a runtime dependency, and its maintainers have not reviewed
or endorsed this project.

The repository's MIT license grants rights held by this project's contributors.
It does not relicense TrollPad-derived code or assert a license on the original
TrollPad project. No explicit license was found in the inspected TrollPad tree
or README; redistribution permission for these derived portions remains
unconfirmed. Attribution records provenance and does not itself grant permission.

## Platform and build tools

This project uses Apple platform APIs/private interfaces and the jailbreak
hooking interfaces declared by its build dependencies. Apple system images,
framework binaries, and SDKs are not distributed in this source tree.
