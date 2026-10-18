#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patches/ffmpeg/patch_ffmpeg_filter_bounds.py at runtime. It builds a
# minimal FFmpeg with AddressSanitizer, libavfilter with only the filters the
# patch touches, applies the patch first, and runs every case of
# filter_bounds_test.c in its own process: values the patch refuses, the
# leaks it closes, and valid values that must keep working. An ASan or
# LeakSanitizer report fails the case.
#
# --pristine skips the patch, to see the cases fail on upstream FFmpeg.
# Without a tarball it downloads the pinned one and checks its SHA-256. The
# work dir is wiped first. Needs clang (CC and FFMPEG_TOOLCHAIN override it,
# e.g. gcc and gcc-asan), make and pkg-config. About two minutes at JOBS=4.
#
# Usage: bash verify/tests/filter_bounds_test.sh [--pristine] <work dir> [ffmpeg tarball]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PRISTINE=0
if [[ "${1:-}" == "--pristine" ]]; then PRISTINE=1; shift; fi
WORK="${1:?usage: filter_bounds_test.sh [--pristine] <work dir> [ffmpeg tarball]}"
TARBALL="${2:-}"
CC="${CC:-clang}"
JOBS="${JOBS:-4}"
# shellcheck source=/dev/null
source "$ROOT/scripts/shared/_versions.sh"

rm -rf "$WORK"
mkdir -p "$WORK/build"
WORK="$(cd "$WORK" && pwd)"
URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.gz"
SHA="$(awk -v u="$URL" '$2 == u { print $1 }' "$ROOT/scripts/shared/_sources.sha256")"
[[ -n "$SHA" ]] || { echo "FAIL: no pinned SHA-256 for $URL"; exit 1; }
if [[ -z "$TARBALL" ]]; then
  TARBALL="$WORK/ffmpeg-${FFMPEG_VERSION}.tar.gz"
  curl -fsSL --retry 3 -o "$TARBALL" "$URL"
fi
echo "$SHA  $TARBALL" | sha256sum -c --quiet
tar -xzf "$TARBALL" -C "$WORK"
SRC="$WORK/ffmpeg-${FFMPEG_VERSION}"

if (( PRISTINE )); then
  echo "pristine FFmpeg $FFMPEG_VERSION, patch not applied"
else
  python3 "$ROOT/patches/ffmpeg/patch_ffmpeg_filter_bounds.py" "$SRC"
fi

FILTERS="abuffer,abuffersink,aresample,adelay,adrc,aecho,aeval,aiir,anequalizer,chorus,compand,dynaudnorm,mcompand,pan"
(
  cd "$WORK/build"
  "$SRC/configure" --prefix="$WORK/prefix" --cc="$CC" --toolchain="${FFMPEG_TOOLCHAIN:-clang-asan}" \
    --disable-everything --disable-autodetect --disable-programs --disable-doc \
    --disable-avdevice --disable-avformat --disable-avcodec --disable-swscale \
    --disable-network --disable-x86asm --disable-stripping --optflags=-O1 \
    --enable-avfilter --enable-swresample --enable-filter="$FILTERS" \
    > "$WORK/configure.log" 2>&1 || { tail -20 "$WORK/configure.log"; exit 1; }
  make -j"$JOBS" install > "$WORK/make.log" 2>&1 || { tail -30 "$WORK/make.log"; exit 1; }
)

export PKG_CONFIG_PATH="$WORK/prefix/lib/pkgconfig"
# shellcheck disable=SC2046
"$CC" -fsanitize=address -g -O1 "$ROOT/verify/tests/filter_bounds_test.c" -o "$WORK/filter_bounds_test" \
  $(pkg-config --cflags --static --libs libavfilter)

FAILS=0
while read -r name; do
  set +e
  out="$(ASAN_OPTIONS=detect_leaks=1 timeout 120 "$WORK/filter_bounds_test" "$name" 2> "$WORK/$name.err")"
  rc=$?
  set -e
  if (( rc == 0 )); then
    echo "ok   $name: $out"
  else
    report="$(grep -m1 -E 'ERROR: (Address|Leak)Sanitizer' "$WORK/$name.err" || true)"
    frame="$(grep -m1 -E '#[0-9]+ .* in [a-z_0-9]+ .*libav' "$WORK/$name.err" | sed -E 's/.* in ([a-z_0-9]+) .*\/([^/]+:[0-9]+).*/\1 \2/' || true)"
    echo "FAIL $name: exit $rc ${report:+${report#*ERROR: } }${frame:+at $frame }${out}"
    FAILS=$((FAILS + 1))
  fi
done < <("$WORK/filter_bounds_test" --list)

if (( FAILS > 0 )); then
  echo "$FAILS case(s) failed"
  exit 1
fi
echo "all cases passed"
