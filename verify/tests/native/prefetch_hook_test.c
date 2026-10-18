// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// prefetch_hook_test <mode> <fixtures> <tmpdir>: the prefetch on_load hook
// keeps the playing file (F271, F57, F272, F273). Plays a.flac with b.flac
// next and prefetch on; the client holds the prefetch on_load hook of b
// while a plays and does <mode>:
//   dump    F271: a dump-cache with end=no is open during the hold. r17
//           masks mpctx->demuxer to NULL there and cache_dump_poll aborts.
//   props   F57: during the hold time-pos, duration, seekable, the title
//           tag and media-title are a's, while path, filename and
//           stream-open-filename are b's (the entry being loaded). The hook
//           rewrites stream-open-filename to c.flac and the transition uses
//           the prefetched c.
//   tracks  F272: audio-add c.flac select during the hold switches the
//           playing track.
//   resume  F273: delete-watch-later-config during the hold deletes the
//           file of a, the playing file.
//   title   F57: with an untagged a, media-title is a's file name during the
//           hold, while filename is b's.
//   clear   regression guard of r17: playlist-clear during the hold frees
//           no entry in use and prefetch-state goes back to idle.
#include "mpv_test.h"

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s dump|props|tracks|resume|title|clear <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    char a[1024], b[1024], c[1024], rec[1024];
    snprintf(a, sizeof a, "%s/%s", argv[2],
             strcmp(mode, "title") == 0 ? "a_notag.flac" : "a.flac");
    snprintf(b, sizeof b, "%s/b.flac", argv[2]);
    snprintf(c, sizeof c, "%s/c.flac", argv[2]);
    snprintf(rec, sizeof rec, "%s/rec.mka", argv[3]);

    mpv_handle *h = mt_create();
    if (strcmp(mode, "resume") == 0)
        mpv_set_option_string(h, "watch-later-dir", argv[3]);
    mpv_initialize(h);
    mpv_hook_add(h, 0, "on_load", 0);
    mt_cmd(h, "loadfile", a, NULL, NULL);
    mt_cmd(h, "loadfile", b, "append", NULL);

    int hooks = 0, loaded = 0, held = 0;
    double t0 = mt_now(), t_after = 0;
    while (mt_now() - t0 < 60) {
        mpv_event *e = mpv_wait_event(h, 0.1);
        if (e->event_id == MPV_EVENT_SHUTDOWN)
            break;
        if (e->event_id == MPV_EVENT_FILE_LOADED) {
            loaded++;
            if (loaded == 1 && strcmp(mode, "dump") == 0) {
                // Async: with end=no the command completes only when the
                // dump stops, and a sync call would block this client.
                const char *dc[] = {"dump-cache", "0", "no", rec, NULL};
                int r = mpv_command_async(h, 1, dc);
                mt_check(r >= 0, "dump-cache started on a");
            }
            if (loaded == 1 && strcmp(mode, "resume") == 0) {
                mt_cmd(h, "write-watch-later-config", NULL, NULL, NULL);
                // The config of a plus the redirects of its parent dirs.
                int n = mt_count_files(argv[3]);
                mt_check(n >= 1, "watch-later files of a written (%d)", n);
            }
            if (loaded == 2 && strcmp(mode, "props") == 0) {
                double d = -1;
                mt_double(h, "duration", &d);
                mt_check(d > 29 && d < 31, "after the transition c plays (duration %.2f)", d);
                mt_check(mt_str_is(h, "prefetch-state", "used"),
                         "the transition used the prefetched c");
                break;
            }
        }
        if (e->event_id == MPV_EVENT_HOOK) {
            mpv_event_hook *hk = e->data;
            hooks++;
            char *sof = mt_str(h, "stream-open-filename");
            printf("hook %s #%d sof=%s\n", hk->name, hooks, sof ? sof : "?");
            int is_b = sof && strcmp(sof, b) == 0;
            mpv_free(sof);
            if (hooks == 2 && is_b) {
                held = 1;
                double t = mt_now();
                if (strcmp(mode, "dump") == 0) {
                    while (mt_now() - t < 1.0)
                        mt_sleep_ms(100);
                    mt_check(1, "core alive after 1 s of hold with dump-cache open");
                } else if (strcmp(mode, "props") == 0) {
                    mt_sleep_ms(300);
                    double tp = -1, d = -1;
                    int r = mt_double(h, "time-pos", &tp);
                    mt_check(r >= 0 && tp >= 0, "time-pos of a available during the hook (%s)",
                             mpv_error_string(r));
                    r = mt_double(h, "duration", &d);
                    mt_check(r >= 0 && d > 59 && d < 61, "duration is a's during the hook (%.2f, %s)",
                             d, mpv_error_string(r));
                    mt_check(mt_str_is(h, "seekable", "yes"), "seekable is a's during the hook");
                    mt_check(mt_str_is(h, "metadata/by-key/title", "Track A"),
                             "metadata is a's during the hook");
                    mt_check(mt_str_is(h, "media-title", "Track A"),
                             "media-title is a's during the hook");
                    mt_check(mt_str_is(h, "path", b), "path is b's (the entry being loaded)");
                    mt_check(mt_str_is(h, "filename", "b.flac"), "filename is b's");
                    r = mpv_set_property_string(h, "stream-open-filename", c);
                    mt_check(r >= 0, "the hook rewrites stream-open-filename (%s)",
                             mpv_error_string(r));
                    mt_check(mt_str_is(h, "stream-open-filename", c),
                             "stream-open-filename reads back the rewrite");
                } else if (strcmp(mode, "title") == 0) {
                    mt_check(mt_str_is(h, "media-title", "a_notag.flac"),
                             "media-title is a's file name during the hook");
                    mt_check(mt_str_is(h, "filename", "b.flac"), "filename is b's");
                } else if (strcmp(mode, "clear") == 0) {
                    int r = mt_cmd(h, "playlist-clear", NULL, NULL, NULL);
                    mt_check(r >= 0, "playlist-clear during the hook");
                } else if (strcmp(mode, "tracks") == 0) {
                    int r = mt_cmd(h, "audio-add", c, "select", NULL);
                    mt_check(r >= 0, "audio-add c select during the hook");
                    mt_sleep_ms(300);
                } else if (strcmp(mode, "resume") == 0) {
                    int r = mt_cmd(h, "delete-watch-later-config", NULL, NULL, NULL);
                    mt_check(r >= 0, "delete-watch-later-config during the hook");
                }
                t_after = mt_now();
            } else if (strcmp(mode, "props") == 0 && is_b && hooks > 2) {
                // b's own on_load at the transition: same rewrite, so the
                // prefetched c is reused.
                mpv_set_property_string(h, "stream-open-filename", c);
            }
            mpv_hook_continue(h, hk->id);
            if (held == 1) {
                held = 2;
                if (strcmp(mode, "props") == 0) {
                    double d = -1;
                    mt_double(h, "duration", &d);
                    char pos[32];
                    snprintf(pos, sizeof pos, "%f", d - 1.5);
                    mt_cmd(h, "seek", pos, "absolute", NULL);
                }
            }
        }
        if (held == 2 && t_after && mt_now() - t_after > 0.5) {
            if (strcmp(mode, "title") == 0)
                break;
            if (strcmp(mode, "clear") == 0) {
                mt_check(mt_str_is(h, "prefetch-state", "idle"),
                         "prefetch skipped after the clear");
                break;
            }
            if (strcmp(mode, "dump") == 0) {
                mt_check(1, "dump-cache survived the prefetch hook");
                break;
            }
            if (strcmp(mode, "tracks") == 0) {
                int64_t id = -1, aid = -1;
                mt_int(h, "current-tracks/audio/id", &id);
                mt_int(h, "aid", &aid);
                mt_check(id == 2, "the playing track is c (current-tracks/audio/id %lld, aid %lld)",
                         (long long)id, (long long)aid);
                break;
            }
            if (strcmp(mode, "resume") == 0) {
                int n = mt_count_files(argv[3]);
                mt_check(n == 0, "watch-later files of a deleted (%d left)", n);
                break;
            }
        }
    }
    mt_check(held, "the prefetch on_load hook of b was seen");
    mpv_terminate_destroy(h);
    return mt_result();
}
