import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/native.dart';
import '../domain/plan.dart';
import '../core/calendar_screen.dart';
import 'disputes.dart';
import 'extra_class.dart';
import 'results.dart';
import 'runner.dart';
import 'classes.dart';
import 'start_now.dart';
import '../core/account_screens.dart';
import 'session_screen.dart';

class TeacherHome extends StatefulWidget {
  final TeacherRunner runner;
  const TeacherHome({super.key, required this.runner});
  @override
  State<TeacherHome> createState() => _TeacherHomeState();
}

class _TeacherHomeState extends State<TeacherHome> with WidgetsBindingObserver {
  TeacherRunner get runner => widget.runner;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ensurePermissions();
  }

  /// Teachers need advertise/connect to run a class (and notifications for alerts).
  Future<void> _ensurePermissions() async {
    await [
      if (Platform.isAndroid) ...[Permission.bluetoothAdvertise, Permission.bluetoothConnect, Permission.bluetoothScan],
      if (Platform.isIOS) Permission.bluetooth,
      Permission.notification,
    ].request();
    if (Platform.isAndroid) await Native.requestBackgroundExemption();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      AppScope.read(context).refreshSchedule();
      runner.sync();
    }
  }

  bool get _autoStartOn => AppScope.read(context).store.read<bool>('teacher.autostart') ?? true;

  bool _startable(AppState app, SessionInfo s, int now) =>
      const {'UPCOMING', 'WAITING_TEACHER', 'SCHEDULED', 'TEACHER_NO_SHOW'}.contains(s.state) &&
      runner.localRecord(s.key) == null &&
      startAllowed(s.scheduledStart, s.scheduledEnd, now, app.policy);

  void _open(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));

  Future<void> _start(SessionInfo s) async {
    try {
      await runner.start(s);
      if (mounted) _open(SessionScreen(runner: runner));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))));
      }
    }
  }

  Future<void> _cancel(SessionInfo s) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this class?'),
        content: TextField(
          controller: c,
          decoration: const InputDecoration(labelText: 'Reason (students will see it)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Cancel class')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final app = AppScope.read(context);
    try {
      await app.api.post('/sessions/cancel', {
        'key': s.key,
        'reason': c.text.trim().isEmpty ? 'Cancelled by teacher' : c.text.trim(),
      });
      await app.refreshSchedule();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Move a class to another time: students get the new time; the old slot is cancelled.
  Future<void> _reschedule(SessionInfo s) async {
    final start = DateTime.fromMillisecondsSinceEpoch(s.scheduledStart);
    final date = await showDatePicker(
      context: context,
      initialDate: start.isBefore(DateTime.now()) ? DateTime.now() : start,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 30)),
      helpText: 'Move ${s.label} to',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(start));
    if (time == null || !mounted) return;
    final newStart = DateTime(date.year, date.month, date.day, time.hour, time.minute).millisecondsSinceEpoch;
    final app = AppScope.read(context);
    try {
      await app.api.post('/sessions/reschedule', {
        'key': s.key,
        'scheduledStart': newStart,
        'scheduledEnd': newStart + (s.scheduledEnd - s.scheduledStart),
        'reason': 'Moved by teacher',
      });
      await app.refreshSchedule();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Moved. Students have been told.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListenableBuilder(
      listenable: runner,
      builder: (context, _) {
        final now = app.now();
        // Classes from the server, plus classes taken on this phone that haven't been uploaded yet.
        final list =
            [
                ...app.sessions,
                ...runner.localOnlySessions(app.sessions.map((s) => s.key).toSet()),
              ].where((s) => s.scheduledEnd > now - 18 * 3600 * 1000).toList()
              ..sort((a, b) => a.scheduledStart.compareTo(b.scheduledStart));
        return Scaffold(
          appBar: AppBar(
            title: const Text('My classes'),
            actions: [
              IconButton(
                tooltip: 'Calendar',
                icon: const Icon(Icons.calendar_month),
                onPressed: () => _open(const CalendarScreen()),
              ),
              IconButton(
                tooltip: 'My classes',
                icon: const Icon(Icons.groups),
                onPressed: () => _open(ClassesScreen(runner: runner)),
              ),
              IconButton(tooltip: 'Disputes', icon: const Icon(Icons.gavel), onPressed: () => _open(const DisputesScreen())),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'extra') {
                    _open(const ExtraClassScreen());
                  } else if (v == 'settings') {
                    _open(const SettingsScreen());
                  } else if (v == 'auto') {
                    await app.store.write('teacher.autostart', !_autoStartOn);
                    setState(() {});
                  } else if (v == 'logout') {
                    if (runner.running || runner.pendingUploads > 0) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(const SnackBar(content: Text('Finish the class and sync first')));
                    } else {
                      await app.logout();
                    }
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(enabled: false, child: Text(app.me?['name'] ?? '')),
                  CheckedPopupMenuItem(value: 'auto', checked: _autoStartOn, child: const Text('Auto-start timetabled classes')),
                  const PopupMenuItem(value: 'extra', child: Text('Schedule an extra class for later')),
                  const PopupMenuItem(value: 'settings', child: Text('Settings')),
                  const PopupMenuItem(value: 'logout', child: Text('Sign out')),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => runner.running ? _open(SessionScreen(runner: runner)) : _open(StartNowScreen(runner: runner)),
            icon: Icon(runner.running ? Icons.sensors : Icons.play_arrow),
            label: Text(runner.running ? 'Open running class' : 'Start a class now'),
          ),
          body: RefreshIndicator(
            onRefresh: () async {
              await app.refreshSchedule();
              await runner.sync();
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              children: [
                if (runner.running)
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: ListTile(
                      leading: const Icon(Icons.sensors),
                      title: Text('Running: ${runner.session!.label}'),
                      subtitle: Text(Platform.isIOS ? 'Keep Exist open on your desk' : 'Works with the phone locked'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _open(SessionScreen(runner: runner)),
                    ),
                  ),
                _syncLine(app),
                for (final s in list) _card(app, s, now),
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No classes in the next few days')),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _syncLine(AppState app) {
    final pending = runner.pendingUploads;
    final text = runner.syncError != null && pending > 0
        ? '$pending item(s) waiting for internet. Attendance is safe on this phone.'
        : pending > 0
        ? 'Uploading $pending item(s)…'
        : app.offline
        ? 'Offline: showing saved timetable'
        : 'All attendance uploaded';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Row(
        children: [
          Icon(pending > 0 ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }

  Widget _card(AppState app, SessionInfo s, int now) {
    final local = runner.localRecord(s.key);
    final runningThis = runner.running && runner.session?.key == s.key;
    final endedLocally = local != null && local['state'] == 'ENDED';
    final state = runningThis ? 'ACTIVE' : (endedLocally ? 'ENDED' : s.state);
    final startable = !runner.running && _startable(app, s, now);
    final lateBy = now - s.scheduledStart;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${dayLabel(s.scheduledStart, now)} · ${hm(s.scheduledStart)}–${hm(s.scheduledEnd)}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                Text(_stateLabel(state), style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(s.label, style: Theme.of(context).textTheme.titleMedium),
            Text(
              [
                s.roomId,
                '${app.rosterFor(s).length} students',
                if (s.kind == 'ADHOC') 'extra class',
              ].whereType<String>().join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (s.state == 'CANCELLED' && s.cancelReason != null) Text('Cancelled: ${s.cancelReason}'),
            if (s.substitutePending) const Text('Cover class: waiting for admin approval'),
            if (startable && lateBy > 0)
              Text(
                'You are ${lateBy ~/ minuteMs} min late. Students will not be marked late for it.',
                style: TextStyle(color: Colors.orange.shade800),
              ),
            if (local?['syncError'] != null)
              Text('Upload problem: ${local!['syncError']}', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (startable) TextButton(onPressed: () => _cancel(s), child: const Text('Cancel')),
                if (!startable && const {'UPCOMING', 'SCHEDULED'}.contains(s.state) && local == null)
                  TextButton(onPressed: () => _cancel(s), child: const Text('Cancel')),
                if (const {'UPCOMING', 'SCHEDULED', 'WAITING_TEACHER'}.contains(s.state) && local == null)
                  TextButton(onPressed: () => _reschedule(s), child: const Text('Move')),
                if (startable)
                  FilledButton.icon(onPressed: () => _start(s), icon: const Icon(Icons.play_arrow), label: const Text('Start')),
                if (runningThis)
                  FilledButton(
                    onPressed: () => _open(SessionScreen(runner: runner)),
                    child: const Text('Open'),
                  ),
                if (state == 'ENDED')
                  OutlinedButton(
                    onPressed: () => _open(ResultsScreen(sessionKey: s.key, title: s.label)),
                    child: const Text('Results'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _stateLabel(String s) =>
      const {
        'UPCOMING': 'Upcoming',
        'WAITING_TEACHER': 'Not started',
        'SCHEDULED': 'Extra class',
        'ACTIVE': 'Running',
        'ENDED': 'Done',
        'CANCELLED': 'Cancelled',
        'TEACHER_NO_SHOW': 'Missed',
      }[s] ??
      s;
}
