import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/format.dart';

/// Final (server-verified) attendance for a class, with review tools.
class ResultsScreen extends StatefulWidget {
  final String sessionKey, title;
  const ResultsScreen({super.key, required this.sessionKey, required this.title});
  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  bool _onlyReview = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await AppScope.read(context).api.get('/sessions/${Uri.encodeComponent(widget.sessionKey)}');
      setState(() {
        _data = Map<String, dynamic>.from(d);
        _error = null;
      });
    } catch (e) {
      setState(
        () => _error = e.toString() == 'session not found'
            ? 'Not uploaded yet. Results appear once this phone has internet.'
            : e.toString(),
      );
    }
  }

  Future<void> _act(Map<String, dynamic> st) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(st['name']), subtitle: Text((st['reasons'] as List).join(' · '))),
            for (final s in const ['PRESENT', 'LATE', 'LEFT_EARLY', 'ABSENT', 'EXCUSED'])
              ListTile(leading: StatusChip(s), onTap: () => Navigator.pop(ctx, s)),
            ListTile(
              leading: const Icon(Icons.phonelink_erase),
              title: const Text('Was in class without a working phone'),
              onTap: () => Navigator.pop(ctx, 'MANUAL'),
            ),
            if (st['overridden'] == true)
              ListTile(
                leading: const Icon(Icons.undo),
                title: const Text('Undo my change'),
                onTap: () => Navigator.pop(ctx, 'RESET'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final api = AppScope.read(context).api;
    final key = Uri.encodeComponent(widget.sessionKey);
    try {
      if (choice == 'MANUAL') {
        final r = await api.post('/sessions/$key/manual', {'studentId': st['id'], 'reason': 'seen in class without phone'});
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Marked. ${r['used']}/${r['quota']} of this student\'s allowance used.')));
        }
      } else {
        await api.post('/sessions/$key/override', {
          'studentId': st['id'],
          'status': choice == 'RESET' ? null : choice,
          'reason': 'teacher review',
        });
      }
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// Whole-class decision, e.g. a field trip. Only touches students not already present.
  Future<void> _bulk(String status) async {
    final reason = TextEditingController(text: status == 'PRESENT' ? 'Field trip / activity outside class' : 'Class excused');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(status == 'PRESENT' ? 'Mark everyone present?' : 'Excuse everyone?'),
        content: TextField(
          controller: reason,
          decoration: const InputDecoration(labelText: 'Reason (recorded)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Apply')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await AppScope.read(context).api.post('/sessions/${Uri.encodeComponent(widget.sessionKey)}/bulk', {
        'status': status,
        'reason': reason.text.trim().isEmpty ? 'teacher decision' : reason.text.trim(),
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['updated']} students updated')));
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final students = (d?['students'] as List? ?? []).cast<Map<String, dynamic>>();
    final review = students.where((s) => s['status'] == 'FLAGGED' || s['status'] == 'UNVERIFIED').toList();
    final shown = _onlyReview ? review : students;
    final counts = <String, int>{};
    for (final s in students) {
      counts[s['status']] = (counts[s['status']] ?? 0) + 1;
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (d != null)
            PopupMenuButton<String>(
              onSelected: _bulk,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'PRESENT', child: Text('Mark everyone not present as present')),
                PopupMenuItem(value: 'EXCUSED', child: Text('Excuse everyone not present')),
              ],
            ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
          : d == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final e in counts.entries) Chip(label: Text('${statusLabels[e.key] ?? e.key}: ${e.value}')),
                      ],
                    ),
                  ),
                  if (review.isNotEmpty)
                    SwitchListTile(
                      value: _onlyReview,
                      onChanged: (v) => setState(() => _onlyReview = v),
                      title: Text('Only show ${review.length} needing review'),
                    ),
                  for (final st in shown)
                    ListTile(
                      title: Text(st['name']),
                      subtitle: Text([st['rollNo'], ...(st['reasons'] as List)].whereType<String>().join(' · ')),
                      trailing: StatusChip(st['status']),
                      onTap: () => _act(st),
                    ),
                ],
              ),
            ),
    );
  }
}
