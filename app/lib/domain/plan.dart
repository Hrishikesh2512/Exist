// Mirror of backend/src/domain/plan.ts. The teacher phone computes the same check windows
// as the server, so it can run a class with no internet.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../protocol/protocol.dart' show Phase;

const minuteMs = 60000;

class Policy {
  final int startWindowMin, midWindowMin, endWindowMin, earlyEndWindowMin, midMarginMin, midEveryMin;
  final int teacherEarlyStartMin, minSessionMin, startAfterQuorumMin, zeroPassMinRoster;

  /// Fixed number of MID checks chosen by the teacher (0–3); null = by class length.
  final int? midChecks;
  final double quorumShare;
  const Policy({
    this.midChecks,
    this.startAfterQuorumMin = 5,
    this.zeroPassMinRoster = 5,
    this.quorumShare = 0.25,
    this.startWindowMin = 10,
    this.midWindowMin = 2,
    this.endWindowMin = 10,
    this.earlyEndWindowMin = 3,
    this.midMarginMin = 15,
    this.midEveryMin = 50,
    this.teacherEarlyStartMin = 10,
    this.minSessionMin = 20,
  });

  factory Policy.fromJson(Map<String, dynamic> j) {
    const d = Policy();
    int v(String k, int def) => (j[k] as num?)?.toInt() ?? def;
    return Policy(
      startWindowMin: v('startWindowMin', d.startWindowMin),
      midWindowMin: v('midWindowMin', d.midWindowMin),
      endWindowMin: v('endWindowMin', d.endWindowMin),
      earlyEndWindowMin: v('earlyEndWindowMin', d.earlyEndWindowMin),
      midMarginMin: v('midMarginMin', d.midMarginMin),
      midEveryMin: v('midEveryMin', d.midEveryMin),
      teacherEarlyStartMin: v('teacherEarlyStartMin', d.teacherEarlyStartMin),
      minSessionMin: v('minSessionMin', d.minSessionMin),
      startAfterQuorumMin: v('startAfterQuorumMin', d.startAfterQuorumMin),
      zeroPassMinRoster: v('zeroPassMinRoster', d.zeroPassMinRoster),
      quorumShare: (j['quorumShare'] as num?)?.toDouble() ?? d.quorumShare,
      midChecks: (j['midChecks'] as num?)?.toInt(),
    );
  }

  /// Apply a teacher's per-class settings (already clamped by the server).
  Policy withPlan(Map<String, dynamic> plan) => Policy(
    startWindowMin: (plan['startWindowMin'] as num?)?.toInt() ?? startWindowMin,
    endWindowMin: (plan['endWindowMin'] as num?)?.toInt() ?? endWindowMin,
    midChecks: plan.containsKey('midChecks') ? (plan['midChecks'] as num?)?.toInt() : midChecks,
    midWindowMin: midWindowMin,
    earlyEndWindowMin: earlyEndWindowMin,
    midMarginMin: midMarginMin,
    midEveryMin: midEveryMin,
    teacherEarlyStartMin: teacherEarlyStartMin,
    minSessionMin: minSessionMin,
    startAfterQuorumMin: startAfterQuorumMin,
    zeroPassMinRoster: zeroPassMinRoster,
    quorumShare: quorumShare,
  );
}

enum CheckKind { start, mid, end }

class CheckWindow {
  String get id => '${kind.name.toUpperCase()}$index';
  final CheckKind kind;
  final int index, from, to;
  const CheckWindow(this.kind, this.index, this.from, this.to);
  bool contains(int t) => t >= from && t < to;

  Map<String, dynamic> toJson() => {'kind': kind.name.toUpperCase(), 'index': index, 'from': from, 'to': to};
}

class SessionTimes {
  final int scheduledStart, scheduledEnd, actualStart, plannedEnd;
  final int? actualEnd;
  const SessionTimes({
    required this.scheduledStart,
    required this.scheduledEnd,
    required this.actualStart,
    required this.plannedEnd,
    this.actualEnd,
  });
}

double _midFraction(List<int> secret, int i) {
  final mac = Hmac(sha256, secret).convert([...'EXST-MID'.codeUnits, i]);
  return ByteData.sublistView(Uint8List.fromList(mac.bytes)).getUint32(0) / 4294967296.0;
}

