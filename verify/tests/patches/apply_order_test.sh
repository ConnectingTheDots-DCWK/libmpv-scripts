#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Applies the mpv patches to pristine mpv in the order of each platform's
# build script, the shared ones through apply_mpv_patches_common of
# scripts/shared/_audio_only.sh, then a second time: the first run must
# succeed and the second must change nothing. The Apple export filter is
# left out (it needs the build prefix).
#
# Usage: bash verify/tests/patches/apply_order_test.sh <pristine mpv source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MPV="${1:?usage: apply_order_test.sh <pristine mpv source dir> <work dir>}"
T="${2:?usage: apply_order_test.sh <pristine mpv source dir> <work dir>}"
M="$ROOT/patches/mpv"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }

# apply <platform> <dir>: the mpv patch steps of build_libmpv_<platform>.sh.
apply() (
  set -e
  # shellcheck source=/dev/null
  source "$ROOT/scripts/shared/_helpers.sh"
  # shellcheck source=/dev/null
  source "$ROOT/scripts/shared/_versions.sh"
  # shellcheck source=/dev/null
  source "$ROOT/scripts/shared/_audio_only.sh"
  # Every patch on, whatever a local Settings override disabled.
  DISABLED_PATCHES=""
  local d="$2"
  case "$1" in
    linux)
      apply_mpv_patches_common "$d"
      python3 "$M/linux/patch_optional_audio_libs.py" "$d" ;;
    android)
      apply_mpv_patches_common "$d"
      if [[ -f "$M/android/patch_audiotrack.py" ]]; then python3 "$M/android/patch_audiotrack.py" "$d"; fi ;;
    ios)
      python3 "$M/ios/patch_ios_platform.py" "$d" iphoneos
      python3 "$M/ios/patch_ios_audio_stubs.py" "$d"
      python3 "$M/apple/patch_utils_mac.py" "$d/meson.build"
      python3 "$M/ios/patch_compat_apple.py" "$d"
      apply_mpv_patches_common "$d" ;;
    macos)
      python3 "$M/apple/patch_utils_mac.py" "$d/meson.build"
      apply_mpv_patches_common "$d" ;;
    windows)
      python3 "$M/windows/patch_windows_deps.py" "$d/meson.build"
      python3 "$M/windows/patch_timer_resolution.py" "$d"
      apply_mpv_patches_common "$d" ;;
  esac
)

for p in linux android ios macos windows; do
  cp -a "$MPV" "$T/$p"
  apply $p "$T/$p" > "$T/$p-1.log" 2>&1; r=$?
  check $r "$p: the patches apply (exit $r)"
  (( r == 0 )) || { tail -5 "$T/$p-1.log"; continue; }
  cp -a "$T/$p" "$T/$p.before"
  apply $p "$T/$p" > "$T/$p-2.log" 2>&1; r=$?
  check $r "$p: a second run applies (exit $r)"
  diff -r "$T/$p.before" "$T/$p" > "$T/$p.diff"; check $? "$p: a second run changes nothing"
  rm -rf "$T/$p.before"
done

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
