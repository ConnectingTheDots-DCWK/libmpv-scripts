#!/usr/bin/env bash
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

# Checks patches/ffmpeg/patch_ffmpeg_embed_cacert.py on pristine FFmpeg: the
# roots load only when tls_verify is on (F90), a second run changes nothing,
# a tree patched by the version without that gate is brought up to date,
# and with its include or CA block anchor missing it fails and leaves
# tls_openssl.c as it was. verify/tests/network_test.sh checks what the
# patched TLS code does.
#
# Usage: bash verify/tests/patches/embed_cacert_patch_test.sh <pristine ffmpeg source dir> <work dir>

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
REF="${1:?usage: embed_cacert_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
T="${2:?usage: embed_cacert_patch_test.sh <pristine ffmpeg source dir> <work dir>}"
P="$ROOT/patches/ffmpeg/patch_ffmpeg_embed_cacert.py"
TLS=libavformat/tls_openssl.c
rm -rf "$T"; mkdir -p "$T"
fails=0
check() { if [[ "$1" == 0 ]]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
tree() { mkdir -p "$T/$1/libavformat"; cp "$REF"/libavformat/{tls_openssl.c,Makefile} "$T/$1/libavformat/"; }
# gated <file>: the roots and the system store load in the verify branch
# only, and the include and the loader call are there once.
gated() {
  grep -qF '    } else if (s->verify) {' "$1" && grep -qF 'MAK_EMBED_CACERT_VERIFY' "$1" &&
    [[ "$(grep -c 'ff_load_embedded_ca(c->ctx)' "$1")" == 1 ]] &&
    [[ "$(grep -c '#include "ca_bundle.h"' "$1")" == 1 ]]
}
edit() { python3 - "$@" <<'PY'
import sys
p, old, new = sys.argv[1:]
t = open(p).read()
assert t.count(old) == 1, old
open(p, 'w').write(t.replace(old, new))
PY
}

tree ok
python3 -B "$P" "$T/ok" > "$T/ok.log" 2>&1; check $? "pristine: the patch applies"
gated "$T/ok/$TLS"; check $? "pristine: the roots load only with verify"
for f in ca_bundle.h ca_bundle_loader.c ca_bundle_data.c; do
  [[ -s "$T/ok/libavformat/$f" ]]; check $? "pristine: $f written"
done
[[ "$(grep -c 'ca_bundle_data.o ca_bundle_loader.o' "$T/ok/libavformat/Makefile")" == 1 ]]
check $? "pristine: the Makefile builds the bundle once"
cp -a "$T/ok" "$T/ok.before"
python3 -B "$P" "$T/ok" > /dev/null 2>&1; check $? "pristine: a second run applies"
diff -r "$T/ok.before" "$T/ok" > /dev/null; check $? "pristine: a second run changes nothing"

# A tree as the version without the gate left it: the same block with a
# plain else, which loaded the roots for every handshake.
cp -a "$T/ok.before" "$T/old"
python3 - "$T/old/$TLS" 2> "$T/old.make.log" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p).read()
t, n = re.subn(r'    \} else if \(s->verify\) \{\n        /\* MAK_EMBED_CACERT_VERIFY:.*?\*/\n',
               '    } else {\n', t, flags=re.S)
assert n == 1
open(p, 'w').write(t)
PY
check $? "old tree: made from the patched one"
! grep -q 'else if (s->verify)' "$T/old/$TLS"; check $? "old tree: no gate"
python3 -B "$P" "$T/old" > "$T/old.log" 2>&1; check $? "old tree: the patch applies"
gated "$T/old/$TLS"; check $? "old tree: brought up to date, include once"
cmp -s "$T/old/$TLS" "$T/ok/$TLS"; check $? "old tree: same file as from pristine"

# broken <name> <file> <anchor> <replacement>: the patch fails and
# tls_openssl.c stays as it was.
broken() {
  tree "$1"; edit "$T/$1/$2" "$3" "$4"
  cp "$T/$1/$TLS" "$T/$1.before"
  python3 -B "$P" "$T/$1" > "$T/$1.log" 2>&1; local r=$?
  [[ $r != 0 ]]; check $? "$1: the patch fails (exit $r)"
  cmp -s "$T/$1.before" "$T/$1/$TLS"; check $? "$1: tls_openssl.c unchanged"
}
broken include "$TLS" '#include <openssl/x509v3.h>' '#include <openssl/x509.h>'
broken block "$TLS" '        if (!SSL_CTX_set_default_verify_paths(c->ctx)) {' \
  '        if (!SSL_CTX_set_default_verify_paths(c->ctx)) { /**/'
broken makefile libavformat/Makefile 'TLS-OBJS-$(CONFIG_OPENSSL)' 'TLS-OBJS-$(CONFIG_OPENSSL_TLS)'

if (( fails > 0 )); then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
