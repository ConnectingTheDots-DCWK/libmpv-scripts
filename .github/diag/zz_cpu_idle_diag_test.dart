// Diagnostic, not a check: CPU of the process per thread, read from
// /proc/self/task, in a few player states. Linux only. Run in profile mode:
//
//   flutter drive --profile -d linux \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/zz_cpu_idle_diag_test.dart
//
// --dart-define=MAK_DIAG_PHASES=a,b,... picks the phases (default: all).
// Lines start with [cpu_diag]. The current phase is written to
// /tmp/cpu_diag_phase so a script can attach perf to it.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart';

const _span = Duration(seconds: 30);
const _phasesDefine = String.fromEnvironment('MAK_DIAG_PHASES');

typedef _Thread = ({String comm, int ticks, int vcsw, int nvcsw});

Map<int, _Thread> _threads() {
  final out = <int, _Thread>{};
  for (final e in Directory('/proc/self/task').listSync()) {
    final tid = int.tryParse(e.uri.pathSegments.where((s) => s.isNotEmpty).last);
    if (tid == null) continue;
    try {
      final stat = File('${e.path}/stat').readAsStringSync();
      final open = stat.indexOf('('), close = stat.lastIndexOf(')');
      final comm = stat.substring(open + 1, close);
      final f = stat.substring(close + 2).split(' ');
      // f[0] is field 3 (state): utime is field 14, stime field 15.
      final ticks = int.parse(f[11]) + int.parse(f[12]);
      var v = 0, nv = 0;
      for (final l in File('${e.path}/status').readAsLinesSync()) {
        if (l.startsWith('voluntary_ctxt_switches:')) v = int.parse(l.split(RegExp(r'\s+'))[1]);
        if (l.startsWith('nonvoluntary_ctxt_switches:')) nv = int.parse(l.split(RegExp(r'\s+'))[1]);
      }
      out[tid] = (comm: comm, ticks: ticks, vcsw: v, nvcsw: nv);
    } on FileSystemException {
      // The thread ended between the listing and the read.
    }
  }
  return out;
}

final int _clkTck = () {
  final r = Process.runSync('getconf', ['CLK_TCK']);
  return int.tryParse((r.stdout as String).trim()) ?? 100;
}();

Future<void> _measure(String phase, Map<String, Object> report) async {
  File('/tmp/cpu_diag_phase').writeAsStringSync(phase);
  // Settle, then measure.
  await Future<void>.delayed(const Duration(seconds: 3));
  final before = _threads();
  final sw = Stopwatch()..start();
  await Future<void>.delayed(_span);
  final secs = sw.elapsedMicroseconds / 1e6;
  final after = _threads();
  File('/tmp/cpu_diag_phase').writeAsStringSync('$phase-done');
  var total = 0;
  final rows = <(String, int, int, int, int)>[];
  for (final MapEntry(key: tid, value: a) in after.entries) {
    final b = before[tid];
    final dt = a.ticks - (b?.ticks ?? 0);
    final dv = a.vcsw - (b?.vcsw ?? 0);
    final dnv = a.nvcsw - (b?.nvcsw ?? 0);
    total += dt;
    if (dt > 0 || dv > secs) rows.add((a.comm, tid, dt, dv, dnv));
  }
  rows.sort((x, y) => y.$3 != x.$3 ? y.$3 - x.$3 : y.$4 - x.$4);
  final pct = total / _clkTck / secs * 100;
  debugPrint('[cpu_diag] phase=$phase cpu=${pct.toStringAsFixed(2)}% of one core over ${secs.toStringAsFixed(1)} s, ${after.length} threads');
  final threads = <Map<String, Object>>[];
  for (final r in rows.take(25)) {
    final p = r.$3 / _clkTck / secs * 100;
    debugPrint('[cpu_diag]   ${r.$1.padRight(18)} tid=${r.$2} cpu=${p.toStringAsFixed(2)}% vcsw/s=${(r.$4 / secs).toStringAsFixed(1)} nvcsw/s=${(r.$5 / secs).toStringAsFixed(1)}');
    threads.add({'comm': r.$1, 'tid': r.$2, 'cpu_pct': p, 'vcsw_s': r.$4 / secs, 'nvcsw_s': r.$5 / secs});
  }
  report[phase] = {'cpu_pct': pct, 'threads': threads};
}