CheckWindow endWindow(SessionTimes t, Policy p) {
  final endedEarly = t.actualEnd != null && t.actualEnd! < t.plannedEnd - p.endWindowMin * minuteMs;
  if (endedEarly) return CheckWindow(CheckKind.end, 0, t.actualEnd!, t.actualEnd! + p.earlyEndWindowMin * minuteMs);
  return CheckWindow(CheckKind.end, 0, t.plannedEnd - p.endWindowMin * minuteMs, t.plannedEnd);
}

List<CheckWindow> planChecks(List<int> secret, SessionTimes t, Policy p) {
  final start = CheckWindow(
    CheckKind.start,
    0,
    t.actualStart,
    math.max(t.actualStart, t.scheduledStart) + p.startWindowMin * minuteMs,
  );
  var end = endWindow(t, p);

  final rangeFrom = math.max(start.to, t.actualStart + p.midMarginMin * minuteMs);
  final rangeTo = t.scheduledEnd - p.endWindowMin * minuteMs - p.midMarginMin * minuteMs;
  final midLen = p.midWindowMin * minuteMs;
  final wanted = p.midChecks ?? math.max(1, (t.scheduledEnd - t.scheduledStart) ~/ (p.midEveryMin * minuteMs));
  final n = rangeTo > rangeFrom ? math.min(wanted, (rangeTo - rangeFrom) ~/ (3 * midLen)) : 0;

  final mids = <CheckWindow>[];
  final seg = n > 0 ? (rangeTo - rangeFrom) / n : 0.0;
  for (var i = 0; i < n; i++) {
    final from = (rangeFrom + i * seg + _midFraction(secret, i) * (seg - midLen)).floor();
    if (from + midLen > end.from) continue;
    mids.add(CheckWindow(CheckKind.mid, i, from, from + midLen));
  }
  if (end.from < start.to) end = CheckWindow(CheckKind.end, 0, math.min(start.to, end.to), end.to);
  return [start, ...mids, end];
}

const surpriseIndex = 100;

/// Add teacher-triggered surprise checks (MID windows) in time order. Mirrors backend withExtraChecks.
List<CheckWindow> withExtraChecks(List<CheckWindow> windows, List<List<int>> extra) {
  if (extra.isEmpty) return windows;
  final mids = [
    ...windows.sublist(1, windows.length - 1),
    for (var i = 0; i < extra.length; i++) CheckWindow(CheckKind.mid, surpriseIndex + i, extra[i][0], extra[i][1]),
  ]..sort((a, b) => a.from.compareTo(b.from));
  return [windows.first, ...mids, windows.last];
}

/// What the teacher phone advertises right now.
({Phase phase, int index}) currentPhase(List<CheckWindow> windows, int now) {
  for (final w in windows) {
    if (w.kind != CheckKind.start && w.contains(now)) {
      return (phase: w.kind == CheckKind.mid ? Phase.mid : Phase.end, index: w.index);
    }
  }
  return (phase: Phase.arrive, index: 0);
}

bool startAllowed(int scheduledStart, int scheduledEnd, int now, Policy p) =>
    now >= scheduledStart - p.teacherEarlyStartMin * minuteMs && now <= scheduledEnd - p.minSessionMin * minuteMs;

/// Mirror of backend classView(): START follows the class's actual arrival, and a
/// check nobody passed does not count.
({List<CheckWindow> windows, Set<String> empty}) classView(
  List<CheckWindow> windows,
  List<List<int>> timesByStudent,
  int rosterSize,
  Policy p,
) {
  if (windows.isEmpty) return (windows: windows, empty: <String>{});
  final firsts = [
    for (final t in timesByStudent)
      if (t.isNotEmpty) t.reduce(math.min),
  ]..sort();
  final quorumN = math.max(1, (rosterSize * p.quorumShare).ceil());
  final adjusted = [...windows];
  final start = adjusted.first, end = adjusted.last;
  if (firsts.length >= quorumN) {
    final close = firsts[quorumN - 1] + p.startAfterQuorumMin * minuteMs;
    adjusted[0] = CheckWindow(start.kind, start.index, start.from, math.min(math.max(start.to, close), end.from));
  }
  final empty = <String>{};
  if (rosterSize >= p.zeroPassMinRoster) {
    for (final w in adjusted.skip(1)) {
      if (!timesByStudent.any((ts) => ts.any(w.contains))) empty.add(w.id);
    }
  }
  return (windows: adjusted, empty: empty);
}
