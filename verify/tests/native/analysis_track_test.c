// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_track_test <mode> <fixtures> <tmpdir>: the analysis decodes the
// audio track the player plays (F67). Waveform and loudness on; track 1 is
// a sine at about -51.8 LUFS, track 2 pink noise at about -20.6 LUFS.
//   mka1      two.mka (mpv's Matroska demuxer), aid=1: about -51.8.
//   mka2      two.mka, aid=2: about -20.6 (r17 measures track 1).
//   m4a2      two.m4a (lavf), aid=2: about -20.6 (r17 measures track 1).
//   ext       a.flac with b.flac as an external track, aid=2: the loudness
//             is unavailable and the waveform grows from playback (r17
//             measures a.flac).
//   http2     two.mka over HTTP with cache=no (the re-open), aid=2.
//   httpseek  two.mka over HTTP with the cache on, aid=2, and a seek past
//             the cache right after the load: the cache feed hands over to
//             the re-open, which must keep track 2.
// run.sh serves the http modes at 1000000 bytes a second.
#include "analysis_test.h"

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s mka1|mka2|m4a2|ext|http2|httpseek <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    int ext = !strcmp(mode, "ext");
    int http = !strncmp(mode, "http", 4);
    int track1 = !strcmp(mode, "mka1");
    char file[1024], opts[2048];
    if (http)
        snprintf(file, sizeof file, "http://127.0.0.1:%s/two.mka",
                 getenv("HTTP_PORT") ? getenv("HTTP_PORT") : "0");
    else if (ext)
        snprintf(file, sizeof file, "%s/a.flac", argv[2]);
    else
        snprintf(file, sizeof file, "%s/%s", argv[2],
                 !strcmp(mode, "m4a2") ? "two.m4a" : "two.mka");
    if (ext)
        snprintf(opts, sizeof opts, "audio-files-append=%s/b.flac,aid=2", argv[2]);
    else if (!strcmp(mode, "http2"))
        snprintf(opts, sizeof opts, "aid=2,cache=no");
    else
        snprintf(opts, sizeof opts, "aid=%d", track1 ? 1 : 2);

    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", 1);
    an_flag(h, "loudness-scan-enabled", 1);
    mpv_set_property_string(h, "pause", "yes");
    const char *l[] = {"loadfile", file, "replace", "-1", opts, NULL};
    if (mpv_command(h, l) < 0)
        printf("     loadfile failed\n");
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "file loaded");
    char *aid = mt_str(h, "current-tracks/audio/id");
    char *isext = mt_str(h, "current-tracks/audio/external");
    printf("     playing audio track %s (external %s)\n", aid ? aid : "?",
           isext ? isext : "?");
    mpv_free(aid);
    mpv_free(isext);
    if (!strcmp(mode, "httpseek"))
        mt_cmd(h, "seek", "25", "absolute", NULL);

    struct an_wave w;
    struct an_loud lo;
    an_wait_final(h, !ext, 1, 60, &w, &lo);
    if (ext) {
        mt_check(!strcmp(lo.state, "unavailable"),
                 "loudness unavailable for the external track (%s, %.2f)",
                 lo.state, lo.integrated);
        mt_check(!strcmp(w.state, "progressive"),
                 "waveform grows from playback (%s)", w.state);
    } else if (track1) {
        mt_check(!strcmp(lo.state, "ready") && lo.integrated < -45 &&
                 lo.integrated > -58, "track 1 measured (%s, %.2f)",
                 lo.state, lo.integrated);
    } else {
        mt_check(!strcmp(lo.state, "ready") && lo.integrated > -25 &&
                 lo.integrated < -16, "track 2 measured (%s, %.2f)",
                 lo.state, lo.integrated);
        mt_check(!strcmp(w.state, "ready"), "waveform ready (%s)", w.state);
    }
    if (http) {
        char path[1100], line[256];
        snprintf(path, sizeof path, "%s.http.log", argv[3]);
        FILE *f = fopen(path, "r");
        while (f && fgets(line, sizeof line, f))
            printf("     server: %s", line);
        if (f)
            fclose(f);
    }
    an_wave_free(&w);
    mpv_terminate_destroy(h);
    return mt_result();
}
