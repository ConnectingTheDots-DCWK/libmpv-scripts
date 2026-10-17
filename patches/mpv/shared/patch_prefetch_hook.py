# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Patch mpv's prefetch_next to run the `on_load` hook before spawning the
opener thread, safely guarded against re-entry.

mpv's prefetch_next (player/loadfile.c) deliberately skips the hook pipeline:
it calls `start_open(..., for_prefetch=true)` directly on the next playlist
entry's raw filename. Any `on_load` hook registered via the client API
(mpv_hook_add) never fires for prefetched files, so clients that rely on
on_load to rewrite `stream-open-filename` for custom URL schemes
(e.g. plex-transcode:// → resolved HLS URL) see the prefetch path reach the
stream layer with an unresolved URL and fail with "No protocol handler found".

This patch mirrors the normal playback path (`play_current_file`) inside
`prefetch_next`: it points the hook view of the player at the prefetch URL,
runs `process_hooks` synchronously on the core thread, reads the
possibly-rewritten URL back, and only then spawns the opener thread.

===== The hook view =====

The playing file keeps `mpctx->filename`, `mpctx->stream_open_filename` and
`mpctx->demuxer` while the hook runs. `process_hooks` pumps `mp_idle`, which
runs client commands and `handle_command_updates`, so everything that reads
those fields keeps working on the playing file: duration, metadata, cover
art, time-pos, the waveform and loudness setters, track switches,
`dump-cache` (cache_dump_poll asserts a demuxer) and the watch-later
commands.

The entry being loaded is seen through three MPContext fields (player/core.h):
`mak_prefetch_hook_active`, `mak_prefetch_filename` and `mak_prefetch_sof`.
While the flag is set, the `path` and `filename` properties report the entry
being loaded, as in a normal on_load, and `stream-open-filename` reads and
writes `mak_prefetch_sof` (player/command.c). The setter refuses a write
while a demuxer is attached, except under the flag, so the hook can still
rewrite the URL of the next entry. `media-title` stays the playing file's.

Older versions masked `mpctx->demuxer` to NULL around the hook instead, and
moved `mpctx->filename` to the prefetch URL. That crashed in cache_dump_poll
with a dump-cache open, hid every demuxer property of the playing file,
turned track switches into no-ops and pointed delete-watch-later-config and
rescan-external-files at the next entry.

===== Re-entry guard =====

`process_hooks` is implemented as a busy loop that pumps `mp_idle` until the
hook signals completion (player/loadfile.c `process_hooks`). `mp_idle` calls
`handle_update_cache` (player/playloop.c). The playing file keeps its
demuxer during the hook, so handle_update_cache runs in full there and at
end-of-file calls `prefetch_next` again:

    handle_update_cache()
        ...
        if (s.eof && !busy)
            prefetch_next(mpctx);     // <-- re-enters us!

Without a guard, the chain prefetch_next → process_hooks → mp_idle →
handle_update_cache → prefetch_next recurses until the core thread stack
overflows (SIGBUS / stack guard violation).

The guard is `mpctx->mak_prefetch_hook_active`, the flag of the hook view.
It belongs to one player and only its core thread reads and writes it, so
two players in one process prefetch independently. Older versions used a
function-scope static shared by every player: one player in a slow hook
made the others skip their prefetch, and the static was a data race.

===== Entry lifetime =====

process_hooks also runs client commands. A `playlist-remove` or
`playlist-clear` sent while the hook runs can remove the prefetched entry,
and with `reserved == 0` playlist_remove frees it on the spot. The patch
takes a reference (`reserved += 1`) before the pump, reads `removed` and
`stream_flags` after it, drops the reference with playlist_entry_unref and
skips the prefetch when the entry is gone. play_current_file holds the
current entry the same way.

===== Memory =====

The prefetch URL is talloc'd locally (`owned_url`) with parent=NULL. The
hook may replace it through the patched `stream-open-filename` setter, which
does:

    mpctx->mak_prefetch_sof =
        talloc_strdup(mpctx->mak_prefetch_sof, *(char **)arg);

i.e. the new allocation becomes a talloc child of `owned_url`. When we
later call `talloc_free(owned_url)`, talloc frees the root and all its
children (including any replacement the hook allocated). Zero double-free,
zero leak.

We snapshot the final string via talloc_strdup into `resolved_url` (also
parent=NULL) before clearing the hook view, so the URL we hand to
start_open() survives the cleanup.

Usage
=====

    python3 patch_prefetch_hook.py <mpv_source_dir>

The older form with the path of player/loadfile.c is still accepted.
"""
import os
import sys

# Present in every file this patch writes, so a second run changes nothing.
MARKER = 'MAK_PREFETCH_HOOK_PATCH_V2'

# Prefix of the prefetch_next comment in every version of this patch.
# patch_prefetch_state.py looks for it to know the hook bail must exist.
HOOK_COMMENT = 'mpv_audio_kit: prefetch_next with on_load hook'

PENDING = []


def write_pending():
    for path, text, label in PENDING:
        with open(path, 'w') as f:
            f.write(text)
        print(f'{label}{path}')


# ─── core.h ────────────────────────────────────────────────────────────

CORE_PRISTINE = (
    '    char *filename; // immutable copy of playing->filename (or NULL)\n'
    '    char *stream_open_filename;\n'
)

CORE_PATCHED = CORE_PRISTINE + (
    '    /* ' + MARKER + ' ─── set by prefetch_next while it runs the\n'
    '     * on_load hook of the next entry (player/loadfile.c). The playing\n'
    '     * file keeps the two fields above and its demuxer. path, filename\n'
    '     * and stream-open-filename report the entry being loaded from these\n'
    '     * (player/command.c). The flag also stops prefetch_next from\n'
    '     * re-entering through the hook pump. Core thread only. */\n'
    '    bool mak_prefetch_hook_active;\n'
    '    char *mak_prefetch_filename;\n'
    '    char *mak_prefetch_sof;\n'
)


# ─── command.c ─────────────────────────────────────────────────────────

COMMAND_SITES = [
    (
        'path getter',
        '    MPContext *mpctx = ctx;\n'
        '    if (!mpctx->filename)\n'
        '        return M_PROPERTY_UNAVAILABLE;\n'
        '    char *path = mp_normalize_path(NULL, mpctx->filename);\n',
        '    MPContext *mpctx = ctx;\n'
        '    /* ' + MARKER + ': the entry the prefetch hook is loading. */\n'
        '    const char *mak_name = mpctx->mak_prefetch_hook_active\n'
        '                           ? mpctx->mak_prefetch_filename\n'
        '                           : mpctx->filename;\n'
        '    if (!mak_name)\n'
        '        return M_PROPERTY_UNAVAILABLE;\n'
        '    char *path = mp_normalize_path(NULL, mak_name);\n',
    ),
    (
        'filename getter',
        '    MPContext *mpctx = ctx;\n'
        '    if (!mpctx->filename)\n'
        '        return M_PROPERTY_UNAVAILABLE;\n'
        '    char *filename = talloc_strdup(NULL, mpctx->filename);\n',
        '    MPContext *mpctx = ctx;\n'
        '    /* ' + MARKER + ': the entry the prefetch hook is loading.\n'
        '     * media-title falls back to this getter with its own name and\n'
        '     * stays the playing file\'s. */\n'
        '    const char *mak_name = mpctx->filename;\n'
        '    if (mpctx->mak_prefetch_hook_active &&\n'
        '        strcmp(prop->name, "filename") == 0)\n'
        '        mak_name = mpctx->mak_prefetch_filename;\n'
        '    if (!mak_name)\n'
        '        return M_PROPERTY_UNAVAILABLE;\n'
        '    char *filename = talloc_strdup(NULL, mak_name);\n',
    ),
    (
        'stream-open-filename property',
        '    MPContext *mpctx = ctx;\n'
        '    if (!mpctx->stream_open_filename || !mpctx->playing)\n'
        '        return M_PROPERTY_UNAVAILABLE;\n'
        '    switch (action) {\n'
        '    case M_PROPERTY_SET: {\n'
        '        if (mpctx->demuxer)\n'
        '            return M_PROPERTY_ERROR;\n'
        '        mpctx->stream_open_filename =\n'
        '            talloc_strdup(mpctx->stream_open_filename, *(char **)arg);\n'
        '        mp_notify_property(mpctx, prop->name);\n'
        '        return M_PROPERTY_OK;\n'
        '    }\n'
        '    case M_PROPERTY_GET_TYPE:\n'
        '    case M_PROPERTY_GET: {\n'
        '        char *path = mp_normalize_path(NULL, mpctx->stream_open_filename);\n',
        '    MPContext *mpctx = ctx;\n'
        '    /* ' + MARKER + ': while prefetch_next runs the on_load hook of\n'
        '     * the next entry, this is that entry\'s URL, writable although the\n'
        '     * playing file has a demuxer. The playing file keeps its own. */\n'
        '    char **sof = mpctx->mak_prefetch_hook_active\n'
        '                 ? &mpctx->mak_prefetch_sof\n'
        '                 : &mpctx->stream_open_filename;\n'
        '    if (!*sof || !mpctx->playing)\n'
        '        return M_PROPERTY_UNAVAILABLE;\n'
        '    switch (action) {\n'
        '    case M_PROPERTY_SET: {\n'
        '        if (mpctx->demuxer && !mpctx->mak_prefetch_hook_active)\n'
        '            return M_PROPERTY_ERROR;\n'
        '        *sof = talloc_strdup(*sof, *(char **)arg);\n'
        '        mp_notify_property(mpctx, prop->name);\n'
        '        return M_PROPERTY_OK;\n'
        '    }\n'
        '    case M_PROPERTY_GET_TYPE:\n'
        '    case M_PROPERTY_GET: {\n'
        '        char *path = mp_normalize_path(NULL, *sof);\n',
    ),
]


# ─── loadfile.c ────────────────────────────────────────────────────────

# Pristine prefetch_next from mpv v0.41.0 (player/loadfile.c).
PRISTINE = (
    'void prefetch_next(struct MPContext *mpctx)\n'
    '{\n'
    '    if (!mpctx->opts->prefetch_open || mpctx->open_active)\n'
    '        return;\n'
    '\n'
    '    struct playlist_entry *new_entry = mp_next_file(mpctx, +1, false, false);\n'
    '    if (new_entry && new_entry->filename) {\n'
    '        MP_VERBOSE(mpctx, "Prefetching: %s\\n", new_entry->filename);\n'
    '        start_open(mpctx, new_entry->filename, new_entry->stream_flags, true);\n'
    '    }\n'
    '}'
)

PATCHED = (
    'void prefetch_next(struct MPContext *mpctx)\n'
    '{\n'
    '    /* ' + HOOK_COMMENT + ' (' + MARKER + ').\n'
    '     *\n'
    '     * process_hooks() below pumps mp_idle, which calls handle_update_cache,\n'
    '     * which at end-of-file calls prefetch_next again. Without this guard we\n'
    '     * recurse until the core thread stack overflows. The flag belongs to\n'
    '     * this player and only its core thread touches it. */\n'
    '    if (mpctx->mak_prefetch_hook_active)\n'
    '        return;\n'
    '\n'
    '    if (!mpctx->opts->prefetch_open || mpctx->open_active)\n'
    '        return;\n'
    '\n'
    '    struct playlist_entry *new_entry = mp_next_file(mpctx, +1, false, false);\n'
    '    if (new_entry && new_entry->filename) {\n'
    '        MP_VERBOSE(mpctx, "Prefetching: %s\\n", new_entry->filename);\n'
    '\n'
    '        /* Run on_load hooks during prefetch so custom URL schemes\n'
    '         * (e.g. plex-transcode://) can be rewritten before the opener\n'
    '         * thread runs. Mirrors the normal play_current_file() path. */\n'
    '        /* process_hooks runs client commands, so a playlist-remove or\n'
    '         * playlist-clear can drop new_entry while the hook runs. Hold a\n'
    '         * reference across the pump, as play_current_file does, and give\n'
    '         * up if the entry was removed meanwhile. */\n'
    '        new_entry->reserved += 1;\n'
    '\n'
    '        /* The playing file keeps filename, stream_open_filename and its\n'
    '         * demuxer, so its properties, commands and cache dump keep\n'
    '         * working while the hook runs. The hook sees the entry being\n'
    '         * loaded: path and filename report mak_prefetch_filename, and\n'
    '         * stream-open-filename reads and writes mak_prefetch_sof, also\n'
    '         * with a demuxer attached (player/command.c). */\n'
    '        char *owned_url = talloc_strdup(NULL, new_entry->filename);\n'
    '        mpctx->mak_prefetch_filename = owned_url;\n'
    '        mpctx->mak_prefetch_sof = owned_url;\n'
    '        mpctx->mak_prefetch_hook_active = true;\n'
    '\n'
    '        process_hooks(mpctx, "on_load");\n'
    '\n'
    '        char *resolved_url = talloc_strdup(NULL, mpctx->mak_prefetch_sof);\n'
    '        mpctx->mak_prefetch_hook_active = false;\n'
    '        mpctx->mak_prefetch_filename = NULL;\n'
    '        mpctx->mak_prefetch_sof = NULL;\n'
    '        talloc_free(owned_url);\n'
    '        /* An observer that read the hook view gets the playing file\n'
    '         * back. Unchanged values send no event. */\n'
    '        mp_notify_property(mpctx, "path");\n'
    '        mp_notify_property(mpctx, "filename");\n'
    '        mp_notify_property(mpctx, "stream-open-filename");\n'
    '\n'
    '        bool entry_removed = new_entry->removed;\n'
    '        int stream_flags = new_entry->stream_flags;\n'
    '        playlist_entry_unref(new_entry);\n'
    '        new_entry = NULL;\n'
    '\n'
    '        if (entry_removed || mpctx->stop_play || mpctx->open_active) {\n'
    '            talloc_free(resolved_url);\n'
    '            return;\n'
    '        }\n'
    '\n'
    '        start_open(mpctx, resolved_url, stream_flags, true);\n'
    '        talloc_free(resolved_url);\n'
    '    }\n'
    '}'
)


def read(path):
    with open(path) as f:
        return f.read()


def patch_core_h(path):
    text = read(path)
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if text.count(CORE_PRISTINE) != 1:
        raise RuntimeError(
            f'Pristine anchor (MPContext filename fields) not found in {path}.'
        )
    PENDING.append((path, text.replace(CORE_PRISTINE, CORE_PATCHED, 1),
                    'Patched: '))


def patch_command_c(path):
    text = read(path)
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    for name, pristine, patched in COMMAND_SITES:
        if text.count(pristine) != 1:
            raise RuntimeError(
                f'Pristine anchor ({name}) not found in {path}.'
            )
        text = text.replace(pristine, patched, 1)
    PENDING.append((path, text, 'Patched: '))


def patch_loadfile_c(path):
    text = read(path)
    if MARKER in text:
        print(f'Already patched: {path}')
        return
    if HOOK_COMMENT in text:
        raise RuntimeError(
            f'An older prefetch_hook patch is applied to {path}. Clean the '
            'extracted mpv source and rebuild:\n'
            '    rm -rf "$BUILD_DIR/src/mpv-<version>"'
        )
    # Apply-order contract: this patch MUST run before patch_prefetch_state.py.
    # That patch inserts its `loading` transition immediately after the
    # MP_VERBOSE("Prefetching") line that our PRISTINE anchor matches
    # verbatim; if it ran first our anchor would no longer match and we'd
    # hard-fail with a misleading "clean the source" message. Detect the
    # inversion explicitly.
    if 'MAK_PREFETCH_STATE_PATCH_V1' in text:
        raise RuntimeError(
            'patch_prefetch_state.py ran before patch_prefetch_hook.py '
            '(wrong apply order). Apply the hook patch first, see '
            'apply_mpv_patches_common() in _audio_only.sh.'
        )
    if text.count(PRISTINE) != 1:
        raise RuntimeError(
            f'Could not find pristine prefetch_next in {path}. Clean the '
            'extracted mpv source and rebuild:\n'
            '    rm -rf "$BUILD_DIR/src/mpv-<version>"'
        )
    PENDING.append((path, text.replace(PRISTINE, PATCHED, 1), 'Patched: '))


def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <mpv_src_dir>')
        sys.exit(1)
    src = sys.argv[1]
    if not os.path.isdir(src):
        # Older form: the path of player/loadfile.c.
        src = os.path.dirname(os.path.dirname(os.path.abspath(src)))
    patch_core_h(os.path.join(src, 'player', 'core.h'))
    patch_command_c(os.path.join(src, 'player', 'command.c'))
    patch_loadfile_c(os.path.join(src, 'player', 'loadfile.c'))
    write_pending()


if __name__ == '__main__':
    main()
