// Runs a class on the teacher's phone. Works fully offline: everything is kept in an
// outbox and synced whenever there is internet (the server re-verifies it all).
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import '../core/native.dart';
import '../domain/plan.dart';
import '../protocol/protocol.dart';

const _maxExtensionMin = 90;
const _slotToleranceMs = 3 * slotMs;

/// Answers to a student's check-in write (see native teacher.respond).
const _accept = 0, _notInClass = 1, _retry = 2;

class TeacherRunner extends ChangeNotifier {
  final AppState app;
  TeacherRunner(this.app) {
    _outbox = Map<String, dynamic>.from(app.store.read<Map<String, dynamic>>('teacher.outbox') ?? {});
    _outbox.putIfAbsent('sessions', () => <String, dynamic>{});
    _outbox.putIfAbsent('checkins', () => <dynamic>[]);
    _outbox.putIfAbsent('marks', () => <dynamic>[]);
    _sub = Native.events.listen(_onEvent);
    _syncTimer = Timer.periodic(const Duration(seconds: 15), (_) => sync());
  }

  late Map<String, dynamic> _outbox;
  StreamSubscription? _sub;
  Timer? _tick, _syncTimer;

  // Active class
  SessionInfo? session;
  Map<String, dynamic>? rec; // outbox record of the active class
  List<int> _secret = const [];
  List<CheckWindow> windows = [];
  List<RosterEntry> roster = [];
  final Map<String, List<int>> _checkinTimes = {}; // studentId -> receivedAt
  final Set<String> _nonces = {};
  int rejected = 0, notInClass = 0;
  int? _lastSlot;
  String? _lastPhase;
  int? stopAdvertisingAt;
  int _lastRosterRefresh = 0;
  String? error;
  String? syncError;
  int? lastSyncAt;

  bool get running => rec != null;
  int get plannedEnd => rec!['plannedEnd'];
  bool get paused => rec?['paused'] == true;
  int get surpriseChecksUsed => (rec?['extraChecks'] as List? ?? const []).length;
  ({Phase phase, int index}) get phase => currentPhase(windows, app.now());
  int get pendingUploads =>
      (_outbox['checkins'] as List).where((c) => c['synced'] != true).length +
      (_outbox['marks'] as List).where((c) => c['synced'] != true).length +
      (_outbox['sessions'] as Map).values.where((s) => s['dirty'] == true).length;

  Map<String, dynamic> _sessions() => Map<String, dynamic>.from(_outbox['sessions']);
  Future<void> _save() => app.store.write('teacher.outbox', _outbox);
  Policy get _policy => app.policy.withPlan(Map<String, dynamic>.from(rec?['plan'] ?? const {}));
  int get _toggle => rec?['toggle'] ?? 0;

  // ------------------------------------------------------------------ starting

  /// Resume a class if the app was killed while one was running.
  Future<void> resumeIfNeeded() async {
    final key = app.store.read<String>('teacher.active');
    if (key == null || running) return;
    final r = _sessions()[key];
    if (r == null || r['state'] != 'ACTIVE' || r['info'] == null) {
      await app.store.write('teacher.active', null);
      return;
    }
    await _run(SessionInfo(Map<String, dynamic>.from(r['info'])), Map<String, dynamic>.from(r));
  }

  /// Start a timetabled or announced class.
  Future<void> start(SessionInfo s) async {
    if (running) throw StateError('Another class is running');
    final now = app.now();
    if (s.kind == 'TIMETABLE' && !startAllowed(s.scheduledStart, s.scheduledEnd, now, app.policy)) {
      throw StateError(
        now < s.scheduledStart ? 'Too early to start this class' : 'Too late to start; use "Start a class now" instead',
      );
    }
    await _begin(s, now);
  }

  /// Take a class right now for any subject group(s) you teach: no timetable, no internet needed.
  /// Students of those subjects are detected automatically; nobody else can check in.
  Future<SessionInfo> startNow({required List<Subject> subjects, required int minutes, String? title}) async {
    if (running) throw StateError('Another class is running');
    final now = app.now();
    final key = 'adhoc:${_uuid()}';
    final ids = subjects.map((s) => s.id).toList()..sort();
    final s = SessionInfo({
      'key': key,
      'shortId': shortIdForKey(key),
      'kind': 'ADHOC',
      'title': title,
      'label': title ?? subjects.map((x) => x.label).join(' + '),
      'sectionIds': ids,
      'scheduledStart': now,
      'scheduledEnd': now + minutes * minuteMs,
      'state': 'ACTIVE',
      'plan': subjects.first.plan,
      'autoStart': true,
    });
    await _begin(s, now);
    return s;
  }

