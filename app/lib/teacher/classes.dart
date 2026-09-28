import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import 'runner.dart';
import 'sections.dart';
import 'start_now.dart';
import 'subject_students.dart';

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
String _t(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';
String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void _snack(BuildContext c, Object e) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))));

/// All classes this teacher teaches: create, open, join as co-teacher, approve new phones.
class ClassesScreen extends StatefulWidget {
  final TeacherRunner runner;
  const ClassesScreen({super.key, required this.runner});
  @override
  State<ClassesScreen> createState() => _ClassesScreenState();
}

class _ClassesScreenState extends State<ClassesScreen> {
  List<dynamic>? _classes;
  int _phoneRequests = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = AppScope.read(context).api;
    try {
      final r = await api.get('/classes') as List;
      final phones = await api.get('/teacher/device-requests') as List;
      if (mounted) {
        setState(() {
          _classes = r;
          _phoneRequests = phones.length;
        });
      }
    } catch (e) {
      if (mounted) _snack(context, e);
    }
  }

  Future<void> _coTeach() async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Co-teach a class'),
        content: TextField(
          controller: c,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Co-teacher code from the class teacher'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Join')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final label = await AppScope.read(context).joinClass(c.text);
      if (mounted) _snack(context, 'You now teach $label');
      _load();
    } catch (e) {
      if (mounted) _snack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _classes;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My classes'),
        actions: [
          IconButton(
            tooltip: 'New phones to approve',
            icon: Badge(
              isLabelVisible: _phoneRequests > 0,
              label: Text('$_phoneRequests'),
              child: const Icon(Icons.phonelink_setup),
            ),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const PhoneRequestsScreen()));
              _load();
            },
          ),
          PopupMenuButton<String>(
            onSelected: (_) => _coTeach(),
            itemBuilder: (_) => const [PopupMenuItem(value: 'co', child: Text('Co-teach a class (enter code)'))],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New class'),
        onPressed: () async {
          final id = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const CreateClassScreen()));
          await _load();
          if (id != null && context.mounted) {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ClassDetailScreen(sectionId: id, runner: widget.runner),
              ),
            );
            _load();
          }
        },
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                children: [
                  if (list.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'No classes yet. Tap "New class", then share its code with your students.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (final c in list)
                    Card(
                      child: ListTile(
                        title: Text(c['label']),
                        subtitle: Text(
                          [
                            '${c['students']} students',
                            if (c['codes']?['student'] != null) 'code ${c['codes']['student']}',
                            if (c['archived'] == true) 'archived',
                          ].join(' · '),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ClassDetailScreen(sectionId: c['id'], runner: widget.runner),
                            ),
                          );
                          _load();
                        },
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class CreateClassScreen extends StatefulWidget {
  const CreateClassScreen({super.key});
  @override
  State<CreateClassScreen> createState() => _CreateClassScreenState();
}

class _CreateClassScreenState extends State<CreateClassScreen> {
  final _name = TextEditingController(), _code = TextEditingController(), _group = TextEditingController();
  DateTime? _start, _end;
  bool _busy = false;

  Future<void> _save() async {
    if (_name.text.trim().length < 2) return _snack(context, 'Enter the subject name');
    setState(() => _busy = true);
    final app = AppScope.read(context);
    final nav = Navigator.of(context);
    try {
      final r = await app.api.post('/classes', {
        'subjectName': _name.text.trim(),
        if (_code.text.trim().isNotEmpty) 'subjectCode': _code.text.trim(),
        if (_group.text.trim().isNotEmpty) 'groupName': _group.text.trim(),
        if (_start != null) 'startDate': _d(_start!),
        if (_end != null) 'endDate': _d(_end!),
      });
      await app.refreshSchedule();
      nav.pop(r['id'] as String);
    } catch (e) {
      if (mounted) _snack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<DateTime?> _pick(DateTime? initial) => showDatePicker(
    context: context,
    initialDate: initial ?? DateTime.now(),
    firstDate: DateTime.now().subtract(const Duration(days: 365)),
    lastDate: DateTime.now().add(const Duration(days: 730)),
  );

  @override
  Widget build(BuildContext context) {
    InputDecoration f(String l, [String? h]) => InputDecoration(labelText: l, hintText: h, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: const Text('New class')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: f('Subject', 'e.g. Data Structures'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            textCapitalization: TextCapitalization.characters,
            decoration: f('Subject code (optional)', 'e.g. CS301'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _group,
            textCapitalization: TextCapitalization.characters,
            decoration: f('Group / section (optional)', 'e.g. CSE-A'),
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.event),
            title: Text(_start == null ? 'Starts: any time' : 'Starts ${_d(_start!)}'),
            onTap: () async {
              final d = await _pick(_start);
              if (d != null) setState(() => _start = d);
            },
          ),
          ListTile(
            leading: const Icon(Icons.event_busy),
            title: Text(_end == null ? 'Ends: no end date' : 'Ends ${_d(_end!)}'),
            onTap: () async {
              final d = await _pick(_end ?? _start);
              if (d != null) setState(() => _end = d);
            },
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Create class')),
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('You get a code to share with students. They join with it in the app.'),
          ),
        ],
      ),
    );
  }
}

/// One class: code and details, students, attendance sheet, schedule.
class ClassDetailScreen extends StatefulWidget {
  final String sectionId;
  final TeacherRunner runner;
  const ClassDetailScreen({super.key, required this.sectionId, required this.runner});
  @override
  State<ClassDetailScreen> createState() => _ClassDetailScreenState();
}

class _ClassDetailScreenState extends State<ClassDetailScreen> {
  Map<String, dynamic>? _c;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await AppScope.read(context).api.get('/classes/${Uri.encodeComponent(widget.sectionId)}');
      if (mounted) setState(() => _c = Map<String, dynamic>.from(r));
    } catch (e) {
      if (mounted) _snack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(c?['label'] ?? ''),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: 'Class'),
              Tab(text: 'Students'),
              Tab(text: 'Attendance sheet'),
              Tab(text: 'Schedule'),
            ],
          ),
        ),
        body: c == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _OverviewTab(c: c, runner: widget.runner, reload: _load),
                  _StudentsTab(c: c, reload: _load),
                  _SheetTab(sectionId: widget.sectionId),
                  _ScheduleTab(c: c, reload: _load),
                ],
              ),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  final Map<String, dynamic> c;
  final TeacherRunner runner;
  final Future<void> Function() reload;
  const _OverviewTab({required this.c, required this.runner, required this.reload});

  String get _id => Uri.encodeComponent(c['id']);

  Future<void> _rotate(BuildContext context, String kind) async {
    try {
      await AppScope.read(context).api.post('/classes/$_id/codes', {'kind': kind});
      await reload();
    } catch (e) {
      if (context.mounted) _snack(context, e);
    }
  }

  Future<void> _editDates(BuildContext context) async {
    final start = await showDatePicker(
      context: context,
      helpText: 'Class starts',
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (start == null || !context.mounted) return;
    final end = await showDatePicker(
      context: context,
      helpText: 'Class ends',
      initialDate: start.add(const Duration(days: 120)),
      firstDate: start,
      lastDate: DateTime(2100),
    );
    if (end == null || !context.mounted) return;
    try {
      await AppScope.read(context).api.patch('/classes/$_id', {'startDate': _d(start), 'endDate': _d(end)});
      await reload();
    } catch (e) {
      if (context.mounted) _snack(context, e);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this class?'),
        content: const Text('If it already has attendance, it is archived instead: records are kept, no new classes happen.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final app = AppScope.read(context);
    final nav = Navigator.of(context);
    try {
      await app.api.delete('/classes/$_id');
      await app.refreshSchedule();
      nav.pop();
    } catch (e) {
      if (context.mounted) _snack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final codes = Map<String, dynamic>.from(c['codes'] ?? const {});
    final app = AppScope.of(context);
    Widget codeCard(String title, String? code, String help, String kind) => Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            SelectableText(code ?? '—', style: const TextStyle(fontSize: 28, letterSpacing: 4, fontWeight: FontWeight.bold)),
            Text(help, style: Theme.of(context).textTheme.bodySmall),
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                  onPressed: code == null
                      ? null
                      : () {
                          Clipboard.setData(
                            ClipboardData(
                              text: kind == 'STUDENT'
                                  ? 'Join ${c['label']} in the Exist app with code $code'
                                  : 'Co-teach ${c['label']} in Exist with code $code',
                            ),
                          );
                          _snack(context, 'Copied. Paste it in your class group.');
                        },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('New code'),
                  onPressed: () => _rotate(context, kind),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    final subject = app.subjects.where((s) => s.id == c['id']).firstOrNull;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (c['archived'] == true)
          const Card(
            child: ListTile(leading: Icon(Icons.archive), title: Text('Archived: records kept, no new classes')),
          ),
        codeCard('Class code for students', codes['student'], 'Students enter it in the app: Join a class.', 'STUDENT'),
        codeCard('Co-teacher code', codes['teacher'], 'Another teacher can use it to teach this class with you.', 'TEACHER'),
        ListTile(
          leading: const Icon(Icons.date_range),
          title: Text(c['startDate'] == null ? 'No start/end dates' : '${c['startDate']} → ${c['endDate'] ?? '…'}'),
          subtitle: const Text('Classes only happen between these dates'),
          trailing: TextButton(onPressed: () => _editDates(context), child: const Text('Change')),
        ),
        ListTile(
          leading: const Icon(Icons.people_outline),
          title: Text('Teachers: ${(c['teachers'] as List).map((t) => t['name']).join(', ')}'),
        ),
        const Divider(),
        if (c['archived'] != true)
          ListTile(
            leading: const Icon(Icons.play_arrow),
            title: const Text('Start a class now'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StartNowScreen(runner: runner, preselected: subject),
              ),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('Attendance settings'),
          subtitle: const Text('Auto-start, middle checks, how late counts…'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SectionSettingsScreen(sectionId: c['id']))),
        ),
        if ((c['teachers'] as List).length > 1)
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Stop co-teaching this class'),
            onTap: () async {
              try {
                await app.api.post('/classes/$_id/leave');
                await app.refreshSchedule();
                if (context.mounted) Navigator.pop(context);
              } catch (e) {
                if (context.mounted) _snack(context, e);
              }
            },
          ),
        ListTile(
          leading: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
          title: Text('Delete class', style: TextStyle(color: Theme.of(context).colorScheme.error)),
          onTap: () => _delete(context),
        ),
      ],
    );
  }
}

