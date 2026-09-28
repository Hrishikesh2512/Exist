import 'dart:async';

import 'package:flutter/material.dart';

import '../core/account_screens.dart';
import '../core/app_state.dart';
import '../core/calendar_screen.dart';
import '../core/format.dart';
import '../core/models.dart';
import '../core/native.dart';
import 'qr_checkin.dart';
import 'sheet.dart';

class StudentHome extends StatefulWidget {
  const StudentHome({super.key});
  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends State<StudentHome> with WidgetsBindingObserver {
  int _tab = 0;
  Map<String, dynamic>? _bt;
  List<Map<String, dynamic>> _log = const [];
  Map<String, dynamic>? _summary;
  List<dynamic> _alerts = const [];
  Timer? _poll;
  StreamSubscription? _events;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refreshLocal());
    _events = Native.events.listen((e) {
      if (e['type'] == 'studentCheckin' || e['type'] == 'bluetooth') _refreshLocal();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _events?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refreshLocal() async {
    try {
      final bt = await Native.state();
      final log = await Native.studentLog();
      if (mounted) {
        setState(() {
          _bt = bt;
          _log = log;
        });
      }
    } catch (_) {}
  }

  Future<void> _refresh() async {
    final app = AppScope.read(context);
    await _refreshLocal();
    await app.refreshSchedule();
    unawaited(app.pollNotifications());
    try {
      final summary = Map<String, dynamic>.from(await app.api.get('/me/attendance'));
      final alerts = await app.api.get('/me/notifications') as List;
      if (mounted) {
        setState(() {
          _summary = summary;
          _alerts = alerts;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final pages = [_today(app), _attendance(), _alertsPage()];
    return Scaffold(
      appBar: AppBar(
        title: Text(['Classes', 'Attendance', 'Alerts'][_tab]),
        actions: [
          IconButton(
            tooltip: 'Calendar',
            icon: const Icon(Icons.calendar_month),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CalendarScreen())),
          ),
          IconButton(
            tooltip: 'Scan classroom QR',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const QrCheckinScreen())),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _refresh, child: pages[_tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.today), label: 'Classes'),
          const NavigationDestination(icon: Icon(Icons.insights), label: 'Attendance'),
          NavigationDestination(
            icon: Badge(isLabelVisible: _alerts.any((a) => a['readAt'] == null), child: const Icon(Icons.notifications)),
            label: 'Alerts',
          ),
        ],
      ),
    );
  }

  Widget _banner(IconData icon, String text, Color color, {Widget? action}) => Card(
    color: color.withValues(alpha: 0.12),
    child: ListTile(
      leading: Icon(icon, color: color),
      title: Text(text),
      trailing: action,
    ),
  );

  Widget _today(AppState app) {
    final now = app.now();
    final list = app.sessions.where((s) => s.scheduledEnd > now - 12 * 3600 * 1000).toList();
    final bt = _bt?['bluetooth'];
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (bt != null && bt != 'on')
          _banner(
            Icons.bluetooth_disabled,
            'Bluetooth is off. Turn it on or your attendance cannot be marked.',
            Theme.of(context).colorScheme.error,
          ),
        if (_bt?['backgroundOk'] == false)
          _banner(
            Icons.battery_alert,
            'Battery saver may stop attendance in the background.',
            Colors.orange,
            action: TextButton(onPressed: Native.requestBackgroundExemption, child: const Text('Fix')),
          ),
        if (app.offline) _banner(Icons.cloud_off, 'Offline. Attendance still works; your record updates later.', Colors.blueGrey),
        if (list.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('No classes in the next few days.')),
          ),
        for (final s in list) _classCard(app, s, now),
      ],
    );
  }

  Widget _classCard(AppState app, SessionInfo s, int now) {
    final mine = _log.where((l) => l['key'] == s.key && l['ok'] == true).toList();
    final inProgress = now >= s.scheduledStart - 10 * 60000 && now <= s.scheduledEnd + 30 * 60000;
    String? note;
    switch (s.state) {
      case 'WAITING_TEACHER':
        note = 'Teacher has not started yet. You will not be marked late for that.';
      case 'CANCELLED':
        note = 'Cancelled${s.cancelReason != null ? ': ${s.cancelReason}' : ''}. Does not count.';
      case 'TEACHER_NO_SHOW':
        note = 'Class did not happen. Does not count.';
      case 'SCHEDULED':
        note = 'Extra class';
    }
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
                if (s.myStatus != null)
                  StatusChip(s.myStatus)
                else
                  Text(s.state == 'ACTIVE' ? 'In progress' : '', style: const TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 4),
            Text(s.label, style: Theme.of(context).textTheme.titleMedium),
            Text([s.teacherName, s.roomId].whereType<String>().join(' · '), style: Theme.of(context).textTheme.bodySmall),
            if (note != null) ...[const SizedBox(height: 6), Text(note, style: const TextStyle(fontStyle: FontStyle.italic))],
            if (mine.isNotEmpty || (inProgress && s.state != 'CANCELLED')) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                children: [
                  for (final ph in const ['ARRIVE', 'MID', 'END'])
                    Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        mine.any((l) => l['phase'] == ph) ? Icons.check_circle : Icons.radio_button_unchecked,
                        size: 18,
                      ),
                      label: Text(const {'ARRIVE': 'Start', 'MID': 'Middle', 'END': 'End'}[ph]!),
                    ),
                ],
              ),
            ],
            if (s.myReasons.isNotEmpty && s.myStatus != 'PRESENT')
              Text(s.myReasons.join(' · '), style: Theme.of(context).textTheme.bodySmall),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (inProgress &&
                    (s.state == 'ACTIVE' || s.state == 'WAITING_TEACHER' || s.state == 'UPCOMING' || s.state == 'SCHEDULED'))
                  TextButton.icon(
                    icon: const Icon(Icons.bluetooth_searching),
                    label: const Text('Check in now'),
                    onPressed: () => _checkNow(s),
                  ),
                if (s.state == 'ENDED' && s.myStatus != null && s.myStatus != 'PRESENT' && s.myStatus != 'EXCUSED')
                  TextButton(onPressed: () => _dispute(s), child: const Text('Dispute')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _checkNow(SessionInfo s) async {
    final m = ScaffoldMessenger.of(context);
    m.showSnackBar(const SnackBar(content: Text('Looking for your teacher\'s phone…')));
    try {
      final r = await Native.studentCheckNow();
      m.showSnackBar(
        SnackBar(
          content: Text(
            r['ok'] == true
                ? 'Checked in: ${r['title'] ?? ''}'
                : r['skipped'] == true
                ? 'Already checked in for this part of class'
                : r['error'] == 'not in this class'
                ? 'The teacher\'s phone nearby is for a class you are not in.'
                : 'Could not check in: ${r['error']}. Move closer to the teacher, or scan the classroom QR.',
          ),
        ),
      );
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text('Could not check in: $e')));
    }
    await _refreshLocal();
  }

  Future<void> _dispute(SessionInfo s) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Dispute this record'),
        content: TextField(
          controller: c,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'What happened?'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final m = ScaffoldMessenger.of(context);
    try {
      await AppScope.read(context).api.post('/disputes', {'sessionKey': s.key, 'message': c.text});
      m.showSnackBar(const SnackBar(content: Text('Sent to your teacher')));
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _attendance() {
    final s = _summary;
    if (s == null) {
      return ListView(
        children: const [
          Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('Pull to load')),
          ),
        ],
      );
    }
    final threshold = (s['threshold'] as num).toDouble();
    final overall = Map<String, dynamic>.from(s['overall'] ?? const {'total': 0, 'percent': 100});
    final subjects = (s['sections'] as List).cast<Map<String, dynamic>>().where((x) => x['current'] != false).toList();
    Color tone(num p) => p < threshold ? Theme.of(context).colorScheme.error : Colors.green.shade700;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Text('All my classes'),
                const SizedBox(height: 4),
                Text(
                  '${overall['percent']}%',
                  style: Theme.of(context).textTheme.displaySmall?.copyWith(color: tone(overall['percent'])),
                ),
                Text('${overall['attended']} of ${overall['total']} classes · required ${threshold.round()}%'),
              ],
            ),
          ),
        ),
        for (final sec in subjects)
          Card(
            child: ListTile(
              title: Text(sec['label'] ?? sec['sectionId']),
              subtitle: Text(
                '${sec['total']} classes counted${(sec['counts']?['ABSENT'] ?? 0) > 0 ? ' · ${sec['counts']['ABSENT']} absent' : ''}',
              ),
              trailing: Text(
                '${sec['percent']}%',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: tone(sec['percent'])),
              ),
              onTap: () => _subjectHistory(sec, s['recent'] as List),
            ),
          ),
        if (subjects.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Text('No classes yet. Join one with the code from your teacher.')),
        Padding(
          padding: const EdgeInsets.all(8),
          child: OutlinedButton.icon(onPressed: _joinClass, icon: const Icon(Icons.add), label: const Text('Join a class')),
        ),
      ],
    );
  }

  void _subjectHistory(Map<String, dynamic> sec, List recent) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StudentSheetScreen(sectionId: sec['sectionId'], title: sec['label'] ?? sec['sectionId']),
      ),
    );
  }

  Future<void> _joinClass() async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Join a class'),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Class code from your teacher'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Join')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final m = ScaffoldMessenger.of(context);
    try {
      final label = await AppScope.read(context).joinClass(c.text);
      m.showSnackBar(SnackBar(content: Text('Joined $label. Attendance is automatic from now on.')));
      await _refresh();
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _alertsPage() => ListView(
    padding: const EdgeInsets.all(12),
    children: [
      if (_alerts.isEmpty)
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: Text('Nothing yet')),
        ),
      for (final a in _alerts)
        ListTile(
          leading: const Icon(Icons.notifications_none),
          title: Text(a['title']),
          subtitle: Text('${a['body']}\n${DateTime.parse(a['createdAt']).toLocal().toString().substring(0, 16)}'),
          isThreeLine: true,
        ),
    ],
  );
}
