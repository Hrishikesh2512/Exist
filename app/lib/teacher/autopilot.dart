import 'dart:async';

import '../core/app_state.dart';
import '../domain/plan.dart';
import 'runner.dart';

/// Starts classes on time without any screen being open. Runs from main(), so it also
/// works when an Android alarm wakes the app in the background with no UI.
class TeacherAutopilot {
  final AppState app;
  final TeacherRunner runner;
  Timer? _timer;
  int _lastRefresh = 0;
  TeacherAutopilot(this.app, this.runner);

  bool get enabled => app.store.read<bool>('teacher.autostart') ?? true;

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 15), (_) => tick());
    tick();
  }

  Future<void> tick() async {
    if (!app.signedIn || !app.isTeacher) return;
    final now = app.now();
    if (now - _lastRefresh > 10 * minuteMs) {
      _lastRefresh = now;
      await app.refreshSchedule(); // picks up cancellations, extra classes, substitutions
    }
    await runner.resumeIfNeeded();
    if (!enabled || runner.running) return;
    for (final s in app.sessions) {
      final due = now >= s.scheduledStart - minuteMs;
      if (!s.autoStart || !due || !startable(s.state, s.key, s.scheduledStart, s.scheduledEnd, now)) continue;
      try {
        await runner.start(s);
      } catch (_) {}
      return;
    }
  }

  bool startable(String state, String key, int scheduledStart, int scheduledEnd, int now) =>
      const {'UPCOMING', 'WAITING_TEACHER', 'SCHEDULED', 'TEACHER_NO_SHOW'}.contains(state) &&
      runner.localRecord(key) == null &&
      startAllowed(scheduledStart, scheduledEnd, now, app.policy);
}
