import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/models.dart';
import 'runner.dart';
import 'session_screen.dart';

/// Take a class right now for any subject you teach, with or without a timetable slot.
/// Works offline. Only students of the chosen subject(s) can check in.
class StartNowScreen extends StatefulWidget {
  final TeacherRunner runner;
  final Subject? preselected;
  const StartNowScreen({super.key, required this.runner, this.preselected});
  @override
  State<StartNowScreen> createState() => _StartNowScreenState();
}

class _StartNowScreenState extends State<StartNowScreen> {
  final Set<String> _chosen = {};
  int _minutes = 60;
  final _title = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.preselected != null) _chosen.add(widget.preselected!.id);
  }

  Future<void> _start() async {
    final app = AppScope.read(context);
    final subjects = app.subjects.where((s) => _chosen.contains(s.id)).toList();
    setState(() => _busy = true);
    try {
      await widget.runner.startNow(
        subjects: subjects,
        minutes: _minutes,
        title: _title.text.trim().isEmpty ? null : _title.text.trim(),
      );
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => SessionScreen(runner: widget.runner)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final subjects = app.subjects;
    final rosterSize = <String>{
      for (final id in _chosen)
        for (final r in app.roster[id] ?? const <RosterEntry>[]) r.id,
    }.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Start a class now')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Subject'),
          if (subjects.isEmpty)
            const Padding(padding: EdgeInsets.all(12), child: Text('No subjects assigned to you this semester. Ask the admin.')),
          for (final s in subjects)
            CheckboxListTile(
              value: _chosen.contains(s.id),
              onChanged: (v) => setState(() => v == true ? _chosen.add(s.id) : _chosen.remove(s.id)),
              title: Text(s.label),
              subtitle: Text('${s.code ?? s.id} · ${(app.roster[s.id] ?? const []).length} students'),
            ),
          if (_chosen.length > 1)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('Combined class: students of all chosen groups.'),
            ),
          const SizedBox(height: 12),
          const Text('Length'),
          Wrap(
            spacing: 8,
            children: [
              for (final m in const [30, 45, 60, 90, 120, 180])
                ChoiceChip(
                  label: Text(m < 60 ? '$m min' : '${m / 60} h'.replaceAll('.0', '')),
                  selected: _minutes == m,
                  onSelected: (_) => setState(() => _minutes = m),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _title,
            decoration: const InputDecoration(labelText: 'Title (optional), e.g. Extra class', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _chosen.isEmpty || _busy ? null : _start,
            icon: const Icon(Icons.play_arrow),
            label: Text(_chosen.isEmpty ? 'Choose a subject' : 'Start now · $rosterSize students'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Works without internet. Students\' phones in the room check in by themselves; students of other subjects cannot.',
            ),
          ),
        ],
      ),
    );
  }
}
