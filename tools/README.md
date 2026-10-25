# Tools

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
