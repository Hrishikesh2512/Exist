import 'package:flutter/material.dart';

import '../core/app_state.dart';

/// Announce an extra class. Needs internet: students' phones must learn about it in
/// advance so they can wake up for it.
class ExtraClassScreen extends StatefulWidget {
  const ExtraClassScreen({super.key});
  @override
  State<ExtraClassScreen> createState() => _ExtraClassScreenState();
}

class _ExtraClassScreenState extends State<ExtraClassScreen> {
  final _title = TextEditingController();
  final Set<String> _sections = {};
  DateTime _date = DateTime.now();
  TimeOfDay _time = TimeOfDay.fromDateTime(DateTime.now().add(const Duration(minutes: 30)));
  int _minutes = 60;
  bool _busy = false;

  Future<void> _save() async {
    final app = AppScope.read(context);
    final start = DateTime(_date.year, _date.month, _date.day, _time.hour, _time.minute);
    setState(() => _busy = true);
    try {
      await app.api.post('/sessions/adhoc', {
        'sectionIds': _sections.toList(),
        if (_title.text.trim().isNotEmpty) 'title': _title.text.trim(),
        'scheduledStart': start.millisecondsSinceEpoch,
        'scheduledEnd': start.add(Duration(minutes: _minutes)).millisecondsSinceEpoch,
      });
      await app.refreshSchedule();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final sections = app.roster.keys.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: const Text('Extra class')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title (optional)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          const Text('Sections'),
          Wrap(
            spacing: 8,
            children: [
              for (final s in sections)
                FilterChip(
                  label: Text(s),
                  selected: _sections.contains(s),
                  onSelected: (v) => setState(() => v ? _sections.add(s) : _sections.remove(s)),
                ),
            ],
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.event),
            title: Text('${_date.day}/${_date.month}/${_date.year}'),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime.now(),
                lastDate: DateTime.now().add(const Duration(days: 30)),
              );
              if (d != null) setState(() => _date = d);
            },
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: Text(_time.format(context)),
            onTap: () async {
              final t = await showTimePicker(context: context, initialTime: _time);
              if (t != null) setState(() => _time = t);
            },
          ),
          ListTile(
            leading: const Icon(Icons.timelapse),
            title: Text('$_minutes minutes'),
            trailing: DropdownButton<int>(
              value: _minutes,
              items: [
                for (final m in [30, 45, 60, 90, 120, 180]) DropdownMenuItem(value: m, child: Text('$m')),
              ],
              onChanged: (v) => setState(() => _minutes = v!),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _busy || _sections.isEmpty ? null : _save, child: const Text('Announce to students')),
        ],
      ),
    );
  }
}