  Future<void> _begin(SessionInfo s, int now) async {
    final rnd = Random.secure();
    final secret = List<int>.generate(32, (_) => rnd.nextInt(256));
    // Start on the opposite toggle to this subject's previous class, so phones notice a new class
    // even if the previous one just ended.
    final toggles = Map<String, dynamic>.from(app.store.read<Map<String, dynamic>>('teacher.toggles') ?? {});
    final tkey = s.sectionIds.join('+');
    final toggle = 1 - ((toggles[tkey] as int?) ?? 1);
    final r = <String, dynamic>{
      'key': s.key,
      'kind': s.kind,
      'info': s.j,
      'state': 'ACTIVE',
      'secretB64': base64.encode(secret),
      if (s.kind == 'ADHOC') ...{
        'sectionIds': s.sectionIds,
        'title': s.title,
        'scheduledStart': s.scheduledStart,
        'scheduledEnd': s.scheduledEnd,
      },
      'scheduledStartLocal': s.scheduledStart,
      'scheduledEndLocal': s.scheduledEnd,
      'actualStart': now,
      'actualEnd': null,
      'plannedEnd': s.scheduledEnd,
      'activity': [
        [now, now],
      ],
      'plan': s.plan, // the teacher's settings for this subject, fixed for this class
      'extraChecks': <List<int>>[],
      'pauses': <List<int>>[],
      'marks': <String, dynamic>{},
      'toggle': toggle,
      'dirty': true,
    };
    toggles[tkey] = toggle;
    await app.store.write('teacher.toggles', toggles);
    (_outbox['sessions'] as Map)[s.key] = r;
    await app.store.write('teacher.active', s.key);
    await _save();
    await _run(s, r);
    unawaited(sync());
  }

  List<Map<String, dynamic>> get _targets => [for (final id in session!.sectionIds) SectionIdentity(id).toNative()];

  Future<void> _run(SessionInfo s, Map<String, dynamic> r) async {
    session = s;
    rec = r;
    (_outbox['sessions'] as Map)[s.key] = r;
    _secret = base64.decode(r['secretB64']);
    roster = app.rosterFor(s);
    _checkinTimes.clear();
    _nonces.clear();
    rejected = 0;
    notInClass = 0;
    for (final c in (_outbox['checkins'] as List).where((c) => c['sessionKey'] == s.key)) {
      _nonces.add(c['nonce']);
      if (c['studentId'] != null) (_checkinTimes[c['studentId']] ??= []).add(c['receivedAt']);
    }
    _replan();
    error = null;
    final now = app.now();
    _lastPhase = _phaseKey(now);
    if (!paused) await _startRadio(now);
    await WakelockPlus.enable(); // iOS can only advertise while the app is on screen
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    notifyListeners();
  }

  Future<void> _startRadio(int now) async {
    try {
      await Native.teacherStart(targets: _targets, toggle: _toggle, challenge: _challenge(now));
    } catch (e) {
      error = 'Bluetooth could not start: $e';
    }
  }

  void _replan() {
    final r = rec!;
    final base = planChecks(
      _secret,
      SessionTimes(
        scheduledStart: r['scheduledStartLocal'],
        scheduledEnd: r['scheduledEndLocal'],
        actualStart: r['actualStart'],
        actualEnd: r['actualEnd'],
        plannedEnd: r['plannedEnd'],
      ),
      _policy,
    );
    windows = withExtraChecks(base, [for (final e in (r['extraChecks'] as List? ?? const [])) List<int>.from(e)]);
  }

  Uint8List _challenge(int now) {
    final s = session!;
    final ph = currentPhase(windows, now);
    final slot = slotAt(now);
    _lastSlot = slot;
    return Challenge(
      shortId: s.shortId,
      slot: slot,
      token: tokenFor(_secret, s.shortId, slot),
      phase: ph.phase,
      windowIndex: ph.index,
    ).encode();
  }

