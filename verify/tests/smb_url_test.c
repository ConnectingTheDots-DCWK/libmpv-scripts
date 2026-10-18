// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The URL handling of patches/ffmpeg/libsmb2.c (F85, F86), built by
// network_test.sh. It includes that file (LIBSMB2_C) inside an FFmpeg tree
// configured with libsmb2, and links libsmb2 for smb2_parse_url. When the
// file still has the r17 signatures, network_test.sh passes OLD_STRIP and
// OLD_DECODE, so the same cases also run, and fail, on the old code.
//   strip:  strip_password_from_url, clean URL and password (F85).
//   decode: percent_decode, and a %00 in the password (F86).
//   parse:  what libsmb2_connect hands to libsmb2: strip, scheme rewrite,
//           smb2_parse_url, decode of user, domain, share and path.
//
// Usage: smb_url_test strip|decode|parse...
#include LIBSMB2_C
#include <stdio.h>
#ifdef OLD_STRIP
static int t_strip(const char *url, char **clean, char **pw)
{
    *clean = strip_password_from_url(url, pw);
    return *clean ? 0 : AVERROR(ENOMEM);
}
#else
static int t_strip(const char *url, char **clean, char **pw)
{
    return strip_password_from_url(url, clean, pw);
}
#endif
#ifdef OLD_DECODE
static int t_decode(char *s) { percent_decode(s); return 0; }
#else
static int t_decode(char *s) { return percent_decode(s); }
#endif

static int fails, runs;
static int same(const char *a, const char *b)
{
    return (!a && !b) || (a && b && !strcmp(a, b));
}
static void check(int ok, const char *group, const char *in, const char *what,
                  const char *got, const char *want)
{
    runs++;
    if (ok)
        return;
    fails++;
    printf("FAIL %-6s %-40s %s: got %s%s%s, want %s%s%s\n", group, in, what,
           got ? "\"" : "", got ? got : "NULL", got ? "\"" : "",
           want ? "\"" : "", want ? want : "NULL", want ? "\"" : "");
}

static const struct { const char *in, *clean, *pw; } strip_cases[] = {
    // an '@' or ':' after the authority is not userinfo (cases 1-3 of F85)
    { "smb2://host:445/share/a@b.flac",      "smb2://host:445/share/a@b.flac",      NULL },
    { "smb2://host:1445/share/dir@x/a.flac", "smb2://host:1445/share/dir@x/a.flac", NULL },
    { "smb2://[fe80::1]/share/a@b.flac",     "smb2://[fe80::1]/share/a@b.flac",     NULL },
    { "smb2://nas/m/Live:x@y.flac",          "smb2://nas/m/Live:x@y.flac",          NULL },
    { "smb2://h?x=u:p@q",                    "smb2://h?x=u:p@q",                    NULL },
    // the first ':' of the userinfo starts the password, ';' after it is password
    { "smb2://user:pa;ss@nas/m/a.flac",      "smb2://user@nas/m/a.flac",            "pa;ss" },
    // the last '@' of the authority ends the userinfo
    { "smb2://u:p@ss@h/s/f",                 "smb2://u@h/s/f",                      "p@ss" },
    // what works today keeps working
    { "smb2://d;u:p%40w@h:445/s/a@b.flac",   "smb2://d;u@h:445/s/a@b.flac",         "p@w" },
    { "smb2://dom;u:pw@h/s/f",               "smb2://dom;u@h/s/f",                  "pw" },
    { "smb2://u:p@h/s/a:b@c",                "smb2://u@h/s/a:b@c",                  "p" },
    { "smb2://u:p%40x@h:1445/s/d@x/f",       "smb2://u@h:1445/s/d@x/f",             "p@x" },
    { "smb2://u:p@[fe80::1]:445/s/f",        "smb2://u@[fe80::1]:445/s/f",          "p" },
    { "smb2://u:p@h/s/f?sec=ntlmssp",        "smb2://u@h/s/f?sec=ntlmssp",          "p" },
    { "smb2://u:pw@h/s/f",                   "smb2://u@h/s/f",                      "pw" },
    { "smb2://u:@h/s/f",                     "smb2://u@h/s/f",                      "" },
    { "smb2://u@h/s/f",                      "smb2://u@h/s/f",                      NULL },
    { "smb2://h/s/f",                        "smb2://h/s/f",                        NULL },
    { "no-scheme",                           "no-scheme",                           NULL },
};

static void group_strip(void)
{
    for (size_t i = 0; i < FF_ARRAY_ELEMS(strip_cases); i++) {
        char *clean = NULL, *pw = NULL;
        int r = t_strip(strip_cases[i].in, &clean, &pw);
        check(r == 0, "strip", strip_cases[i].in, "return", r ? "error" : "0", "0");
        check(same(clean, strip_cases[i].clean), "strip", strip_cases[i].in, "url", clean, strip_cases[i].clean);
        check(same(pw, strip_cases[i].pw), "strip", strip_cases[i].in, "password", pw, strip_cases[i].pw);
        av_free(clean);
        av_free(pw);
    }
}

static const struct { const char *in, *out; } decode_cases[] = {
    { "a%20b", "a b" }, { "%41", "A" }, { "caf%C3%A9", "caf\xc3\xa9" },
    { "%e2%82%ac", "\xe2\x82\xac" },
    // an escape that is not two hex digits is kept, like ff_urldecode
    { "100% Pure", "100% Pure" }, { "x%zz", "x%zz" }, { "%4g", "%4g" },
    { "a%2", "a%2" }, { "100%", "100%" }, { "%%41", "%A" }, { "% 41", "% 41" },
    // NULL: refused, a NUL would cut the name short
    { "a%00b", NULL }, { "%00", NULL },
};

