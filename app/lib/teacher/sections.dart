import 'package:flutter/material.dart';

import '../core/app_state.dart';
import 'runner.dart';
import 'start_now.dart';
import 'subject_students.dart';

/// Teacher's sections: attendance at a glance, students at risk, and per-section settings.
class SectionsScreen extends StatefulWidget {
  final TeacherRunner? runner;
  const SectionsScreen({super.key, this.runner});
  @override
  State<SectionsScreen> createState() => _SectionsScreenState();
}

class _SectionsScreenState extends State<SectionsScreen> {
  List<dynamic>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await AppScope.read(context).api.get('/teacher/sections');
      if (mounted) setState(() => _items = r as List);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('My subjects')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final s in items)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s['course'] != null ? s['course']['name'] : s['sectionId'],
                                        style: Theme.of(context).textTheme.titleMedium,
                                      ),
                                      Text(
                                        '${s['course']?['code'] ?? ''} · ${s['sectionId']}',
                                        style: Theme.of(context).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                Text(
                                  s['averagePercent'] == null ? '—' : '${s['averagePercent']}%',
                                  style: Theme.of(context).textTheme.headlineSmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text('${s['students']} students · ${s['classesHeld']} classes held'),
                            if ((s['atRisk'] as List).isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Below requirement',
                                style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w600),
                              ),
                              for (final st in s['atRisk'] as List)
                                Text('${st['rollNo'] ?? ''}  ${st['name']}  ${st['percent']}%'),
                            ],
                            Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 4,
                              children: [
                                TextButton.icon(
                                  icon: const Icon(Icons.people),
                                  label: const Text('Students'),
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => SubjectStudentsScreen(
                                        sectionId: s['sectionId'],
                                        title: s['course'] != null ? s['course']['name'] : s['sectionId'],
                                      ),
                                    ),
                                  ),
                                ),
                                if (widget.runner != null)
                                  TextButton.icon(
                                    icon: const Icon(Icons.play_arrow),
                                    label: const Text('Start class'),
                                    onPressed: () {
                                      final subj = AppScope.read(
                                        context,
                                      ).subjects.where((x) => x.id == s['sectionId']).firstOrNull;
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => StartNowScreen(runner: widget.runner!, preselected: subj),
                                        ),
                                      );
                                    },
                                  ),
                                TextButton.icon(
                                  icon: const Icon(Icons.tune),
                                  label: const Text('Settings'),
                                  onPressed: () async {
                                    await Navigator.push(
                                      context,
                                      MaterialPageRoute(builder: (_) => SectionSettingsScreen(sectionId: s['sectionId'])),
                                    );
                                    _load();
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class SectionSettingsScreen extends StatefulWidget {
  final String sectionId;
  const SectionSettingsScreen({super.key, required this.sectionId});
  @override
  State<SectionSettingsScreen> createState() => _SectionSettingsScreenState();
}

class _SectionSettingsScreenState extends State<SectionSettingsScreen> {
  Map<String, dynamic>? _defaults;
  bool _autoStart = true;
  int? _midChecks; // null = automatic
  int? _startWindow, _endWindow, _manualQuota;
  double? _lateWeight, _leftEarlyWeight;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await AppScope.read(context).api.get('/sections/${Uri.encodeComponent(widget.sectionId)}/settings');
    final s = r['stored'] as Map?;
    if (!mounted) return;
    setState(() {
      _defaults = Map<String, dynamic>.from(r['defaults']);
      _autoStart = s?['autoStart'] ?? true;
      _midChecks = s?['midChecks'];
      _startWindow = s?['startWindowMin'];
      _endWindow = s?['endWindowMin'];
      _manualQuota = s?['manualQuota'];
      _lateWeight = (s?['lateWeight'] as num?)?.toDouble();
      _leftEarlyWeight = (s?['leftEarlyWeight'] as num?)?.toDouble();
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final app = AppScope.read(context);
    try {
      await _put();
      await app.refreshSchedule();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _put() => AppScope.read(context).api.put('/sections/${Uri.encodeComponent(widget.sectionId)}/settings', {
    'autoStart': _autoStart,
    'midChecks': _midChecks,
    'startWindowMin': _startWindow,
    'endWindowMin': _endWindow,
    'manualQuota': _manualQuota,
    'lateWeight': _lateWeight,
    'leftEarlyWeight': _leftEarlyWeight,
  });

  Widget _weight(String label, double? value, double def, ValueChanged<double?> onChanged) => ListTile(
    title: Text(label),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SegmentedButton<double?>(
        segments: [
          ButtonSegment(value: null, label: Text('Default (${(def * 100).round()}%)')),
          const ButtonSegment(value: 1, label: Text('100%')),
          const ButtonSegment(value: 0.5, label: Text('50%')),
          const ButtonSegment(value: 0, label: Text('0%')),
        ],
        selected: {value},
        onSelectionChanged: (v) => setState(() => onChanged(v.first)),
      ),
    ),
  );

  Widget _minutes(String label, int? value, int def, int min, int max, ValueChanged<int?> onChanged) => ListTile(
    title: Text('$label: ${value ?? def} min${value == null ? ' (default)' : ''}'),
    subtitle: Slider(
      value: (value ?? def).toDouble(),
      min: min.toDouble(),
      max: max.toDouble(),
      divisions: max - min,
      onChanged: (v) => setState(() => onChanged(v.round() == def ? null : v.round())),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final d = _defaults;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.sectionId} settings')),
      body: d == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                SwitchListTile(
                  value: _autoStart,
                  onChanged: (v) => setState(() => _autoStart = v),
                  title: const Text('Start classes automatically'),
                  subtitle: const Text('Off: you tap Start yourself'),
                ),
                ListTile(
                  title: const Text('Random middle checks'),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SegmentedButton<int?>(
                      segments: const [
                        ButtonSegment(value: null, label: Text('Auto')),
                        ButtonSegment(value: 0, label: Text('0')),
                        ButtonSegment(value: 1, label: Text('1')),
                        ButtonSegment(value: 2, label: Text('2')),
                        ButtonSegment(value: 3, label: Text('3')),
                      ],
                      selected: {_midChecks},
                      onSelectionChanged: (v) => setState(() => _midChecks = v.first),
                    ),
                  ),
                ),
                _minutes('Start check open for', _startWindow, d['startWindowMin'], 5, 30, (v) => _startWindow = v),
                _minutes('End check: last', _endWindow, d['endWindowMin'], 3, 20, (v) => _endWindow = v),
                _weight('"Late" counts as', _lateWeight, (d['weights']['LATE'] as num).toDouble(), (v) => _lateWeight = v),
                _weight(
                  '"Left early" counts as',
                  _leftEarlyWeight,
                  (d['weights']['LEFT_EARLY'] as num).toDouble(),
                  (v) => _leftEarlyWeight = v,
                ),
                ListTile(
                  title: Text(
                    '"Present without phone" allowance: ${_manualQuota ?? d['manualQuota']} per term${_manualQuota == null ? ' (default)' : ''}',
                  ),
                  subtitle: Slider(
                    value: (_manualQuota ?? d['manualQuota'] as int).toDouble(),
                    min: 0,
                    max: 10,
                    divisions: 10,
                    onChanged: (v) => setState(() => _manualQuota = v.round() == d['manualQuota'] ? null : v.round()),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Changes apply from the next class. A class that is running keeps its settings.'),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(onPressed: _saving ? null : _save, child: const Text('Save')),
                ),
              ],
            ),
    );
  }
}
