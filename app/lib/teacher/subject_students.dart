import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/format.dart';

/// All students of one subject group with their attendance; tap for their full record.
class SubjectStudentsScreen extends StatefulWidget {
  final String sectionId;
  final String title;
  const SubjectStudentsScreen({super.key, required this.sectionId, required this.title});
  @override
  State<SubjectStudentsScreen> createState() => _SubjectStudentsScreenState();
}

class _SubjectStudentsScreenState extends State<SubjectStudentsScreen> {
  Map<String, dynamic>? _data;
  String _q = '';
  bool _lowFirst = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await AppScope.read(context).api.get('/sections/${Uri.encodeComponent(widget.sectionId)}/students');
      if (mounted) setState(() => _data = Map<String, dynamic>.from(d));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final threshold = 75.0;
    var students = (d?['students'] as List? ?? const []).cast<Map<String, dynamic>>();
    if (_q.isNotEmpty) {
      students = students.where((s) => '${s['name']} ${s['rollNo'] ?? ''}'.toLowerCase().contains(_q.toLowerCase())).toList();
    }
    if (_lowFirst) students = [...students]..sort((a, b) => (a['percent'] as num).compareTo(b['percent'] as num));
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text('${d['classesHeld']} classes held · ${(d['students'] as List).length} students'),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search),
                              hintText: 'Name or roll no',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (v) => setState(() => _q = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilterChip(
                          label: const Text('Lowest first'),
                          selected: _lowFirst,
                          onSelected: (v) => setState(() => _lowFirst = v),
                        ),
                      ],
                    ),
                  ),
                  for (final s in students)
                    ListTile(
                      title: Text(s['name']),
                      subtitle: Text('${s['rollNo'] ?? ''}  ·  ${s['attended']}/${s['counted']} classes'),
                      trailing: Text(
                        '${s['percent']}%',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: (s['percent'] as num) < threshold ? Theme.of(context).colorScheme.error : Colors.green.shade700,
                        ),
                      ),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => StudentRecordScreen(sectionId: widget.sectionId, studentId: s['id']),
                          ),
                        );
                        _load();
                      },
                    ),
                ],
              ),
            ),
    );
  }
}

/// One student's record in one subject, class by class. The teacher can change any entry.
class StudentRecordScreen extends StatefulWidget {
  final String sectionId, studentId;
  const StudentRecordScreen({super.key, required this.sectionId, required this.studentId});
  @override
  State<StudentRecordScreen> createState() => _StudentRecordScreenState();
}

class _StudentRecordScreenState extends State<StudentRecordScreen> {
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await AppScope.read(
      context,
    ).api.get('/sections/${Uri.encodeComponent(widget.sectionId)}/students/${widget.studentId}');
    if (mounted) setState(() => _data = Map<String, dynamic>.from(d));
  }

  Future<void> _edit(Map<String, dynamic> r) async {
    final reason = TextEditingController();
    String? chosen;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('${dayLabel(r['start'], DateTime.now().millisecondsSinceEpoch)} ${hm(r['start'])}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Now: ${statusLabels[r['status']] ?? r['status']}${r['overridden'] == true ? ' (changed by teacher)' : ''}'),
              if ((r['reasons'] as List).isNotEmpty)
                Text((r['reasons'] as List).join(', '), style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in const ['PRESENT', 'LATE', 'LEFT_EARLY', 'ABSENT', 'EXCUSED'])
                    ChoiceChip(label: Text(statusLabels[s]!), selected: chosen == s, onSelected: (_) => set(() => chosen = s)),
                  if (r['overridden'] == true)
                    ChoiceChip(
                      label: const Text('Automatic'),
                      selected: chosen == 'AUTO',
                      onSelected: (_) => set(() => chosen = 'AUTO'),
                    ),
                ],
              ),
              TextField(
                controller: reason,
                decoration: const InputDecoration(labelText: 'Reason (recorded)'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true || chosen == null || !mounted) return;
    try {
      await AppScope.read(context).api.post('/sessions/${Uri.encodeComponent(r['sessionKey'])}/override', {
        'studentId': widget.studentId,
        'status': chosen == 'AUTO' ? null : chosen,
        'reason': reason.text.trim().isEmpty ? 'changed by teacher' : reason.text.trim(),
      });
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _resetPassword() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset password?'),
        content: const Text(
          'For a student who forgot it. You will get a temporary password to give them; they must change it at next sign-in.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await AppScope.read(context).api.post('/users/${widget.studentId}/reset-password');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Temporary password'),
          content: SelectableText(r['temporaryPassword'], style: const TextStyle(fontSize: 24, letterSpacing: 2)),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))],
        ),
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(
        title: Text(d?['student']?['name'] ?? ''),
        actions: [IconButton(tooltip: 'Reset password', icon: const Icon(Icons.lock_reset), onPressed: _resetPassword)],
      ),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                ListTile(
                  title: Text('Roll ${d['student']['rollNo'] ?? '—'}'),
                  trailing: Text('${d['percent'] ?? '—'}%', style: Theme.of(context).textTheme.headlineSmall),
                ),
                const Divider(),
                if ((d['records'] as List).isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No classes yet')),
                for (final r in (d['records'] as List).cast<Map<String, dynamic>>())
                  ListTile(
                    title: Text(
                      '${dayLabel(r['start'], DateTime.now().millisecondsSinceEpoch)} · ${hm(r['start'])}${r['title'] != null ? ' · ${r['title']}' : ''}',
                    ),
                    subtitle: Text(
                      [
                        ...(r['reasons'] as List).cast<String>(),
                        if (r['overridden'] == true) 'changed: ${r['overrideReason'] ?? ''}',
                      ].join(' · '),
                    ),
                    trailing: StatusChip(r['status']),
                    onTap: () => _edit(r),
                  ),
              ],
            ),
    );
  }
}
