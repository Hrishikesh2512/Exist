import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/format.dart';

/// My attendance sheet for one class: every class held, with my status and why.
class StudentSheetScreen extends StatefulWidget {
  final String sectionId, title;
  const StudentSheetScreen({super.key, required this.sectionId, required this.title});
  @override
  State<StudentSheetScreen> createState() => _StudentSheetScreenState();
}

class _StudentSheetScreenState extends State<StudentSheetScreen> {
  Map<String, dynamic>? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await AppScope.read(context).api.get('/me/classes/${Uri.encodeComponent(widget.sectionId)}/sheet');
      if (mounted) setState(() => _d = Map<String, dynamic>.from(r));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _dispute(Map r) async {
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This is wrong'),
        content: TextField(
          controller: c,
          maxLines: 3,
          decoration: const InputDecoration(hintText: 'Tell your teacher what happened'),
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
      await AppScope.read(context).api.post('/disputes', {'sessionKey': r['sessionKey'], 'message': c.text});
      m.showSnackBar(const SnackBar(content: Text('Sent to your teacher')));
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final records = (d?['records'] as List? ?? const []).cast<Map>();
    final counts = <String, int>{};
    for (final r in records) {
      counts[r['status']] = (counts[r['status']] ?? 0) + 1;
    }
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _error != null
          ? Center(child: Text(_error!))
          : d == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Text('${d['percent'] ?? '—'}%', style: Theme.of(context).textTheme.displaySmall),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final e in counts.entries) Chip(label: Text('${statusLabels[e.key] ?? e.key}: ${e.value}')),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  if (records.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No classes held yet')),
                  for (final r in records)
                    ListTile(
                      title: Text(
                        '${dayLabel(r['start'], DateTime.now().millisecondsSinceEpoch)} · ${hm(r['start'])}${r['title'] != null ? ' · ${r['title']}' : ''}',
                      ),
                      subtitle: Text(
                        [...(r['reasons'] as List).cast<String>(), if (r['overridden'] == true) 'set by teacher'].join(' · '),
                      ),
                      trailing: StatusChip(r['status']),
                      onLongPress: () => _dispute(r),
                      onTap: r['status'] == 'PRESENT' || r['status'] == 'EXCUSED' ? null : () => _dispute(r),
                    ),
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Tap a wrong entry to tell your teacher (within 3 days).', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
    );
  }
}
