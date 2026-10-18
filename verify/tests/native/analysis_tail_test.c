// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// analysis_tail_test <mode> <fixtures> <tmpdir>: an HTTP file whose duration
// is estimated past its real end (F66, the overestimate). over.aac (ADTS
// AAC, 40 s) estimates about 1459 s from the bitrate of its silent start.
// It comes from slow_http.py at 2000000 bytes a second (run.sh), with the
// cache on: the cache feed decodes it from the start to the end of file.
//   over     waveform and loudness on: both ready, the noise drawn, and no
//            GET after the player's own (r17 counts the pass as cut, 1 s
//            short of the estimate, and downloads the file again for the
//            same result).
//   overcut  the same, with the player's download cut at byte 400000 of
//            838095 (run.sh tells slow_http.py): the pass ends far from
//            the end of the file, so the re-open still takes over and both
//            results are ready.
#include "analysis_test.h"

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s over|overcut <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    char url[256];
    snprintf(url, sizeof url, "http://127.0.0.1:%s/over.aac",
             getenv("HTTP_PORT") ? getenv("HTTP_PORT") : "0");
    mpv_handle *h = an_create();
    mpv_initialize(h);
    an_flag(h, "waveform-enabled", 1);
    an_flag(h, "loudness-scan-enabled", 1);
    mpv_set_property_string(h, "pause", "yes");
    mt_cmd(h, "loadfile", url, NULL, NULL);
    mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "file loaded");
    struct an_wave w;
    struct an_loud l;
    an_wait_final(h, 1, 1, 40, &w, &l);
    double dur = -1;
    mt_double(h, "duration", &dur);
    int loud_bins = 0;
    uint32_t sum = 0;   // compare with the re-open's (r17) envelope
    for (int i = 0; w.max && i < w.bins; i++) {
        uint32_t lo, hi;
        memcpy(&lo, &w.min[i], 4);
        memcpy(&hi, &w.max[i], 4);
        sum = sum * 31 + lo * 7 + hi + w.fill[i];
        loud_bins += w.fill[i] && w.max[i] - w.min[i] > 0.05f;
    }
    printf("     mpv duration %.2f s, waveform %d bins of %lld, %d loud, sum %08x, "
           "loudness %.4f\n", dur, w.bins, (long long)w.total_bins, loud_bins,
           sum, l.integrated);
    mt_check(!strcmp(w.state, "ready") && !strcmp(l.state, "ready"),
             "both ready (%s, %s)", w.state, l.state);
    mt_check(loud_bins > 0, "the noise is drawn (%d bins)", loud_bins);
    mt_check(l.integrated > -30 && l.integrated < -10, "loudness plausible (%.2f)",
             l.integrated);

    // The server's log: one line per GET. Each open of the file (lavf's aac
    // demuxer) reads from the start three times, around two reads of the
    // tail for the ID3v1 and APE tags: the player's open, and with a
    // re-open the probe's and the worker's too.
    char path[1100], line[256];
    snprintf(path, sizeof path, "%s.http.log", argv[3]);
    FILE *f = fopen(path, "r");
    int from0 = 0;
    while (f && fgets(line, sizeof line, f)) {
        printf("     server: %s", line);
        from0 += strstr(line, "range=0-") != NULL;
    }
    if (f)
        fclose(f);
    if (!strcmp(argv[1], "overcut"))
        mt_check(from0 > 3, "the re-open downloads the file (%d GETs from the start)",
                 from0);
    else
        mt_check(from0 <= 3, "no second download (%d GETs from the start)", from0);
    an_wave_free(&w);
    mpv_terminate_destroy(h);
    return mt_result();
}
