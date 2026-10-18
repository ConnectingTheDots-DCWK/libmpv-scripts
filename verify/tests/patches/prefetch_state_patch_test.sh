#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks that patch_prefetch_state.py fails when the bail of the prefetch
# hook no longer matches its anchor, and leaves the tree as it was (F59).
# Controls: the clean hook output and a tree without the hook both patch.
#
# Usage: bash verify/tests/patches/prefetch_state_patch_test.sh <pristine mpv source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MPV="${1:?usage: prefetch_state_patch_test.sh <pristine mpv source dir> <work dir>}"
T="${2:?usage: prefetch_state_patch_test.sh <pristine mpv source dir> <work dir>}"
P="$ROOT/patches/mpv/shared"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
tree() { mkdir -p "$T/$1/player"; cp "$MPV"/player/{core.h,command.c,loadfile.c,playloop.c} "$T/$1/player/"; }

# control 1: hook, then state.
tree ok; python3 -B "$P/patch_prefetch_hook.py" "$T/ok/player/loadfile.c" > /dev/null
python3 -B "$P/patch_prefetch_state.py" "$T/ok" > /dev/null 2>&1; check $? "hook output: prefetch_state applies"
python3 -c "import sys; t=open(sys.argv[1]).read(); sys.exit(0 if 'mak_set_prefetch_state(mpctx, 0 /* idle */);\n            talloc_free(resolved_url);' in t else 1)" "$T/ok/player/loadfile.c"
check $? "hook output: the bail resets prefetch-state"

# control 2: no hook.
tree nohook
python3 -B "$P/patch_prefetch_state.py" "$T/nohook" > /dev/null 2>&1; check $? "no hook: prefetch_state applies"

# the case: hook with its bail renamed (resolved_url -> url_out).
tree bad; python3 -B "$P/patch_prefetch_hook.py" "$T/bad/player/loadfile.c" > /dev/null
python3 - "$T/bad/player/loadfile.c" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read()
old = '            talloc_free(resolved_url);\n            return;\n'
assert t.count(old) == 1
open(p, 'w').write(t.replace(old, '            talloc_free(url_out);\n            return;\n'))
PY
cp -a "$T/bad" "$T/bad.before"
python3 -B "$P/patch_prefetch_state.py" "$T/bad" > "$T/bad.log" 2>&1; r=$?
[[ $r != 0 ]]; check $? "renamed bail: prefetch_state fails (exit $r)"
diff -r "$T/bad.before" "$T/bad" > /dev/null; check $? "renamed bail: no file written"

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
