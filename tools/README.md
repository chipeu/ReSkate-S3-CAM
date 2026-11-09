# Tools

## Validate and package the compatibility test build
From the repository root, run `python tools/package_release.py` (Python 3, standard library only).
This runs the offline suites and strict golden-trace parity, then makes the installable ZIP and
a validation JSON in `release/`. It ships only `Dynamic_Camera/` metadata/assets and `plugin/*.lua`.
Each ZIP is directly in `release/`, with a new version in its filename and one stable installation folder inside it.
`tools/release_config.json` pins the existing installation identity; do not change it to match a new version number.
Import the ZIP and choose Replace. Saved settings and presets live outside that folder and are not packaged or overwritten.
Increase manifest.json's version_number and update the changelog and Dynamic_Camera/README.md build line for every patch; the packer rejects stale README versions as well as reused/older releases.
Old ZIPs are never overwritten. Archives cannot contain other ZIPs, user settings, or preset data.
Packaging also checks installer-root selection and preservation of external settings/presets in a temporary fixture.
The core suite includes `test_crouch.lua`: amplitude, settings persistence, missing ground, slopes, collision, takeoff, and
30/60/144 FPS comparisons, including a direct comparison with the camera extracted from the 1.1.3 package at 100%.
The offline runner and saved golden traces below must already be available. Gameplay validation is separate.

## luau_run (offline tests)
A small Luau runner built from ReSkate 2.1.2's own Luau source, so the tests run the compiler and VM the game uses
(optimisation level 1, like the game's plugin host).

1. Extract the Luau source from a ReSkate checkout that has the v2.1.2 tag:
   `git -C <ReSkate> archive v2.1.2 External/luau | tar -x -C tools/luau-src`
2. Build with MSVC (x64 developer prompt), from this folder:
   `cl /nologo /O2 /std:c++17 /EHsc /MP /I luau-src/External/luau/Common/include /I luau-src/External/luau/Ast/include /I luau-src/External/luau/Compiler/include /I luau-src/External/luau/VM/include /I luau-src/External/luau/Bytecode/include /I luau-src/External/luau/VM/src luau_run.cpp luau-src/External/luau/Ast/src/*.cpp luau-src/External/luau/Compiler/src/*.cpp luau-src/External/luau/VM/src/*.cpp luau-src/External/luau/Common/src/*.cpp /Fe:luau_run.exe`

Run tests from the repository root:
- core modules: `tools/luau_run.exe -I Dynamic_Camera/plugin tests/run_core.lua`
- parity with the C++ camera: `tools/luau_run.exe -I Dynamic_Camera/plugin -I tests -I tools/trace/out tests/run_parity.lua`
- glue: `tools/luau_run.exe -I Dynamic_Camera/plugin -I tests tests/test_glue.lua real` and `tests/test_main.lua`

## trace (golden traces)
`tools/trace/regen.ps1` builds `trace_gen.cpp` against the C++ camera (a ReSkate checkout on the dynamic-camera branch)
and writes the traces to `tools/trace/out/`. See `tools/trace/FORMAT.md`.

## Experimental custom UI test build
Run `python tools/package_release.py --test` for the explicitly named
`release/DynamicCamera-<version>-TEST.zip`. It runs the same regression and update checks
plus `test_ui_126.lua`. The installation folder stays `aescher-Dynamic_Camera`.
Test builds are marked experimental in the validation report; no publication occurs.

For an offline drawing-command preview, run `tests/render_ui_126.lua` through luau_run
and save its output, then pass it to `tools/render_ui_preview.ps1 -Commands <log> -Output <folder>`.
The preview uses Segoe UI as an approximation of the host font and proves no gameplay behavior.