class _StudentsTab extends StatefulWidget {
  final Map<String, dynamic> c;
  final Future<void> Function() reload;
  const _StudentsTab({required this.c, required this.reload});
  @override
  State<_StudentsTab> createState() => _StudentsTabState();
}

class _StudentsTabState extends State<_StudentsTab> {
  Map<String, num> _percent = {};

  @override
  void initState() {
    super.initState();
    AppScope.read(context).api
        .get('/sections/${Uri.encodeComponent(widget.c['id'])}/students')
        .then((r) {
          if (mounted) setState(() => _percent = {for (final s in r['students'] as List) s['id'] as String: s['percent'] as num});
        })
        .catchError((Object _) {});
  }

  Future<void> _leave(Map s) async {
    final reason = TextEditingController(text: 'Medical leave');
    DateTime from = DateTime.now(), to = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Leave for ${s['name']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: reason,
                decoration: const InputDecoration(labelText: 'Reason'),
              ),
              ListTile(
                title: Text('From ${_d(from)}'),
                onTap: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: from,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) set(() => from = d);
                },
              ),
              ListTile(
                title: Text('Until ${_d(to)}'),
                onTap: () async {
                  final d = await showDatePicker(context: ctx, initialDate: to, firstDate: from, lastDate: DateTime(2100));
                  if (d != null) set(() => to = d);
                },
              ),
              const Text('Classes on these days count as excused.', style: TextStyle(fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await AppScope.read(context).api.post('/classes/${Uri.encodeComponent(widget.c['id'])}/excuse', {
        'studentId': s['id'],
        'fromDate': _d(from),
        'toDate': _d(to.isBefore(from) ? from : to),
        'reason': reason.text.trim().isEmpty ? 'leave' : reason.text.trim(),
      });
      if (mounted) _snack(context, 'Leave saved');
    } catch (e) {
      if (mounted) _snack(context, e);
    }
  }

  Future<void> _remove(Map s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${s['name']} from this class?'),
        content: const Text('Their past records stay. They can rejoin with the class code.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await AppScope.read(context).api.delete('/classes/${Uri.encodeComponent(widget.c['id'])}/students/${s['id']}');
      await widget.reload();
    } catch (e) {
      if (mounted) _snack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final students = (widget.c['students'] as List? ?? const []).cast<Map>();
    if (students.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No students yet. Share the class code.', textAlign: TextAlign.center),
        ),
      );
    }
    return ListView(
      children: [
        Padding(padding: const EdgeInsets.all(12), child: Text('${students.length} students')),
        for (final s in students)
          ListTile(
            title: Text(s['name']),
            subtitle: Text(
              [
                s['rollNo'],
                if (s['phone'] == null) 'no phone registered',
                if (s['phone']?['attestationOk'] == false) '⚠ phone failed security check',
              ].whereType<String>().join(' · '),
            ),
            leading: CircleAvatar(
              child: Text(
                _percent[s['id']] == null ? '–' : '${_percent[s['id']]!.round()}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            trailing: PopupMenuButton<String>(
              onSelected: (v) => v == 'leave' ? _leave(s) : _remove(s),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'leave', child: Text('Record leave')),
                PopupMenuItem(value: 'remove', child: Text('Remove from class')),
              ],
            ),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StudentRecordScreen(sectionId: widget.c['id'], studentId: s['id']),
              ),
            ),
          ),
      ],
    );
  }
}

