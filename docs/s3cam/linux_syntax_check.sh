#!/bin/sh
# Syntax-only check of ReSkate's Windows sources from Linux (cloud sessions without MSVC).
# Needs MinGW-w64 (apt-get install g++-mingw-w64-x86-64-posix). Catches compile errors before a
# Windows build round-trip; it is NOT a substitute for the MSVC /W4 /WX build.
#
#   sh docs/s3cam/linux_syntax_check.sh Extension/Camera/s3cam_probe.cpp Extension/Skater/client_debug.cpp
#
# MSVC SEH (__try / __except) has no MinGW equivalent and libstdc++ uses the name __try itself, so
# the sources are copied to a scratch mirror and SEH blocks are rewritten to plain blocks there.
# The repository is never modified.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${TMPDIR:-/tmp}/reskate-syntax-check
rm -rf "$WORK" && mkdir -p "$WORK/mirror" "$WORK/shim"
# Windows headers are case-insensitive; MinGW's are lowercase. Shim every mixed-case <Name.h>
# the sources include that MinGW has in lowercase.
MINGW_INC=$(echo | x86_64-w64-mingw32-g++ -xc++ -E -v - 2>&1 | sed -n 's/^ \(\/.*mingw32\/include\)$/\1/p' | head -1)
grep -rhoE '#include <[A-Za-z0-9_]*[A-Z][A-Za-z0-9_]*\.h>' "$(dirname "$0")/../../Engine" "$(dirname "$0")/../../Extension" \
    "$(dirname "$0")/../../Runtime" 2>/dev/null | sed -E 's/#include <(.*)>/\1/' | sort -u | while read -r h; do
    lower=$(echo "$h" | tr 'A-Z' 'a-z')
    [ -f "$MINGW_INC/$lower" ] && printf '#pragma once\n#include <%s>\n' "$lower" > "$WORK/shim/$h"
    true
done
cd "$ROOT"
git ls-files -co --exclude-standard Engine Extension Runtime External | tar -cf - -T - | tar -xf - -C "$WORK/mirror"
grep -rlE '__try|__except' "$WORK/mirror/Engine" "$WORK/mirror/Extension" "$WORK/mirror/Runtime" |
    xargs -r sed -i -E 's/__try/if (true)/g; s/__except *\(([^()]|\([^()]*\))*\)/else/g'
cd "$WORK/mirror"
status=0
for f in "$@"; do
    echo "== $f"
    if ! x86_64-w64-mingw32-g++ -std=c++20 -fsyntax-only -I. -IExternal/imgui -I"$WORK/shim" -DNOMINMAX "$f" 2>"$WORK/errors"; then
        grep -E "error" "$WORK/errors" | head -20
        status=1
    fi
done
exit $status
