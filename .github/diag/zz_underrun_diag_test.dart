// Diagnostic, copied into the package on the runner: where do the audio
// underruns of the null output come from on this host? Each scenario plays
// about 4 s on ao=null with warnings logged and counts mpv's "Audio device
// underrun" lines, and a 5 ms Dart timer measures how long this process
// stalls meanwhile. A plain file has no live input at all: underruns there
// come from the host, not from the PCM source.

@TestOn('mac-os || linux || windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mpv_audio_kit/mpv_audio_kit.dart';
import 'package:test/test.dart';

import '../_helpers/setter_test_helpers.dart';

const _f = PcmFormat(sampleRate: 24000, channels: 1);
final _rounds = int.tryParse(Platform.environment['DIAG_ROUNDS'] ?? '') ?? 8;

Uint8List _tone(int frame0, int ms) {
  final frames = _f.sampleRate * ms ~/ 1000;
  final d = ByteData(frames * _f.bytesPerFrame);
  for (var i = 0; i < frames; i++) {
    final v = 0.3 * math.sin(2 * math.pi * 440 * (frame0 + i) / _f.sampleRate);
    d.setInt16(i * 2, (v * 32767).round(), Endian.little);
  }
  return d.buffer.asUint8List();
}

/// Largest gap between ticks of a 5 ms periodic timer, minus the period.
final class _Stall {
  final _sw = Stopwatch();
  Timer? _t;
  int _last = 0;
  int maxMs = 0;
  void start() {
    _sw.start();
    _t = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final now = _sw.elapsedMilliseconds;
      maxMs = math.max(maxMs, now - _last - 5);
      _last = now;
    });
  }

  void stop() => _t?.cancel();
}

Future<Map<String, Object?>> _run(String scenario) async {
  final player = await buildPlayer(
    configuration: const PlayerConfiguration(), // warnings and up
  );
  var underruns = 0;
  final sub = player.stream.log.listen((l) {
    if (l.text.contains('Audio device underrun')) underruns++;
  });
  final done = player.stream.completed.firstWhere((c) => c);
  final stall = _Stall()..start();
  final sw = Stopwatch()..start();
  var audioMs = 4000;
  switch (scenario) {
    case 'file':
      audioMs = 5000;
      await player.open(
        Media('${Directory.current.path}/test/fixtures/sine_5s.flac'),
        play: true,
      );
    case 'pcm-prefilled':
      final s = await player.openPcmStream(_f);
      s.add(_tone(0, 4000));
      await s.close();
    case 'pcm-realtime':
    case 'pcm-jitter':
      final s = await player.openPcmStream(_f);
      final rnd = math.Random(27);
      final start = DateTime.now();
      var sent = 0;
      var chunks = 0;
      while (sent < 4000) {
        var wait = start
            .add(Duration(milliseconds: sent))
            .difference(DateTime.now());
        if (scenario == 'pcm-jitter') {
          wait += Duration(milliseconds: rnd.nextInt(40));
          if (chunks % 10 == 9) wait += const Duration(milliseconds: 80);
        }
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        s.add(_tone(sent * 24, 20));
        sent += 20;
        chunks++;
      }
      await s.close();
  }
  await done.timeout(const Duration(seconds: 20));
  final wallMs = sw.elapsedMilliseconds;
  stall.stop();
  await sub.cancel();
  await player.dispose();
  return {
    'scenario': scenario,
    'underruns': underruns,
    'wallMs': wallMs,
    'audioMs': audioMs,
    'maxDartStallMs': stall.maxMs,
  };
}

void main() {
  runtimeSuite(() {
    test('underrun diagnostic', () async {
      final rows = <Map<String, Object?>>[];
      for (var i = 0; i < _rounds; i++) {
        for (final s in [
          'file',
          'pcm-prefilled',
          'pcm-realtime',
          'pcm-jitter',
        ]) {
          final r = await _run(s);
          rows.add(r);
          // ignore: avoid_print
          print('DIAG $r');
        }
      }
      for (final s in ['file', 'pcm-prefilled', 'pcm-realtime', 'pcm-jitter']) {
        final mine = rows.where((r) => r['scenario'] == s).toList();
        final withUnderrun = mine
            .where((r) => (r['underruns']! as int) > 0)
            .length;
        final total = mine.fold<int>(0, (a, r) => a + (r['underruns']! as int));
        final stalls = mine.map((r) => r['maxDartStallMs']! as int).toList()
          ..sort();
        // ignore: avoid_print
        print(
          'DIAG SUMMARY $s: rounds with underruns $withUnderrun/${mine.length}, '
          'underruns $total, max Dart stall ${stalls.last} ms',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 15)));
  });
}