  String _phaseKey(int now) {
    final p = currentPhase(windows, now);
    return '${p.phase.name}${p.index}';
  }

  // ------------------------------------------------------------------ running

  int _ticks = 0;
  Future<void> _onTick() async {
    if (!running) return;
    final now = app.now();
    final r = rec!;
    if (paused) {
      ((r['pauses'] as List).last as List)[1] = now;
      if (now >= r['plannedEnd']) {
        r['actualEnd'] = r['plannedEnd'];
        return _finish();
      }
      if (++_ticks % 10 == 0) await _save();
      return;
    }

    // Record that the phone was active (this is how the server knows which checks ran).
    final act = (r['activity'] as List);
    final last = act.last as List;
    if (now - (last[1] as int) <= 10000) {
      last[1] = now;
    } else {
      act.add([now, now]); // the app was frozen or killed for a while
    }
    r['dirty'] = true;

    if (stopAdvertisingAt != null && now >= stopAdvertisingAt!) return _finish();
    if (r['actualEnd'] == null && now >= r['plannedEnd']) {
      r['actualEnd'] = r['plannedEnd'];
      return _finish();
    }

    // A check opened or closed: flip the toggle so every phone in the room wakes up.
    final pk = _phaseKey(now);
    final phaseChanged = pk != _lastPhase;
    if (phaseChanged) {
      _lastPhase = pk;
      r['toggle'] = 1 - _toggle;
    }
    if (phaseChanged || slotAt(now) != _lastSlot) {
      try {
        await Native.teacherUpdate(toggle: _toggle, challenge: _challenge(now));
      } catch (e) {
        error = 'Bluetooth: $e';
      }
      if (phaseChanged) notifyListeners();
    }
    if (++_ticks % 10 == 0) {
      await _save();
      notifyListeners();
    }
  }

  Future<void> _onEvent(Map<String, dynamic> e) async {
    if (e['type'] == 'teacherError' && running) {
      error = 'Bluetooth: ${e['message']}';
      notifyListeners();
      return;
    }
    if (e['type'] != 'checkin') return;
    final id = e['id'] as int;
    if (!running || paused) return Native.teacherRespond(id, _retry);
    final code = _verify(Uint8List.fromList(List<int>.from(e['data'])));
    await Native.teacherRespond(id, code);
    notifyListeners();
  }

  /// Check a student's signed check-in right away, so their phone learns the result.
  int _verify(Uint8List raw) {
    final receivedAt = app.now();
    final s = session!;
    CheckIn c;
    try {
      c = CheckIn.decode(raw);
    } catch (_) {
      rejected++;
      return _retry;
    }
    if (c.shortId != s.shortId ||
        tokenFor(_secret, c.shortId, c.slot) != c.token ||
        (c.slot * slotMs - receivedAt).abs() > _slotToleranceMs) {
      rejected++;
      return _retry;
    }
    if (_nonces.contains(c.nonceHex)) return _accept; // repeated write after a lost reply
    final student = roster.where((r) => r.deviceId == c.deviceId).firstOrNull;
    if (student == null) {
      // Maybe a new phone approved today: refresh the class list once, let the phone retry.
      if (receivedAt - _lastRosterRefresh > 2 * minuteMs) {
        _lastRosterRefresh = receivedAt;
        unawaited(
          app.refreshSchedule().then((_) {
            if (session != null) roster = app.rosterFor(session!);
          }),
        );
        return _retry;
      }
      notInClass++;
      return _notInClass;
    }
    if (!c.verify(student.publicKeySpki!)) {
      rejected++;
      return _retry;
    }
    _nonces.add(c.nonceHex);
    (_outbox['checkins'] as List).add({
      'sessionKey': s.key,
      'rawB64': base64.encode(raw),
      'receivedAt': receivedAt,
      'nonce': c.nonceHex,
      'studentId': student.id,
      'synced': false,
    });
    (_checkinTimes[student.id] ??= []).add(receivedAt);
    return _accept;
  }

  // ------------------------------------------------------------------ teacher controls