static void group_decode(void)
{
    for (size_t i = 0; i < FF_ARRAY_ELEMS(decode_cases); i++) {
        char buf[64];
        snprintf(buf, sizeof buf, "%s", decode_cases[i].in);
        int r = t_decode(buf);
        if (decode_cases[i].out)
            check(r == 0 && !strcmp(buf, decode_cases[i].out), "decode",
                  decode_cases[i].in, "result", r ? "error" : buf, decode_cases[i].out);
        else
            check(r == AVERROR(EINVAL), "decode", decode_cases[i].in, "result",
                  r ? "error" : buf, "EINVAL");
    }
    // the password goes through the same decoding
    char *clean = NULL, *pw = NULL;
    int r = t_strip("smb2://u:p%00w@h/s/f", &clean, &pw);
    check(r == AVERROR(EINVAL), "decode", "smb2://u:p%00w@h/s/f", "strip",
          r ? "error" : pw, "EINVAL");
    av_free(clean);
    av_free(pw);
    clean = pw = NULL;
    r = t_strip("smb2://u:p%zz@h/s/f", &clean, &pw);
    check(r == 0 && same(pw, "p%zz"), "decode", "smb2://u:p%zz@h/s/f", "password",
          r ? "error" : pw, "p%zz");
    av_free(clean);
    av_free(pw);
}

// libsmb2_connect up to smb2_connect_share. Returns 0, or the error the
// open would fail with.
static int connect_args(struct smb2_context *smb2, const char *in,
                        struct smb2_url **out, char **pw)
{
    char *clean = NULL;
    int r = t_strip(in, &clean, pw);
    if (r < 0)
        return r;
    if (!strncmp(clean, "smb2://", 7)) {
        memmove(clean + 4, clean + 5, strlen(clean + 5) + 1);
        memcpy(clean, "smb:", 4);
    }
    *out = smb2_parse_url(smb2, clean);
    av_free(clean);
    if (!*out)
        return AVERROR(EINVAL);
    // the parser's own buffers, decoded in place as libsmb2_connect does
    char *parts[] = { (char *)(*out)->user, (char *)(*out)->domain,
                      (char *)(*out)->share, (char *)(*out)->path };
    for (int i = 0; i < 4; i++)
        if (parts[i] && t_decode(parts[i]) < 0)
            return AVERROR(EINVAL);
    return 0;
}

static const struct { const char *in, *user, *domain, *server, *share, *path, *pw; int err; } parse_cases[] = {
    { "smb2://host:445/share/a@b.flac", NULL, NULL, "host:445", "share", "a@b.flac", NULL },
    { "smb2://host:1445/share/dir@x/a.flac", NULL, NULL, "host:1445", "share", "dir@x/a.flac", NULL },
    { "smb2://[fe80::1]/share/a@b.flac", NULL, NULL, "[fe80::1]", "share", "a@b.flac", NULL },
    { "smb2://user:pa;ss@nas/m/a.flac", "user", NULL, "nas", "m", "a.flac", "pa;ss" },
    { "smb2://d;u:p%40w@h:445/s/a%20b.flac", "u", "d", "h:445", "s", "a b.flac", "p@w" },
    { "smb2://u:p@h:1445/s/d@x/f.wav", "u", NULL, "h:1445", "s", "d@x/f.wav", "p" },
    { "smb2://nas/music/100% Pure.flac", NULL, NULL, "nas", "music", "100% Pure.flac", NULL },
    { "smb2://nas/music/%4g.flac", NULL, NULL, "nas", "music", "%4g.flac", NULL },
    { "smb2://nas/music/a%00b.flac", .err = 1 },
};


static void group_parse(void)
{
    struct smb2_context *smb2 = smb2_init_context();
    for (size_t i = 0; i < FF_ARRAY_ELEMS(parse_cases); i++) {
        struct smb2_url *u = NULL;
        char *pw = NULL;
        const char *in = parse_cases[i].in;
        int r = connect_args(smb2, in, &u, &pw);
        if (parse_cases[i].err) {
            check(r == AVERROR(EINVAL), "parse", in, "open", r ? "error" : u->path, "EINVAL");
        } else if (r < 0) {
            check(0, "parse", in, "open", smb2_get_error(smb2), "success");
        } else {
            check(same(u->user, parse_cases[i].user), "parse", in, "user", u->user, parse_cases[i].user);
            check(same(u->domain, parse_cases[i].domain), "parse", in, "domain", u->domain, parse_cases[i].domain);
            check(same(u->server, parse_cases[i].server), "parse", in, "server", u->server, parse_cases[i].server);
            check(same(u->share, parse_cases[i].share), "parse", in, "share", u->share, parse_cases[i].share);
            check(same(u->path, parse_cases[i].path), "parse", in, "path", u->path, parse_cases[i].path);
            check(same(pw, parse_cases[i].pw), "parse", in, "password", pw, parse_cases[i].pw);
        }
        if (u)
            smb2_destroy_url(u);
        av_free(pw);
    }
    smb2_destroy_context(smb2);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s strip|decode|parse...\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "strip"))
            group_strip();
        else if (!strcmp(argv[i], "decode"))
            group_decode();
        else if (!strcmp(argv[i], "parse"))
            group_parse();
        else
            return 2;
    }
    if (fails)
        printf("RESULT FAIL (%d of %d checks)\n", fails, runs);
    else
        printf("RESULT PASS (%d checks)\n", runs);
    return fails ? 1 : 0;
}
