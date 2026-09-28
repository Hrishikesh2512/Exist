import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';

import '../domain/plan.dart';
import 'api.dart';
import 'models.dart';
import '../protocol/protocol.dart';
import 'native.dart';
import 'offline.dart';
import 'store.dart';

class AppState extends ChangeNotifier {
  final Api api = Api();
  final Store store;
  /// Data saved on the phone + changes waiting for internet.
  late final Offline local = Offline(api, store);
  AppState(this.store) {
    api.token = store.read<String>('auth.token');
    me = store.read<Map<String, dynamic>>('auth.me');
    _serverOffset = store.read<int>('clock.offset') ?? 0;
    _loadCachedSchedule();
  }

  Map<String, dynamic>? me;
  List<SessionInfo> sessions = [];
  List<Subject> subjects = [];
  Map<String, List<RosterEntry>> roster = {};
  Policy policy = const Policy();
  int _serverOffset = 0;
  DateTime? scheduleFetchedAt;
  String? lastError;
  bool offline = false;

  bool get signedIn => api.token != null && me != null;
  String get role => me?['role'] ?? '';
  bool get isTeacher => role == 'TEACHER';
  bool get mustChangePassword => me?['mustChangePassword'] == true;
  bool get consentRequired => me?['consentRequired'] != false;
  String? get deviceId => store.read<String>('device.id');

  /// Server-corrected clock. Phones with a wrong time still compute the right slots.
  int now() => DateTime.now().millisecondsSinceEpoch + _serverOffset;

  void _loadCachedSchedule() {
    final s = store.read<Map<String, dynamic>>('schedule');
    if (s != null) _applySchedule(s);
  }

