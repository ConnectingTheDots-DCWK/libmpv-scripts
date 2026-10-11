
/* MAK_WAVEFORM_PATCH ─── attach the bulk analysis packet feed (see
 * demux/mak_demux_feed.h). Replays the cached packets of [sh] in the range
 * the demuxer is filling, then leaves the feed on the demuxer so
 * add_packet_locked() queues every new one. */

/* The most cached packets the attach replays. The replay holds the demuxer
 * lock on the core thread, about half a microsecond a packet on a desktop
 * (70 ms for the 138,000 packets of an hour of MP3), and playback is not
 * fed meanwhile. This keeps it near 15 ms there; a longer cache, which only
 * the analysis enabled late in a long file meets, re-opens instead. */
#define MAK_FEED_MAX_REPLAY 32768

struct mak_demux_feed *mak_demux_feed_attach(struct demuxer *demuxer,
                                             struct sh_stream *sh)
{
    struct demux_internal *in = demuxer->in;
    if (!sh || !sh->ds || sh->ds->in != in)
        return NULL;   /* no stream, or one of another demuxer (external) */
    struct demux_stream *ds = sh->ds;

    mp_mutex_lock(&in->lock);
    /* Only where the feed can cover the whole file: a seekable cache in
     * memory (a disk cache would be read back here under the lock), a file
     * the forward cache can hold (beyond it the demuxer only reads at the
     * playback pace), and a plain demuxer (a timeline's packets carry their
     * own codec and segment bounds). A size the stream does not report
     * passes here: read_packet() cuts the feed if the cache fills up before
     * the end. The packet overhead the cache counts can still fill it short
     * of the end of a file of known size close to the limit: the rest then
     * comes at the pace playback frees the cache, which still ends in one
     * clean pass. */
    bool usable = in->seekable_cache && ds->selected &&
                  !in->d_user->opts->disk_cache &&
                  in->d_thread->desc != &demuxer_desc_timeline &&
                  (in->stream_size <= 0 ||
                   (uint64_t)in->stream_size <= (uint64_t)in->max_bytes);
    /* The range the demuxer is filling must start the file, or be about to
     * read it: right after the open, the first read marks the queue as the
     * start (after_seek_to_start) only when it happens. Another cached range
     * that starts the file ends where a seek left it, so the pass could not
     * go on from it. */
    struct demux_queue *q = ds->queue;
    bool has_bof = usable && q && q->range == in->current_range &&
                   (q->is_bof || (!q->head && in->after_seek_to_start)) &&
                   !(q->is_eof && !q->head);
    size_t cached = 0;
    for (struct demux_packet *dp = has_bof ? q->head : NULL; dp; dp = dp->next) {
        if (++cached > MAK_FEED_MAX_REPLAY) {
            has_bof = false;
            break;
        }
    }
    if (!has_bof) {
        mp_mutex_unlock(&in->lock);
        return NULL;
    }
    if (in->mak_feed) {
        mak_demux_feed_owner_release(in->mak_feed);
        in->mak_feed = NULL;
    }
    struct mak_demux_feed *f = mak_demux_feed_new(ds->index);
    if (!f) {
        mp_mutex_unlock(&in->lock);
        return NULL;
    }

    for (struct demux_packet *dp = q->head; dp; dp = dp->next) {
        mak_demux_feed_push_replay(f, read_packet_from_cache(in, dp), q,
                                   q->is_bof && dp == q->head);
    }
    if (q->is_eof && q->head)
        mak_demux_feed_mark(f, MAK_FEED_EOF);

    in->mak_feed = f;
    mp_mutex_unlock(&in->lock);
    return f;
}