  /// Live view: which checks each student passed so far, plus the teacher's own marks.
  ({List<CheckWindow> windows, Map<String, Set<String>> passed}) liveView() {
    final v = classView(windows, [for (final r in roster) _checkinTimes[r.id] ?? const []], roster.length, _policy);
    final passed = <String, Set<String>>{
      for (final e in _checkinTimes.entries)
        e.key: {
          for (final w in v.windows)
            if (e.value.any(w.contains)) w.id,
        },
    };
    return (windows: v.windows, passed: passed);
  }

  bool hasArrived(String studentId) => (_checkinTimes[studentId] ?? const []).isNotEmpty;

  /// The teacher's manual status for a student in this class (null = automatic).
  String? markOf(String studentId) => (rec?['marks'] as Map?)?[studentId];

  /// Teacher sets a student's status by hand (works offline; uploaded with the class).
  Future<void> mark(String studentId, String? status, {String reason = 'set by teacher during class'}) async {
    final r = rec!;
    (r['marks'] as Map)[studentId] = status;
    (_outbox['marks'] as List).add({
      'sessionKey': r['key'],
      'studentId': studentId,
      'status': status,
      'reason': reason,
      'synced': false,
    });
    await _save();
    notifyListeners();
    unawaited(sync());
  }

  /// Open a surprise check right now (up to 3 per class).
  Future<void> surpriseCheck() async {
    final now = app.now();
    if (paused || stopAdvertisingAt != null) throw StateError('Resume the class first');
    if (currentPhase(windows, now).phase != Phase.arrive) throw StateError('A check is already running');
    if (surpriseChecksUsed >= 3) throw StateError('Up to 3 surprise checks per class');
    final len = _policy.midWindowMin * minuteMs;
    if (now + len > windows.last.from) throw StateError('Too close to the end check');
    (rec!['extraChecks'] as List).add([now, now + len]);
    rec!['dirty'] = true;
    _replan();
    await _onTick(); // flips the toggle and pushes the new challenge immediately
    await _save();
    notifyListeners();
  }

  /// Stop taking attendance for a while (e.g. class goes outside). Checks in a pause count for no one.
  Future<void> pause() async {
    if (paused || !running) return;
    final now = app.now();
    rec!['paused'] = true;
    (rec!['pauses'] as List).add([now, now]);
    rec!['dirty'] = true;
    try {
      await Native.teacherStop();
    } catch (_) {}
    await _save();
    notifyListeners();
  }

  Future<void> resume() async {
    if (!paused) return;
    rec!['paused'] = false;
    rec!['dirty'] = true;
    final now = app.now();
    (rec!['activity'] as List).add([now, now]);
    await _startRadio(now);
    await _save();
    notifyListeners();
  }

  Future<void> extend(int minutes) async {
    final r = rec!;
    final maxEnd = (r['scheduledEndLocal'] as int) + _maxExtensionMin * minuteMs;
    r['plannedEnd'] = min(maxEnd, (r['plannedEnd'] as int) + minutes * minuteMs);
    r['dirty'] = true;
    _replan();
    await _save();
    notifyListeners();
  }

  /// End now. If the regular END window hasn't started, END opens immediately for a few
  /// minutes so students still get their final check.
  Future<void> end() async {
    final r = rec!;
    if (r['actualEnd'] != null) return;
    final now = app.now();
    r['actualEnd'] = now;
    r['dirty'] = true;
    if (paused) return _finish();
    _replan();
    final endW = windows.last;
    if (now < endW.to && endW.from >= now) {
      stopAdvertisingAt = endW.to;
    } else {
      await _finish();
      return;
    }
    await _save();
    notifyListeners();
  }

  Future<void> _finish() async {
    _tick?.cancel();
    final r = rec!;
    r['paused'] = false;
    r['state'] = 'ENDED';
    r['actualEnd'] ??= app.now();
    r['dirty'] = true;
    try {
      await Native.teacherStop();
    } catch (_) {}
    await WakelockPlus.disable();
    await app.store.write('teacher.active', null);
    await _save();
    rec = null;
    session = null;
    stopAdvertisingAt = null;
    notifyListeners();
    unawaited(sync());
  }

  // ------------------------------------------------------------------ upload

  bool _syncing = false;