  void _applySchedule(Map<String, dynamic> s) {
    sessions = (s['sessions'] as List).map((e) => SessionInfo(Map<String, dynamic>.from(e))).toList();
    subjects = ((s['subjects'] as List?) ?? const []).map((e) => Subject(Map<String, dynamic>.from(e))).toList();
    roster = {
      for (final e in (Map<String, dynamic>.from(s['roster'] ?? {})).entries)
        e.key: (e.value as List).map((r) => RosterEntry(Map<String, dynamic>.from(r))).toList(),
    };
    policy = Policy.fromJson(Map<String, dynamic>.from(s['policy'] ?? {}));
    scheduleFetchedAt = s['fetchedAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch(s['fetchedAt']);
  }

  /// Create an account (student or teacher); signs in on success.
  Future<void> register({
    required String role,
    required String name,
    required String email,
    required String password,
    String? rollNo,
    String? classCode,
    String? teacherCode,
  }) async {
    final r = await api.post('/auth/register', {
      'role': role,
      'name': name,
      'email': email,
      'password': password,
      'rollNo': ?rollNo,
      'classCode': ?classCode,
      'teacherCode': ?teacherCode,
    });
    api.token = r['token'];
    await store.write('auth.token', r['token']);
    await refreshMe();
    await refreshSchedule();
  }

  /// Join a class with its code (students) or co-teach it (teachers).
  Future<String> joinClass(String code) async {
    final r = await api.post('/classes/join', {'code': code.trim()});
    await refreshSchedule();
    return r['label'] as String;
  }

  Future<void> login(String email, String password) async {
    final r = await api.post('/auth/login', {'email': email.trim(), 'password': password});
    api.token = r['token'];
    await store.write('auth.token', r['token']);
    await refreshMe();
    await refreshSchedule();
  }

  Future<void> logout() async {
    api.token = null;
    me = null;
    sessions = [];
    roster = {};
    final deviceId = this.deviceId;
    await store.clear();
    // The hardware key and binding survive logout on purpose: the same phone keeps its identity.
    if (deviceId != null) await store.write('device.id', deviceId);
    notifyListeners();
  }

  Future<void> refreshMe() async {
    me = Map<String, dynamic>.from(await api.get('/me'));
    await store.write('auth.me', me);
    final dev = me!['device'];
    if (dev == null) {
      await store.write('device.id', null);
    } else {
      await store.write('device.id', dev['id']);
    }
    notifyListeners();
  }

  Future<void> refreshSchedule() async {
    try {
      final sent = DateTime.now().millisecondsSinceEpoch;
      final s = Map<String, dynamic>.from(await api.get('/me/schedule?days=7'));
      final rtt = DateTime.now().millisecondsSinceEpoch - sent;
      _serverOffset = (s['serverNow'] as int) + rtt ~/ 2 - DateTime.now().millisecondsSinceEpoch;
      await store.write('clock.offset', _serverOffset);
      s['fetchedAt'] = DateTime.now().millisecondsSinceEpoch;
      await store.write('schedule', s);
      _applySchedule(s);
      offline = false;
      lastError = null;
      await _configureNative();
      // Send changes made offline, then save everything this person may look at without internet.
      unawaited(local.flush().then((_) => prefetchForOffline()));
    } on ApiException catch (e) {
      offline = e.isOffline;
      lastError = e.message;
      if (e.status == 401) await logout();
    }
    notifyListeners();
  }

  /// Hand my subjects to the native layer, which then checks in on its own for any class of
  /// them (timetabled or started on the spot) and ignores every other class.
  Future<void> _configureNative() async {
    final id = deviceId;
    if (role == 'STUDENT' && id != null && !consentRequired) {
      await Native.studentConfigure(
        deviceId: id,
        subjects: [
          for (final sub in subjects) {'sectionId': sub.id, 'title': sub.label, ...SectionIdentity(sub.id).toNative()},
        ],
        windows: [
          for (final s in sessions)
            if (!const {'CANCELLED', 'TEACHER_NO_SHOW', 'ENDED'}.contains(s.state) && s.scheduledEnd + 30 * minuteMs > now())
              {
                'title': s.label,
                // Listen hard from 15 min before until 100 min after (teacher late / class extended).
                'from': s.scheduledStart - 15 * minuteMs,
                'to': s.scheduledEnd + 100 * minuteMs,
              },
        ],
      );
    }
    if (isTeacher) {
      await Native.scheduleTeacherAlarms([
        for (final s in sessions)
          if (s.state == 'UPCOMING' && s.scheduledStart > now())
            {'key': s.key, 'at': s.scheduledStart - minuteMs, 'title': 'Class starting: ${s.label}'},
      ]);
    }
  }

  static String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Calendar request paths, identical to the ones the screens use (so the saved copies match).
  static String monthPath(DateTime month) =>
      '/me/calendar?from=${_day(DateTime(month.year, month.month))}&to=${_day(DateTime(month.year, month.month + 1, 0))}';
  static String classDaysPath(DateTime today) =>
      '/me/calendar?from=${_day(today)}&to=${_day(today.add(const Duration(days: 60)))}';

  /// Save what a teacher or student may need offline: classes, sheets, calendar, alerts.
  Future<void> prefetchForOffline() async {
    if (!signedIn) return;
    final now = DateTime.now();
    final common = [monthPath(now), monthPath(DateTime(now.year, now.month + 1)), '/me/notifications'];
    if (isTeacher) {
      try {
        final classes = (await local.get('/classes')).data as List;
        await local.prefetch([
          ...common,
          '/teacher/device-requests',
          '/disputes',
          classDaysPath(now),
          for (final c in classes) ...[
            '/classes/${Uri.encodeComponent(c['id'])}',
            '/classes/${Uri.encodeComponent(c['id'])}/register',
            '/sections/${Uri.encodeComponent(c['id'])}/students',
          ],
        ]);
      } catch (_) {}
    } else if (role == 'STUDENT') {
      await local.prefetch([
        ...common,
        '/me/attendance',
        '/classes',
        for (final s in subjects) '/me/classes/${Uri.encodeComponent(s.id)}/sheet',
      ]);
    }
  }

  Future<void> acceptConsent(int version) async {
    await api.post('/me/consent', {'version': version});
    await refreshMe();
    await _configureNative();
  }

  Future<void> changePassword(String current, String next) async {
    final r = await api.post('/me/password', {'current': current, 'next': next});
    api.token = r['token'];
    await store.write('auth.token', r['token']);
    await refreshMe();
  }

  /// Free alternative to push: fetch new alerts and show them as phone notifications.
  /// Runs whenever the app is awake (open, or woken for class in the background).
  Future<void> pollNotifications() async {
    if (!signedIn) return;
    final since = store.read<int>('notif.since');
    if (since == null) {
      await store.write('notif.since', now()); // first run: don't replay old alerts as a burst
      return;
    }
    try {
      final list = await api.get('/me/notifications?since=$since') as List;
      var newest = since;
      for (final n in list.reversed) {
        final at = DateTime.parse(n['createdAt']).millisecondsSinceEpoch;
        if (at > newest) newest = at;
        await Native.notify(n['title'], n['body']);
      }
      await store.write('notif.since', newest);
    } catch (_) {}
  }

  /// Bind this phone's hardware key. Returns BOUND or PENDING (device change cooldown).
  Future<Map<String, dynamic>> bindDevice() async {
    final spki = await Native.publicKey();
    final challenge = base64.encode(sha256.convert(base64.decode(spki)).bytes);
    final attestation = await Native.attest(challenge);
    final sys = await Native.state();
    final os = Platform.operatingSystemVersion;
    final r = Map<String, dynamic>.from(
      await api.post('/devices/bind', {
        'platform': Platform.isIOS ? 'ios' : 'android',
        'publicKeySpki': spki,
        'attestation': attestation,
        // For the admin's eyes only (e.g. "same phone, reinstalled"). Never trusted for security.
        if (sys['model'] != null) 'model': sys['model'],
        'osVersion': os.length > 100 ? os.substring(0, 100) : os,
        if (sys['installId'] != null) 'installId': sys['installId'],
      }),
    );
    if (r['status'] == 'BOUND') {
      await store.write('device.id', r['deviceId']);
      await refreshMe();
      await _configureNative();
    }
    notifyListeners();
    return r;
  }

  List<RosterEntry> rosterFor(SessionInfo s) {
    final seen = <String>{};
    return [
      for (final sec in s.sectionIds)
        for (final r in roster[sec] ?? const <RosterEntry>[])
          if (seen.add(r.id)) r,
    ]..sort((a, b) => (a.rollNo ?? a.name).compareTo(b.rollNo ?? b.name));
  }
}

class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);
  static AppState of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppState read(BuildContext c) => c.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
