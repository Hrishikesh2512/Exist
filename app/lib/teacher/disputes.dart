import 'package:flutter/material.dart';

import '../core/app_state.dart';

class DisputesScreen extends StatefulWidget {
  const DisputesScreen({super.key});
  @override
  State<DisputesScreen> createState() => _DisputesScreenState();
}

class _DisputesScreenState extends State<DisputesScreen> {
  List<dynamic>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await AppScope.read(context).api.get('/disputes');
      setState(() => _items = r as List);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _resolve(Map d, bool accept) async {
    try {
      await AppScope.read(context).api.post('/disputes/${d['id']}/resolve', {
        'accept': accept,
        'resolution': accept ? 'Accepted by teacher' : 'Rejected by teacher',
      });
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: const Text('Disputes')),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? const Center(child: Text('No open disputes'))
          : ListView(
              children: [
                for (final d in items)
                  Card(
                    margin: const EdgeInsets.all(8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(d['message']),
                          Text('Student ${d['studentId']}', style: Theme.of(context).textTheme.bodySmall),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(onPressed: () => _resolve(d, false), child: const Text('Reject')),
                              FilledButton(onPressed: () => _resolve(d, true), child: const Text('Mark present')),
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
