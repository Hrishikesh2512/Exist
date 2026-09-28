import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'format.dart';

/// Month calendar: classes (with my attendance), holidays, exams, events, day swaps.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

String _mm(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const _kindColors = {'HOLIDAY': Colors.red, 'EXAM': Colors.purple, 'EVENT': Colors.blue, 'DAY_ORDER': Colors.teal};
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

class _CalendarScreenState extends State<CalendarScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime _selected = DateTime.now();
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final from = _month;
    final to = DateTime(_month.year, _month.month + 1, 0);
    try {
      final d = await AppScope.read(context).api.get('/me/calendar?from=${_d(from)}&to=${_d(to)}');
      if (mounted) {
        setState(() {
          _data = Map<String, dynamic>.from(d);
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  List<Map<String, dynamic>> _eventsOn(String day) => [
    for (final e in (_data?['events'] as List? ?? const []))
      if ((e['fromDate'] as String).compareTo(day) <= 0 && (e['toDate'] as String).compareTo(day) >= 0)
        Map<String, dynamic>.from(e),
  ];

  List<Map<String, dynamic>> _classesOn(String day) => [
    for (final s in (_data?['sessions'] as List? ?? const []))
      if (_d(DateTime.fromMillisecondsSinceEpoch(s['scheduledStart'])) == day) Map<String, dynamic>.from(s),
  ];

  void _shift(int months) {
    setState(() {
      _month = DateTime(_month.year, _month.month + months);
      _data = null;
    });
    _load();
  }

  Future<void> _subscribe() async {
    final app = AppScope.read(context);
    try {
      final r = await app.api.get('/me/calendar-link');
      final url = '${app.api.baseUrl}${r['path']}';
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Add to your calendar'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'In Google Calendar: Other calendars → From URL. On iPhone: Settings → Calendar → Accounts → Add Subscribed Calendar.',
              ),
              const SizedBox(height: 12),
              SelectableText(url, style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              const Text('Keep this link private. It shows your classes.', style: TextStyle(fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final r2 = await app.api.post('/me/calendar-link/reset');
                await Clipboard.setData(ClipboardData(text: '${app.api.baseUrl}${r2['path']}'));
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('New link'),
            ),
            FilledButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Copy link'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// My own entry (study plan, reminder). Only I see it.
  Future<void> _addPersonal() async {
    final title = TextEditingController(), note = TextEditingController();
    TimeOfDay? start, end;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('Add to ${_d(_selected)}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'What, e.g. Revise chapter 3'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  start == null ? 'All day' : 'From ${start!.format(ctx)}${end != null ? ' to ${end!.format(ctx)}' : ''}',
                ),
                trailing: const Icon(Icons.schedule),
                onTap: () async {
                  final s = await showTimePicker(
                    context: ctx,
                    initialTime: const TimeOfDay(hour: 18, minute: 0),
                    helpText: 'Starts',
                  );
                  if (s == null) return;
                  if (!ctx.mounted) return;
                  final e = await showTimePicker(
                    context: ctx,
                    initialTime: TimeOfDay(hour: (s.hour + 1) % 24, minute: s.minute),
                    helpText: 'Ends',
                  );
                  set(() {
                    start = s;
                    end = e;
                  });
                },
              ),
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
              ),
              const SizedBox(height: 8),
              const Text('Only you can see this.', style: TextStyle(fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || title.text.trim().isEmpty || !mounted) return;
    String fmt(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    try {
      await AppScope.read(context).api.post('/me/events', {
        'title': title.text.trim(),
        'date': _d(_selected),
        if (start != null) 'start': fmt(start!),
        if (start != null && end != null && (end!.hour * 60 + end!.minute) > (start!.hour * 60 + start!.minute)) 'end': fmt(end!),
        if (note.text.trim().isNotEmpty) 'note': note.text.trim(),
      });
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  List<Map<String, dynamic>> _personalOn(String day) => [
    for (final e in (_data?['personal'] as List? ?? const []))
      if (e['date'] == day) Map<String, dynamic>.from(e),
  ];

  @override
  Widget build(BuildContext context) {
    final first = _month;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final lead = first.weekday - 1;
    final today = _d(DateTime.now());
    final sel = _d(_selected);
    const names = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar'),
        actions: [IconButton(tooltip: 'Add to Google/Apple Calendar', icon: const Icon(Icons.ios_share), onPressed: _subscribe)],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addPersonal,
        icon: const Icon(Icons.edit_calendar),
        label: const Text('Add to my calendar'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Row(
              children: [
                IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
                Expanded(
                  child: Text(
                    '${names[_month.month - 1]} ${_month.year}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(onPressed: () => _shift(1), icon: const Icon(Icons.chevron_right)),
              ],
            ),
            Row(
              children: [
                for (final w in _weekdays)
                  Expanded(
                    child: Center(child: Text(w, style: Theme.of(context).textTheme.labelSmall)),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 0.9,
              children: [
                for (var i = 0; i < lead; i++) const SizedBox(),
                for (var day = 1; day <= daysInMonth; day++) _cell(DateTime(_month.year, _month.month, day), today, sel),
              ],
            ),
            if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!)),
            if (_data == null && _error == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            const Divider(height: 24),
            Text(
              '${dayLabel(_selected.millisecondsSinceEpoch, DateTime.now().millisecondsSinceEpoch)}, ${_selected.day} ${names[_selected.month - 1]}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            for (final e in _eventsOn(sel))
              ListTile(
                dense: true,
                leading: Icon(Icons.circle, size: 12, color: _kindColors[e['kind']]),
                title: Text(e['title']),
                subtitle: Text(switch (e['kind']) {
                  'HOLIDAY' => 'Holiday · no classes',
                  'EXAM' => e['noClasses'] == true ? 'Exams · no classes' : 'Test',
                  'DAY_ORDER' =>
                    'Runs ${const ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'][e['followsWeekday'] ?? 0]}\'s timetable',
                  _ => e['noClasses'] == true ? 'Event · no classes' : 'Event',
                }),
              ),
            for (final s in _classesOn(sel))
              ListTile(
                dense: true,
                leading: Text(hm(s['scheduledStart'])),
                title: Text((s['label'] ?? s['title'] ?? (s['sectionIds'] as List).join(' + ')) as String),
                subtitle: Text(
                  [
                    s['roomId'],
                    s['teacherName'],
                    if (s['state'] == 'CANCELLED') 'cancelled${s['cancelReason'] != null ? ': ${s['cancelReason']}' : ''}',
                  ].whereType<String>().join(' · '),
                ),
                trailing: s['myStatus'] != null ? StatusChip(s['myStatus']) : null,
              ),
            for (final e in _personalOn(sel))
              ListTile(
                dense: true,
                leading: const Icon(Icons.person_pin_circle_outlined, size: 20),
                title: Text(e['title']),
                subtitle: Text(
                  [
                    e['startMin'] == null
                        ? 'All day'
                        : '${_mm(e['startMin'])}${e['endMin'] != null ? '–${_mm(e['endMin'])}' : ''}',
                    if (e['note'] != null) e['note'],
                    'only you',
                  ].join(' · '),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await AppScope.read(context).api.delete('/me/events/${e['id']}');
                    await _load();
                  },
                ),
              ),
            if (_eventsOn(sel).isEmpty && _classesOn(sel).isEmpty && _personalOn(sel).isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('Nothing on this day')),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  Widget _cell(DateTime date, String today, String sel) {
    final key = _d(date);
    final events = _eventsOn(key);
    final classes = _classesOn(key).where((c) => c['state'] != 'CANCELLED').toList();
    final statuses = classes.map((c) => c['myStatus']).whereType<String>().toList();
    final bad = statuses.any((s) => s == 'ABSENT' || s == 'FLAGGED');
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _selected = date),
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: key == sel ? cs.primaryContainer : null,
          border: key == today ? Border.all(color: cs.primary) : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${date.day}',
              style: TextStyle(
                color: events.any((e) => e['kind'] == 'HOLIDAY') ? Colors.red : null,
                fontWeight: key == today ? FontWeight.bold : null,
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final e in events.take(2)) _dot(_kindColors[e['kind']] ?? cs.outline),
                if (_personalOn(key).isNotEmpty) _dot(Colors.orange),
                if (classes.isNotEmpty) _dot(statuses.isEmpty ? cs.primary : (bad ? cs.error : Colors.green)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color c) => Container(
    width: 6,
    height: 6,
    margin: const EdgeInsets.symmetric(horizontal: 1),
    decoration: BoxDecoration(color: c, shape: BoxShape.circle),
  );
}