/// A 60 s 48 kHz stereo s16 sine, written once.
Future<String> _wav() async {
  final path = '${Directory.systemTemp.path}/cpu_diag_sine.wav';
  const rate = 48000, secs = 60, ch = 2;
  final n = rate * secs;
  final data = ByteData(44 + n * ch * 2);
  void s(int o, String t) { for (var i = 0; i < 4; i++) data.setUint8(o + i, t.codeUnitAt(i)); }
  s(0, 'RIFF'); data.setUint32(4, 36 + n * ch * 2, Endian.little); s(8, 'WAVE');
  s(12, 'fmt '); data.setUint32(16, 16, Endian.little); data.setUint16(20, 1, Endian.little);
  data.setUint16(22, ch, Endian.little); data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * ch * 2, Endian.little); data.setUint16(32, ch * 2, Endian.little);
  data.setUint16(34, 16, Endian.little); s(36, 'data'); data.setUint32(40, n * ch * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (math.sin(2 * math.pi * 440 * i / rate) * 9000).round();
    data.setInt16(44 + i * 4, v, Endian.little);
    data.setInt16(46 + i * 4, v, Endian.little);
  }
  await File(path).writeAsBytes(data.buffer.asUint8List());
  return path;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, Object>{};
  final phases = _phasesDefine.isEmpty ? null : _phasesDefine.split(',').toSet();
  bool want(String p) => phases == null || phases.contains(p);

  setUpAll(() {
    MpvAudioKit.ensureInitialized(hotRestartCleanup: false);
  });

  tearDownAll(() {
    binding.reportData = {'cpu_diag': report, 'clk_tck': _clkTck, 'product': kReleaseMode || kProfileMode};
  });

  testWidgets('cpu per thread by player state', (_) async {
    debugPrint('[cpu_diag] mode profile=$kProfileMode release=$kReleaseMode pid=$pid clk_tck=$_clkTck');
    if (want('no_player')) await _measure('no_player', report);

    final path = await _wav();
    final player = Player(configuration: const PlayerConfiguration(logLevel: LogLevel.off));
    try {
      await player.open(Media(path), play: false);
      await player.stream.duration.firstWhere((d) => d > Duration.zero);
      final ao = await player.getRawProperty('current-ao');
      debugPrint('[cpu_diag] current-ao=$ao');

      if (want('paused')) await _measure('paused', report);

      if (want('paused_fft')) {
        final sub = player.stream.fft.listen((_) {});
        await _measure('paused_fft', report);
        await sub.cancel();
      }

      if (want('paused_pcm')) {
        final sub = player.stream.pcm.listen((_) {});
        await _measure('paused_pcm', report);
        await sub.cancel();
      }

      await player.play();
      await player.stream.playing.firstWhere((p) => p);

      if (want('playing')) await _measure('playing', report);

      if (want('playing_fft')) {
        var frames = 0;
        final sub = player.stream.fft.listen((_) => frames++);
        await _measure('playing_fft', report);
        await sub.cancel();
        debugPrint('[cpu_diag] playing_fft frames=$frames');
      }

      await player.pause();
      await player.stream.playing.firstWhere((p) => !p);
      if (want('paused_after_play_fft')) {
        final sub = player.stream.fft.listen((_) {});
        await _measure('paused_after_play_fft', report);
        await sub.cancel();
      }
    } finally {
      await player.dispose();
    }
    if (want('disposed')) await _measure('disposed', report);
  }, timeout: const Timeout(Duration(minutes: 8)));
}
