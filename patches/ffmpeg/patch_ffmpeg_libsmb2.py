#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Patches FFmpeg source tree to add --enable-libsmb2 support.

Modifies:
  - configure            (add option, dep, pkg-config check)
  - libavformat/Makefile (add object)
  - libavformat/protocols.c (add extern declaration)

Also copies libsmb2.c into libavformat/.

Usage:
    python3 patch_ffmpeg_libsmb2.py <ffmpeg_source_dir> <libsmb2_c_path>
"""
import sys, os, re, shutil


# Idempotency marker — re-running the build pipeline against the same
# extracted ffmpeg tree is safe.
MARKER = 'MAK_LIBSMB2_PATCH_V1'


def replace_once(text, anchor, new, path):
    """Replaces the one occurrence of anchor, or raises: a missing or
    repeated anchor means the FFmpeg layout changed, and a silent no-op
    would build without SMB."""
    count = text.count(anchor)
    if count != 1:
        raise RuntimeError(
            'Expected exactly 1 %r in %s, found %d (ffmpeg layout changed?)'
            % (anchor, path, count))
    return text.replace(anchor, new)


# Each patch_* returns the new text, or None when the file is already
# patched. main() writes the files only once every anchor has matched, so a
# missing one leaves the tree as it was.
def patch_configure(path):
    with open(path) as f:
        text = f.read()

    if MARKER in text:
        print(f'Already patched: {path}')
        return None

    # 1. Add help text after the libsmbclient line.
    help_line = '  --enable-libsmbclient    enable Samba protocol via libsmbclient [no]'
    text = replace_once(
        text, help_line,
        help_line + '\n'
        '  --enable-libsmb2         enable SMB2/3 protocol via libsmb2 [no]',
        path)

    # 2. Add libsmb2 to EXTERNAL_LIBRARY_LIST (NOT GPL — libsmb2 is LGPL),
    #    right after 'libshine', which is in that list and not in a GPL one.
    if '    libsmb2\n' not in text:
        text = replace_once(text, '    libshine\n', '    libshine\n    libsmb2\n', path)

    # 3. Add protocol dependency (NOT gpl — this is the key difference).
    #    The MARKER bash comment alongside the dep declaration is what the
    #    early-return at the top of patch_configure() greps for.
    smbclient_dep = 'libsmbclient_protocol_deps="libsmbclient gplv3"'
    if 'libsmb2_protocol_deps' not in text:
        text = replace_once(
            text, smbclient_dep,
            smbclient_dep + '\n# ' + MARKER + '\n' +
            'libsmb2_protocol_deps="libsmb2"',
            path)

    # 4. Add pkg-config check after the libsmbclient check
    smbclient_check = 'enabled libsmbclient'
    if 'enabled libsmb2' not in text:
        count = text.count(smbclient_check)
        if count != 1:
            raise RuntimeError(
                'Expected exactly 1 %r in %s, found %d (ffmpeg layout changed?)'
                % (smbclient_check, path, count))
        idx = text.find(smbclient_check)
        # Find the end of the libsmbclient check block (next blank line or next 'enabled')
        end_idx = text.find('\n\n', idx)
        if end_idx == -1:
            end_idx = text.find('\nenabled ', idx + len(smbclient_check))
        if end_idx == -1:
            raise RuntimeError(
                'End of the libsmbclient check block not found in %s '
                '(ffmpeg layout changed?)' % path)
        insert = ('\nenabled libsmb2           && { check_pkg_config libsmb2 libsmb2 '
                  'smb2/libsmb2.h smb2_init_context ||\n'
                  '                               require libsmb2 smb2/libsmb2.h '
                  'smb2_init_context -lsmb2; }')
        text = text[:end_idx] + insert + text[end_idx:]

    return text


def patch_makefile(path):
    with open(path) as f:
        text = f.read()

    if 'CONFIG_LIBSMB2_PROTOCOL' in text:
        print(f"Already patched: {path}")
        return None

    # Add after libsmbclient line (use regex for flexible whitespace)
    text, count = re.subn(
        r'(OBJS-\$\(CONFIG_LIBSMBCLIENT_PROTOCOL\)\s+\+= libsmbclient\.o)',
        r'\1\nOBJS-$(CONFIG_LIBSMB2_PROTOCOL)              += libsmb2.o',
        text
    )
    if count != 1:
        raise RuntimeError(
            'Expected exactly 1 libsmbclient.o OBJS line in %s, found %d '
            '(ffmpeg Makefile layout changed?)' % (path, count))
    return text


def patch_protocols(path):
    with open(path) as f:
        text = f.read()

    if 'ff_libsmb2_protocol' in text:
        print(f"Already patched: {path}")
        return None

    # Add extern declaration after libsmbclient
    return replace_once(
        text,
        'extern const URLProtocol ff_libsmbclient_protocol;',
        'extern const URLProtocol ff_libsmbclient_protocol;\n'
        'extern const URLProtocol ff_libsmb2_protocol;',
        path)


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <ffmpeg_src_dir> <libsmb2_c_path>")
        sys.exit(1)

    ffmpeg_dir = sys.argv[1]
    libsmb2_c = sys.argv[2]
    if not os.path.isfile(libsmb2_c):
        raise RuntimeError('libsmb2.c not found: %s' % libsmb2_c)

    edits = []
    for patch, rel in ((patch_configure, ('configure',)),
                       (patch_makefile, ('libavformat', 'Makefile')),
                       (patch_protocols, ('libavformat', 'protocols.c'))):
        path = os.path.join(ffmpeg_dir, *rel)
        text = patch(path)
        if text is not None:
            edits.append((path, text))

    for path, text in edits:
        with open(path, 'w') as f:
            f.write(text)
        print(f"Patched: {path}")

    # Copy libsmb2.c into libavformat/
    dest = os.path.join(ffmpeg_dir, 'libavformat', 'libsmb2.c')
    shutil.copy2(libsmb2_c, dest)
    print(f"Copied: {libsmb2_c} -> {dest}")


if __name__ == '__main__':
    main()