  /// Upload everything not yet on the server.
  Future<void> sync() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final dirty = _sessions().values.where((s) => s['dirty'] == true).map((s) => Map<String, dynamic>.from(s)).toList();
      final pending = (_outbox['checkins'] as List).where((c) => c['synced'] != true).take(1000).toList();
      final marks = (_outbox['marks'] as List).where((m) => m['synced'] != true).take(500).toList();
      if (dirty.isEmpty && pending.isEmpty && marks.isEmpty) return;
      final body = {
        'sessions': [
          for (final s in dirty)
            {
              'key': s['key'],
              'kind': s['kind'],
              'state': s['state'],
              'secretB64': s['secretB64'],
              if (s['kind'] == 'ADHOC') ...{
                'sectionIds': s['sectionIds'],
                if (s['title'] != null) 'title': s['title'],
                'scheduledStart': s['scheduledStart'],
                'scheduledEnd': s['scheduledEnd'],
              },
              'actualStart': s['actualStart'],
              'actualEnd': s['actualEnd'],
              'plannedEnd': s['plannedEnd'],
              'activity': s['activity'],
              if (s['plan'] != null) 'plan': s['plan'],
              'extraChecks': s['extraChecks'] ?? [],
              'pauses': s['pauses'] ?? [],
            },
        ],
        'checkins': [
          for (final c in pending) {'sessionKey': c['sessionKey'], 'rawB64': c['rawB64'], 'receivedAt': c['receivedAt']},
        ],
        'marks': [
          for (final m in marks)
            {'sessionKey': m['sessionKey'], 'studentId': m['studentId'], 'status': m['status'], 'reason': m['reason']},
        ],
      };
      final res = await app.api.post('/sessions/sync', body);
      final sres = res['sessions'] as List;
      for (var i = 0; i < dirty.length; i++) {
        final stored = (_outbox['sessions'] as Map)[dirty[i]['key']];
        stored['syncError'] = sres[i]['ok'] == true ? null : sres[i]['error'];
        // Only clear dirty if nothing changed since the payload was built.
        if (jsonEncode(stored['activity']) == jsonEncode(dirty[i]['activity']) && stored['state'] == dirty[i]['state']) {
          stored['dirty'] = false;
        }
      }
      final cres = res['checkins'] as List;
      for (var i = 0; i < pending.length; i++) {
        pending[i]['synced'] = true;
        if (cres[i]['ok'] != true && cres[i]['duplicate'] != true) pending[i]['serverError'] = cres[i]['error'];
      }
      final mres = (res['marks'] as List?) ?? const [];
      for (var i = 0; i < marks.length; i++) {
        // A mark for a class the server doesn't know yet is retried next time.
        if (i < mres.length && (mres[i]['ok'] == true || mres[i]['error'] != 'session not found')) marks[i]['synced'] = true;
      }
      _pruneOutbox();
      await _save();
      syncError = null;
      lastSyncAt = DateTime.now().millisecondsSinceEpoch;
    } catch (e) {
      syncError = e.toString();
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// Keep the outbox small: drop synced data older than 3 days.
  void _pruneOutbox() {
    final cutoff = app.now() - 3 * 24 * 3600 * 1000;
    final sessions = _outbox['sessions'] as Map;
    sessions.removeWhere((k, s) => s['dirty'] != true && s['state'] == 'ENDED' && (s['actualEnd'] ?? 0) < cutoff);
    (_outbox['checkins'] as List).removeWhere((c) => c['synced'] == true && !sessions.containsKey(c['sessionKey']));
    (_outbox['marks'] as List).removeWhere((m) => m['synced'] == true && !sessions.containsKey(m['sessionKey']));
  }

  Map<String, dynamic>? localRecord(String key) => _sessions()[key] == null ? null : Map<String, dynamic>.from(_sessions()[key]);

  /// Classes started on this phone that the server doesn't know yet (e.g. taken offline).
  List<SessionInfo> localOnlySessions(Set<String> known) => [
    for (final r in _sessions().values)
      if (!known.contains(r['key']) && r['info'] != null)
        SessionInfo({...Map<String, dynamic>.from(r['info']), 'state': r['state']}),
  ];

  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    return uuidFromBytes(b);
  }

  @override
  void dispose() {
    _tick?.cancel();
    _syncTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
