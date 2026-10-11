## [0.2.0] - unreleased

### Breaking
- On Linux and Android the library's SONAME is `libmpv_audio_kit.so`, so it no longer clashes with another plugin's libmpv. The release asset names are unchanged.
- The per-filter tap is keyed on chain labels instead of filter types: `analyzer-taps` and `audio-tap-frames` take and return labels, and two instances of one filter get separate rings.
- The Checksums, libs and Clean actions are gone, since mpv_audio_kit 0.5.0 takes libmpv through its build hook. The new Manifest action writes `manifest.json`.

### Fixed
- Removing or rebuilding a filter that holds the end of the file, such as `rubberband` in the last few hundred milliseconds, no longer stops playback there for good: mpv re-seeks to decode the end again (`patch_chain_eof.py`).
- A new audio filter whose first input is the end of the stream, as during the refresh seek of `patch_chain_eof.py`, passes it on and waits for data instead of building on a dummy float format. A filter that takes no float, such as `hdcd`, was disabled for good (`patch_lavfi_eof_passthrough.py`).
- PipeWire and PulseAudio stay loaded until the process exits: the stubs unloaded them from an exit handler, under the audio thread of an app that exits without destroying the player.
- The loudness scan of a Matroska file no longer reads -70 LUFS with no gated block: it placed each frame at its timestamp, rounded to 1 ms, so no 100 ms block was complete. It now counts samples from the first frame, as the waveform does, and the waveform of an MP3 no longer ends one encoder delay short.
- The analysis of a local file gives the result of one decode of it. The parallel workers seeked to their region with no pre-roll and placed it by its timestamp, so loudness and peaks drifted at each boundary (WebM -21.78 against -21.74 LUFS, an MP3 peak of 0.101 against 0.084). Each worker now decodes half a second before its region, formats whose seek is not sample exact use one worker, and every fixture gives the bins and loudness of one decode.
- The loudness scan of an MP2 file no longer crashes the process or reads garbage peaks: it converted the decoded samples as the probe's sample format, float, while the decoder outputs 16 bit.

### Changed
- The waveform and loudness scan of an HTTP file that plays from its start decode it from mpv's demuxer cache instead of opening it again, so the file is downloaded once (mpv_audio_kit [#22](https://github.com/ales-drnz/mpv_audio_kit/issues/22)). When one pass from the start to the end is not possible (playback starting further in, a seek the cache cannot serve, an audio track switch, a cut download, the cache off or on disk, a file larger than the cache or a read-ahead that stops short), the analysis opens the file again as before. Both ways give the same bins.
- Linux builds on Ubuntu 20.04, so the library needs glibc 2.31 instead of 2.38, plus ALSA (`libasound.so.2`). It loads PipeWire and PulseAudio only when they are installed, and skips a PipeWire older than 0.3.57 in favour of PulseAudio, then ALSA.
- Linux builds natively, one architecture per host: the menu greys out the other one, and `./build all` skips what the host cannot build.
- Linux keeps plain RELA relocations: RELR would need glibc 2.36.
- mpv's version string carries the release (`mpv v0.41.0+r16`), and a build writes `manifest.json` with the versions, the compiled filters and the hash of every library.

### Build
- Every source tarball, Windows included, is pinned by SHA-256, and every git source (libplacebo, libsmb2, PipeWire) by the commit of its tag. CI stops on an unpinned source and uploads the line to add.
- A missing git tag stops the build instead of falling back to the default branch.
- CI runs `scripts/verify_binaries.sh` on the nine libraries once they are built, and the verify image can load the foreign Linux arch.
- Verify also checks the SONAME, the absence of `DT_RELR`, the 16 KB alignment of the 64 bit Android libraries, the glibc 2.31 floor and every audio filter, and counts a failing tool as a failure.
- CI loads the Linux x86_64 library in a Debian 11 container without PipeWire and PulseAudio, lists the audio devices and plays a tone, falling through to ALSA and then the null output. The container falls back to archive.debian.org as Debian 11 moves there.
- The Android build stops on `DT_RELR` or on 64 bit libraries not aligned for 16 KB pages.
- The PipeWire and PulseAudio stubs come from Implib.so, vendored in `tools/implib`. They build without asserts, so no build path ends up in the library, and rebuild when `PIPEWIRE_VERSION` changes.

## [0.1.7] - 10-10-2026

### Fixed
- Windows: `playlist-prev-playlist` across two playlist files no longer aborts on the ta canary assertion. It appended a separator to a string that the previous append had moved (`patch_playlist_prev_dos_path.py`).
- Windows: destroying a libmpv core that had read `audio-device-list` no longer crashes the process or corrupts its heap. The device watcher (WASAPI, which is COM) was torn down on the thread destroying the core instead of the core thread that created it (`patch_hotplug_core_thread.py`).
- OpenSSL no longer cleans up from an exit handler, which ran before the analysis drain and freed TLS state under a running scan.
- When an analysis worker fails to start, the ones already running are stopped before the join instead of decoding their whole region.

