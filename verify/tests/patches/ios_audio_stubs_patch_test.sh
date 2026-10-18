#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks the audio session edits of patches/mpv/ios/patch_ios_audio_stubs.py
# on pristine mpv. It must drop the MixWithOthers block of ao_audiounit.m
# (F62) and mpv's setMode:MoviePlayback from ao_audiounit.m and
# ao_avfoundation.m (F187), keep setCategory and setActive, and run a second
# time without effect. When the block or a setMode call is not in the shape
# it removes, it must fail and write no file.
#
# Usage: bash verify/tests/patches/ios_audio_stubs_patch_test.sh <pristine mpv source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MPV="${1:?usage: ios_audio_stubs_patch_test.sh <pristine mpv source dir> <work dir>}"
T="${2:?usage: ios_audio_stubs_patch_test.sh <pristine mpv source dir> <work dir>}"
P="$ROOT/patches/mpv/ios/patch_ios_audio_stubs.py"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
tree() { mkdir -p "$T/$1/audio/out"; cp "$MPV"/audio/out/{ao_avfoundation.m,ao_audiounit.m,ao.h,ao_coreaudio_utils.c} "$T/$1/audio/out/"; }
edit() { python3 - "$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:]
t = open(p).read()
assert t.count(old) == 1, old
open(p, 'w').write(t.replace(old, new))
PY
}
# broken <name>: the patch fails on tree <name> and writes no file.
broken() {
  cp -a "$T/$1" "$T/$1.before"
  python3 -B "$P" "$T/$1" > "$T/$1.log" 2>&1; local r=$?
  [[ $r != 0 ]]; check $? "$1: the patch fails (exit $r)"
  diff -r "$T/$1.before" "$T/$1" > /dev/null; check $? "$1: no file written"
}
AU=audio/out/ao_audiounit.m
AVF=audio/out/ao_avfoundation.m
BLOCK='    if (!(ao->init_flags & AO_INIT_EXCLUSIVE)) {
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
'
MODE='    [instance setMode:AVAudioSessionModeMoviePlayback error:nil];
'

# control: pristine tree.
tree ok
python3 -B "$P" "$T/ok" > "$T/ok.log" 2>&1; check $? "pristine: the patch applies"
! grep -q AVAudioSessionCategoryOptionMixWithOthers "$T/ok/$AU"; check $? "pristine: MixWithOthers is gone"
for f in $AU $AVF; do
  ! grep -q 'setMode:' "$T/ok/$f"; check $? "pristine: no setMode left in $(basename $f)"
  grep -q 'setCategory:AVAudioSessionCategoryPlayback' "$T/ok/$f"; check $? "pristine: setCategory kept in $(basename $f)"
  grep -q 'setActive:YES' "$T/ok/$f"; check $? "pristine: setActive kept in $(basename $f)"
done
cp -a "$T/ok" "$T/ok.before"
python3 -B "$P" "$T/ok" > /dev/null 2>&1; check $? "pristine: a second run applies"
diff -r "$T/ok.before" "$T/ok" > /dev/null; check $? "pristine: a second run changes nothing"

# MixWithOthers set with no if block around it.
tree mix-noif
edit "$T/mix-noif/$AU" "$BLOCK" '    options |= AVAudioSessionCategoryOptionMixWithOthers;
'
broken mix-noif

# The block plus a second use of the option.
tree mix-twice
edit "$T/mix-twice/$AU" "$BLOCK" "$BLOCK"'    if (p->mix) options |= AVAudioSessionCategoryOptionMixWithOthers;
'
broken mix-twice

# The audiounit setMode takes an error pointer.
tree mode-err
edit "$T/mode-err/$AU" "$MODE" '    [instance setMode:AVAudioSessionModeMoviePlayback error:&err];
'
broken mode-err

# audiounit sets another mode next to MoviePlayback.
tree mode-other
edit "$T/mode-other/$AU" "$MODE" "$MODE"'    [instance setMode:AVAudioSessionModeSpokenAudio error:nil];
'
broken mode-other

# The avfoundation call changed shape.
tree mode-shape
edit "$T/mode-shape/$AVF" "$MODE" '    [instance setMode:AVAudioSessionModeMoviePlayback
                error:nil];
'
broken mode-shape

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
