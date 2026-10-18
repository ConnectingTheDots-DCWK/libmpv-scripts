// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_start_test <mode> <fixtures> <tmpdir>: a source whose timestamps
// do not start at zero (F64). The audio is 2 s of silence then 8 s of
// pink noise; mpv plays it from time-pos 0 (rebase-start-time), so the
// waveform must be silent before 2 s and loud after, up to its end, and the
// loudness must match gap.flac, which starts at zero. Waveform and loudness on.
//   ts      gap.ts, AAC in MPEG-TS starting at 1.4 s (one worker). r17 puts
//           the noise 1.4 s late and loses the last 1.4 s.
//   late    gaplate.ts, starting at 3601.4 s. r17 fills no bin and reads
//           -70 LUFS.
//   ogg     gaplate.ogg, Vorbis starting at 100 s (four workers, each seeks).
//           r17 fills no bin.
//   http    gaplate.ts over HTTP (served by run.sh): the cache feed.
#include <math.h>
#include "analysis_test.h"

static void analyze(mpv_handle *h, const char *url, struct an_wave *w,
                    struct an_loud *l)
{
    mt_cmd(h, "loadfile", url, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "%s loaded", url);
    an_wait_final(h, 1, 1, 40, w, l);
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s ts|late|ogg|http <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    char ref[1024], url[1024];
    snprintf(ref, sizeof ref, "%s/gap.flac", argv[2]);
    if (!strcmp(mode, "http"))
        snprintf(url, sizeof url, "http://127.0.0.1:%s/gaplate.ts",
                 getenv("HTTP_PORT") ? getenv("HTTP_PORT") : "0");
    else
        snprintf(url, sizeof url, "%s/%s", argv[2],
                 !strcmp(mode, "ts") ? "gap.ts" :
                 !strcmp(mode, "late") ? "gaplate.ts" : "gaplate.ogg");

    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", 1);
    an_flag(h, "loudness-scan-enabled", 1);
    mpv_set_property_string(h, "pause", "yes");
    struct an_wave rw, w;
    struct an_loud rl, l;
    analyze(h, ref, &rw, &rl);
    analyze(h, url, &w, &l);
    double start = -1;
    mt_double(h, "demuxer-start-time", &start);
    printf("     demuxer start time %.3f s\n", start);

    mt_check(!strcmp(w.state, "ready") && !strcmp(l.state, "ready"),
             "both ready (%s, %s)", w.state, l.state);
    mt_check(fabs(l.integrated - rl.integrated) < 1.0,
             "loudness matches gap.flac (%.2f and %.2f)", l.integrated, rl.integrated);
    mt_check(w.total_bins > 0 && w.filled >= w.total_bins * 95 / 100,
             "the bins are filled to the end (%d of %lld)", w.filled,
             (long long)w.total_bins);
    int loud_early = 0, quiet_late = 0, first_loud = -1;
    for (int i = 0; w.max && i < w.bins; i++) {
        // The peak of the bin: pink noise can stay on one side of zero
        // for a whole 5 ms bin.
        double t = (double)i * w.duration_us / w.total_bins / 1e6;
        float peak = fmaxf(fabsf(w.min[i]), fabsf(w.max[i]));
        int loud = w.fill[i] && peak > 0.02f;
        if (first_loud < 0 && loud)
            first_loud = i;
        if (t < 1.8 && peak > 0.02f)
            loud_early++;
        if (t > 2.2 && t < 9.5 && !loud && quiet_late++ < 6)
            printf("     quiet bin %d at %.3f s: filled %d, min %f max %f\n",
                   i, t, w.fill[i], w.min[i], w.max[i]);
    }
    printf("     first loud bin %d at %.3f s\n", first_loud, first_loud < 0 ? -1.0 :
           (double)first_loud * w.duration_us / w.total_bins / 1e6);
    mt_check(loud_early == 0 && quiet_late == 0,
             "silent before 2 s, loud after (%d loud early, %d quiet late)",
             loud_early, quiet_late);
    an_wave_free(&rw);
    an_wave_free(&w);
    mpv_terminate_destroy(h);
    return mt_result();
}