## [0.1.6] - 24-09-2026

### Fixed
- The bulk analysis re-opens a network source with mpv's own network options (`tls-verify`, `tls-ca-file`, `http-header-fields`, user agent, cookies, proxy), so the waveform and loudness scan no longer skip certificate verification or drop auth headers (mpv_audio_kit [#19](https://github.com/ales-drnz/mpv_audio_kit/issues/19)).
- The bulk waveform downmixes to mono with the same channel average as the progressive path, so peaks stay within `[-1, 1]` instead of reaching about 1.41 on correlated stereo.
- A cancelled analysis worker is joined only once, which could crash the process.
- The detached analysis threads are cancelled and drained before the last core is destroyed or the process exits, so they no longer decode while libav and TLS state are freed under them.

### Added
- `waveform-data` carries a per-bin `rms` array next to `min` and `max`, on the bulk, progressive and rolling paths (mpv_audio_kit [#20](https://github.com/ales-drnz/mpv_audio_kit/issues/20)).
- A GitHub Actions workflow builds every platform, Apple included, on each push to a release branch.

## [0.1.5] - 22-08-2026

### Fixed
- The Android binaries no longer pack their relative relocations as `DT_RELR`, which the Android linker ignores below API 30, leaving every relative pointer unrelocated and crashing libmpv on load (mpv_audio_kit [#16](https://github.com/ales-drnz/mpv_audio_kit/issues/16)). They now use APS2 packing, supported since API 23, which costs about 150 KB on each 64 bit binary.

### Changed
- `mpv_elf_size_ldflags` now takes the packing format as an argument, `android` or `relr`. Linux keeps `relr` and its flags are unchanged; `DT_RELR` stays safe there because glibc emits a `GLIBC_ABI_DT_RELR` version dependency, so an old loader refuses the library instead of crashing.

## [0.1.4] - 18-06-2026

### Changed
- The `timer_resolution` patch now forces mpv's high-resolution-timer policy to `never` (was `perwait`): the Windows libmpv no longer changes the system-wide 1 ms timer resolution at all.

## [0.1.3] - 16-06-2026

### Added
- Offline loudness analysis: a new toggleable `loudness_scan` patch measures whole-file EBU R128 (integrated LUFS, range, sample and true peak) on load (rides `bulk_analysis`, disabled with it).
- Embedded CA root store: a new toggleable `embed_cacert` patch compiles the Mozilla CA bundle into OpenSSL, so HTTPS verification needs no on-device cert file (sandboxed macOS, iOS, Android); `tls-ca-file` still overrides it.
- A Tools action in the build menu to refresh the bundled Mozilla CA list (`update_cacert.sh`).

### Fixed
- Windows UI micro-stutter: a new toggleable `timer_resolution` patch stops mpv pinning the system-wide 1 ms timer at init (it disrupted the compositor's frame pacing). No-op off Windows.

### Changed
- The `bulk_analysis`, `pcm_tap` and `filter_label_tap` patches now ship their C as real `.c` and `.h` files (Python appliers are anchor-only); binaries are byte-identical.

### Build
- Further binary size reduction on every platform: mpv orchestration code and the compression and infrastructure deps (`zlib`, `bzip2`, `xz`, `libxml2`) build at `-Os` and `-Oz` while codec and DSP code stays at `-O2`.

## [0.1.2] - 9-06-2026

### Fixed
- iOS and macOS `libmpv.framework` was signed with the wrong identifier which blocked physical-iPhone installs; the build scripts now sign with `--identifier`.

### Added
- `verify_binaries.sh` Layer 15: asserts each xcframework slice's code-signing identifier matches its `CFBundleIdentifier`.

## [0.1.1] - 9-06-2026

### Changed
- Audio-filter whitelist corrected (86 → 87): removed `headphone`, added `aintegral` and `asetrate`.
- The four size-reduction patches are now toggleable from Settings ▸ Patches, all default-on.

### Build
- Audio-only `libmpv` binaries are **~50–65% smaller** at full feature parity; the `mpv_*` API is unchanged.
- `verify_binaries.sh` gained a macOS `dlopen` test, an adaptive feature-presence layer, and per-slice validation.

## [0.1.0] - 05-06-2026

### Added
- Initial release of the build kit that compiles an audio-only `libmpv` for macOS, iOS, Linux, Windows and Android.
- A terminal menu (`./build`) to pick what to build and watch live progress.
- Verify, to audit every produced binary.
- Checksums, to install the binaries into the `mpv_audio_kit` package.
- A `local` and `remote` switch to choose whether `mpv_audio_kit` uses the local libs or downloads them from GitHub Releases.
- Settings to pick which audio decoders and filters are included, and a Dependencies list of the bundled libraries.
- A multi-stage Docker setup with one image per platform, and a Docker tab to build, size and delete them, so you only keep the toolchains you actually use.
