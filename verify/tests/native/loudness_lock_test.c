// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// loudness_lock_test: white-box test of audio/mak_loudness.c (F75), which
// run.sh builds from the patched tree with the stubs below. A coordinator
// thread of generation 1 marks the loudness failed exactly while the core
// starts generation 2 and marks it scanning. The test lock sleeps 100 ms
// before taking the mutex on that thread only, which holds it between its
// generation check and the write: on r17 the check is outside the lock, so
// the stale FAILED lands on top of the new generation's SCANNING. Fixed, the
// check is under the lock and the stale write is dropped.
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

#include "osdep/threads.h"

static _Thread_local int an_slow_lock;

static int an_lock(pthread_mutex_t *m)
{
    if (an_slow_lock)
        usleep(100 * 1000);
    return pthread_mutex_lock(m);
}

#undef mp_mutex_lock
#define mp_mutex_lock(m) an_lock(m)

#include "audio/mak_loudness.c"

// The waveform product's generation, stubbed.
static atomic_int an_gen;
int mak_waveform_current_gen(void) { return atomic_load(&an_gen); }
double mak_waveform_decode_fraction(void) { return 0; }

static void *stale_failed(void *p)
{
    (void)p;
    an_slow_lock = 1;
    mak_loudness_mark_failed(1);   // the coordinator of generation 1 fails
    return NULL;
}

int main(void)
{
    int fails = 0;
    for (int round = 0; round < 3; round++) {
        atomic_store(&an_gen, 1);
        mak_loudness_set_enabled(true);
        mak_loudness_mark_scanning(1);
        pthread_t t;
        pthread_create(&t, NULL, stale_failed, NULL);
        usleep(30 * 1000);              // the old thread is in its lock
        atomic_fetch_add(&an_gen, 1);   // core: begin_generation (2)
        mak_loudness_mark_scanning(2);  // core: mark_scanning (2)
        pthread_join(t, NULL);
        bool scanning = mak_loudness_is_scanning();
        printf("%s round %d: generation 2 %s\n", scanning ? "ok  " : "FAIL",
               round, scanning ? "still scanning" : "lost to the stale failed");
        fails += !scanning;
    }
    printf(fails ? "RESULT FAIL (%d)\n" : "RESULT PASS\n", fails);
    return fails ? 1 : 0;
}