/// The class register: students × class dates. Tap any cell to change it.
class _SheetTab extends StatefulWidget {
  final String sectionId;
  const _SheetTab({required this.sectionId});
  @override
  State<_SheetTab> createState() => _SheetTabState();
}

class _SheetTabState extends State<_SheetTab> {
  Map<String, dynamic>? _r;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await AppScope.read(context).api.get('/classes/${Uri.encodeComponent(widget.sectionId)}/register');
      if (mounted) setState(() => _r = Map<String, dynamic>.from(r));
    } catch (e) {
      if (mounted) _snack(context, e);
    }
  }

  Future<void> _edit(Map student, Map session, String? current) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(student['name']),
              subtitle: Text(
                '${dayLabel(session['start'], DateTime.now().millisecondsSinceEpoch)} ${hm(session['start'])} · now ${statusLabels[current] ?? '—'}',
              ),
            ),
            for (final s in const ['PRESENT', 'LATE', 'LEFT_EARLY', 'ABSENT', 'EXCUSED'])
              ListTile(leading: StatusChip(s), onTap: () => Navigator.pop(ctx, s)),
            ListTile(
              leading: const Icon(Icons.undo),
              title: const Text('Automatic (undo my change)'),
              onTap: () => Navigator.pop(ctx, 'AUTO'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      await AppScope.read(context).api.post('/sessions/${Uri.encodeComponent(session['key'])}/override', {
        'studentId': student['id'],
        'status': choice == 'AUTO' ? null : choice,
        'reason': 'edited in attendance sheet',
      });
      await _load();
    } catch (e) {
      if (mounted) _snack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    if (r == null) return const Center(child: CircularProgressIndicator());
    final sessions = (r['sessions'] as List).cast<Map>();
    final students = (r['students'] as List).cast<Map>();
    if (sessions.isEmpty) return const Center(child: Text('No classes held yet'));
    const letters = {
      'PRESENT': 'P',
      'LATE': 'L',
      'LEFT_EARLY': 'E',
      'FLAGGED': '?',
      'ABSENT': 'A',
      'EXCUSED': 'X',
      'MANUAL': 'P',
      'UNVERIFIED': 'U',
    };
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Text(
              'P present · L late · E left early · ? needs review · A absent · X excused. Tap a cell to change it.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: DataTable(
              columnSpacing: 14,
              horizontalMargin: 8,
              headingRowHeight: 44,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 40,
              columns: [
                const DataColumn(label: Text('Student')),
                const DataColumn(label: Text('%'), numeric: true),
                for (final s in sessions)
                  DataColumn(
                    label: Text(
                      '${DateTime.fromMillisecondsSinceEpoch(s['start']).day}/${DateTime.fromMillisecondsSinceEpoch(s['start']).month}',
                    ),
                  ),
              ],
              rows: [
                for (final st in students)
                  DataRow(
                    cells: [
                      DataCell(Text('${st['rollNo'] ?? ''} ${st['name']}'.trim())),
                      DataCell(Text('${st['percent']}')),
                      for (var i = 0; i < sessions.length; i++)
                        DataCell(
                          Text(
                            letters[(st['statuses'] as List)[i]] ?? '·',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: statusColor(context, (st['statuses'] as List)[i]),
                            ),
                          ),
                          onTap: () => _edit(st, sessions[i], (st['statuses'] as List)[i]),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Weekly timetable and special days (no class / test / event) of the class.
class _ScheduleTab extends StatefulWidget {
  final Map<String, dynamic> c;
  final Future<void> Function() reload;
  const _ScheduleTab({required this.c, required this.reload});
  @override
  State<_ScheduleTab> createState() => _ScheduleTabState();
}

class _ScheduleTabState extends State<_ScheduleTab> {
  List<dynamic> _events = const [];

  String get _id => Uri.encodeComponent(widget.c['id']);

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  Future<void> _loadEvents() async {
    final now = DateTime.now();
    try {
      final r = await AppScope.read(context).api.get('/me/calendar?from=${_d(now)}&to=${_d(now.add(const Duration(days: 60)))}');
      if (mounted) {
        setState(() => _events = (r['events'] as List).where((e) => (e['sectionIds'] as List).contains(widget.c['id'])).toList());
      }
    } catch (_) {}
  }

  Future<void> _addSlot() async {
    var day = 'Mon';
    TimeOfDay start = const TimeOfDay(hour: 9, minute: 30), end = const TimeOfDay(hour: 10, minute: 30);
    final room = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Weekly class'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButton<String>(
                value: day,
                items: [for (final d in _days) DropdownMenuItem(value: d, child: Text(d))],
                onChanged: (v) => set(() => day = v!),
              ),
              ListTile(
                title: Text('Starts ${start.format(ctx)}'),
                onTap: () async {
                  final t = await showTimePicker(context: ctx, initialTime: start);
                  if (t != null) set(() => start = t);
                },
              ),
              ListTile(
                title: Text('Ends ${end.format(ctx)}'),
                onTap: () async {
                  final t = await showTimePicker(context: ctx, initialTime: end);
                  if (t != null) set(() => end = t);
                },
              ),
              TextField(
                controller: room,
                decoration: const InputDecoration(labelText: 'Room (optional)'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    String fmt(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    try {
      await AppScope.read(context).api.post('/classes/$_id/timetable', {
        'day': day,
        'start': fmt(start),
        'end': fmt(end),
        if (room.text.trim().isNotEmpty) 'room': room.text.trim(),
      });
      await widget.reload();
      if (mounted) await AppScope.read(context).refreshSchedule();
    } catch (e) {
      if (mounted) _snack(context, e);
    }
  }

  Future<void> _addDay() async {
    var kind = 'HOLIDAY';
    final title = TextEditingController();
    DateTime from = DateTime.now(), to = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Special day'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'HOLIDAY', label: Text('No class')),
                  ButtonSegment(value: 'EXAM', label: Text('Test')),
                  ButtonSegment(value: 'EVENT', label: Text('Event')),
                ],
                selected: {kind},
                onSelectionChanged: (v) => set(() => kind = v.first),
              ),
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title, e.g. Holiday / Unit test 2'),
              ),
              ListTile(
                title: Text('From ${_d(from)}'),
                onTap: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: from,
                    firstDate: DateTime.now(),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) set(() => from = d);
                },
              ),
              ListTile(
                title: Text('Until ${_d(to)}'),
                onTap: () async {
                  final d = await showDatePicker(
                    context: ctx,
                    initialDate: to.isBefore(from) ? from : to,
                    firstDate: from,
                    lastDate: DateTime(2100),
                  );
                  if (d != null) set(() => to = d);
                },
              ),
              Text(
                kind == 'HOLIDAY'
                    ? 'Classes of this class are off on these days.'
                    : 'Classes still happen; students are notified.',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await AppScope.read(context).api.post('/calendar/section-event', {
        'kind': kind,
        'title': title.text.trim().isEmpty
            ? (kind == 'HOLIDAY'
                  ? 'No class'
                  : kind == 'EXAM'
                  ? 'Test'
                  : 'Event')
            : title.text.trim(),
        'fromDate': _d(from),
        'toDate': _d(to.isBefore(from) ? from : to),
        'sectionIds': [widget.c['id']],
        'noClasses': kind == 'HOLIDAY',
      });
      await _loadEvents();
      if (mounted) await AppScope.read(context).refreshSchedule();
    } catch (e) {
      if (mounted) _snack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slots = (widget.c['timetable'] as List).cast<Map>();
    final api = AppScope.read(context).api;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Row(
          children: [
            Expanded(child: Text('Every week', style: Theme.of(context).textTheme.titleSmall)),
            TextButton.icon(onPressed: _addSlot, icon: const Icon(Icons.add), label: const Text('Add')),
          ],
        ),
        if (slots.isEmpty)
          const Padding(padding: EdgeInsets.all(8), child: Text('No weekly classes. You can still start a class any time.')),
        for (final s in slots)
          ListTile(
            leading: Text(_days[(s['weekday'] as int) - 1]),
            title: Text('${_t(s['startMin'])}–${_t(s['endMin'])}'),
            subtitle: s['roomId'] != null ? Text('Room ${s['roomId']}') : null,
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await api.delete('/classes/$_id/timetable/${s['id']}');
                await widget.reload();
              },
            ),
          ),
        const Divider(height: 32),
        Row(
          children: [
            Expanded(child: Text('Special days (next 60 days)', style: Theme.of(context).textTheme.titleSmall)),
            TextButton.icon(onPressed: _addDay, icon: const Icon(Icons.add), label: const Text('Add')),
          ],
        ),
        if (_events.isEmpty)
          const Padding(padding: EdgeInsets.all(8), child: Text('None. Add holidays, tests or events for this class.')),
        for (final e in _events)
          ListTile(
            leading: Icon(e['kind'] == 'HOLIDAY' || e['noClasses'] == true ? Icons.event_busy : Icons.event_note),
            title: Text(e['title']),
            subtitle: Text(
              '${e['fromDate']}${e['toDate'] != e['fromDate'] ? ' → ${e['toDate']}' : ''}${e['noClasses'] == true ? ' · no class' : ''}',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await api.delete('/calendar/section-event/${e['id']}');
                await _loadEvents();
              },
            ),
          ),
      ],
    );
  }
}

