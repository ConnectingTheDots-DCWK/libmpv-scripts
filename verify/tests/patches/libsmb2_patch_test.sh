#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patches/ffmpeg/patch_ffmpeg_libsmb2.py on pristine FFmpeg: every
# edit in place, libsmb2.c copied, a second run without effect, and with any
# of its anchors in configure, libavformat/Makefile or libavformat/protocols.c
# missing it fails and writes no file (F91).
#
# Usage: bash verify/tests/patches/libsmb2_patch_test.sh <pristine ffmpeg source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REF="${1:?usage: libsmb2_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
T="${2:?usage: libsmb2_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
P="$ROOT/patches/ffmpeg/patch_ffmpeg_libsmb2.py"
SMB="$ROOT/patches/ffmpeg/libsmb2.c"
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
tree() { mkdir -p "$T/$1/libavformat"; cp "$REF/configure" "$T/$1/"; cp "$REF"/libavformat/{Makefile,protocols.c} "$T/$1/libavformat/"; }
has() { grep -qF -- "$2" "$1"; }
edit() { python3 - "$@" <<'PY'
import sys
p, old, new = sys.argv[1:]
t = open(p).read()
assert t.count(old) == 1, old
open(p, 'w').write(t.replace(old, new))
PY
}

# control: pristine tree.
tree ok
python3 -B "$P" "$T/ok" "$SMB" > "$T/ok.log" 2>&1; check $? "pristine: the patch applies"
has "$T/ok/configure" '  --enable-libsmb2         enable SMB2/3 protocol via libsmb2 [no]' &&
  has "$T/ok/configure" 'libsmb2_protocol_deps="libsmb2"' &&
  has "$T/ok/configure" 'enabled libsmb2           && { check_pkg_config libsmb2' &&
  [[ "$(grep -c '^    libsmb2$' "$T/ok/configure")" == 1 ]]
check $? "pristine: configure has the option, the list entry, the dep and the check"
has "$T/ok/libavformat/Makefile" 'OBJS-$(CONFIG_LIBSMB2_PROTOCOL)'; check $? "pristine: Makefile builds libsmb2.o"
has "$T/ok/libavformat/protocols.c" 'extern const URLProtocol ff_libsmb2_protocol;'; check $? "pristine: protocols.c declares the protocol"
cmp -s "$SMB" "$T/ok/libavformat/libsmb2.c"; check $? "pristine: libsmb2.c copied"
cp -a "$T/ok" "$T/ok.before"
python3 -B "$P" "$T/ok" "$SMB" > /dev/null 2>&1; check $? "pristine: a second run applies"
diff -r "$T/ok.before" "$T/ok" > /dev/null; check $? "pristine: a second run changes nothing"

# broken <name> <file> <anchor> <replacement>: with that anchor missing the
# patch fails and the tree stays as it was.
broken() {
  tree "$1"; edit "$T/$1/$2" "$3" "$4"
  cp -a "$T/$1" "$T/$1.before"
  python3 -B "$P" "$T/$1" "$SMB" > "$T/$1.log" 2>&1; local r=$?
  [[ $r != 0 ]]; check $? "$1: the patch fails (exit $r)"
  diff -r "$T/$1.before" "$T/$1" > /dev/null; check $? "$1: no file written"
}
broken help configure '  --enable-libsmbclient    enable Samba protocol via libsmbclient [no]' \
  '  --enable-libsmbclient    enable Samba protocol through libsmbclient [no]'
broken libshine configure $'    libshine\n' $'    libshine_\n'
broken dep configure 'libsmbclient_protocol_deps="libsmbclient gplv3"' 'libsmbclient_protocol_deps="libsmbclient"'
broken check configure 'enabled libsmbclient      &&' 'enabled libsamba          &&'
broken makefile libavformat/Makefile 'OBJS-$(CONFIG_LIBSMBCLIENT_PROTOCOL)     += libsmbclient.o' \
  'OBJS-$(CONFIG_LIBSMBCLIENT_PROTOCOL)     += smbclient.o'
broken protocols libavformat/protocols.c 'extern const URLProtocol ff_libsmbclient_protocol;' \
  'extern const URLProtocol ff_smbclient_protocol;'

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