/// Students' new phones waiting for approval (otherwise automatic after 48 h).
class PhoneRequestsScreen extends StatefulWidget {
  const PhoneRequestsScreen({super.key});
  @override
  State<PhoneRequestsScreen> createState() => _PhoneRequestsScreenState();
}

class _PhoneRequestsScreenState extends State<PhoneRequestsScreen> {
  List<dynamic>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await AppScope.read(context).api.get('/teacher/device-requests') as List;
    if (mounted) setState(() => _items = r);
  }

  Future<void> _decide(Map r, bool approve) async {
    try {
      await AppScope.read(context).api.post('/teacher/device-requests/${r['id']}', {'approve': approve});
      await _load();
    } catch (e) {
      if (mounted) _snack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('New phones')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? const Center(child: Text('Nothing to approve'))
          : ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'A student asked to move their account to a new phone. It happens automatically after 48 hours; approve now if you know it is really them.',
                  ),
                ),
                for (final r in items)
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${r['user']?['name'] ?? ''} · ${r['user']?['rollNo'] ?? ''}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text('Old: ${r['current']?['model'] ?? r['current']?['platform'] ?? '—'}   New: ${r['model'] ?? '—'}'),
                          if (r['likelySamePhone'] == true) const Text('Probably the same phone, reinstalled'),
                          if (r['attestationOk'] == false) const Text('⚠ New phone failed the security check'),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(onPressed: () => _decide(r, false), child: const Text('Reject')),
                              FilledButton(onPressed: () => _decide(r, true), child: const Text('Approve')),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
