import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../domain/plan.dart';
import '../protocol/protocol.dart';
import 'runner.dart';

/// Live class view. Shows who has checked in for each check, without revealing when the
/// secret middle check will happen.
class SessionScreen extends StatelessWidget {
  final TeacherRunner runner;
  const SessionScreen({super.key, required this.runner});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return ListenableBuilder(
      listenable: runner,
      builder: (context, _) {
        if (!runner.running) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Class ended. Attendance is being uploaded.')),
          );
        }
        final s = runner.session!;
        final now = app.now();
        final view = runner.liveView();
        final ph = runner.phase;
        final arrived = runner.roster.where((r) => runner.hasArrived(r.id)).length;
        final opened = view.windows.where((w) => w.from <= now).toList();
        final ending = runner.stopAdvertisingAt != null;
        return Scaffold(
          appBar: AppBar(title: Text(s.label)),
          body: Column(
            children: [
              Container(
                width: double.infinity,
                color: Theme.of(context).colorScheme.primaryContainer,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.sensors),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            runner.paused
                                ? 'Paused. Attendance is not being taken'
                                : ending
                                ? 'Final check open until ${hm(runner.stopAdvertisingAt!)}'
                                : switch (ph.phase) {
                                    Phase.mid =>
                                      ph.index >= surpriseIndex ? 'Surprise check in progress' : 'Middle check in progress',
                                    Phase.end => 'End check in progress',
                                    Phase.arrive => 'Taking attendance',
                                  },
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('$arrived of ${runner.roster.length} arrived · ends ${hm(runner.plannedEnd)}'),
                    if (Platform.isIOS) const Text('Keep Exist open on this screen until class ends.'),
                    if (runner.rejected > 0) Text('${runner.rejected} invalid check-in(s) blocked'),
                    if (runner.notInClass > 0)
                      Text('${runner.notInClass} phone(s) of students not in this class were turned away'),
                    if (runner.error != null) Text(runner.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final r in runner.roster)
                      ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 14,
                          backgroundColor: runner.hasArrived(r.id)
                              ? Colors.green.shade600
                              : Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: Icon(
                            runner.hasArrived(r.id) ? Icons.check : Icons.person_outline,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                        title: Text(r.name),
                        subtitle: Text([r.rollNo, if (r.deviceId == null) 'no phone registered'].whereType<String>().join(' · ')),
                        onTap: () => _markSheet(context, r.id, r.name),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (runner.markOf(r.id) != null) StatusChip(runner.markOf(r.id)),
                            for (final w in opened)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Icon(
                                  (view.passed[r.id] ?? const {}).contains(w.id) ? Icons.check_circle : Icons.circle_outlined,
                                  size: 18,
                                  color: (view.passed[r.id] ?? const {}).contains(w.id)
                                      ? Colors.green.shade600
                                      : Theme.of(context).colorScheme.outline,
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: ending ? null : () => runner.paused ? runner.resume() : runner.pause(),
                          icon: Icon(runner.paused ? Icons.play_arrow : Icons.pause),
                          label: Text(runner.paused ? 'Resume' : 'Pause'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: ending || runner.paused || runner.surpriseChecksUsed >= 3 ? null : () => _surprise(context),
                          icon: const Icon(Icons.bolt),
                          label: Text(
                            'Surprise check${runner.surpriseChecksUsed > 0 ? ' (${runner.surpriseChecksUsed}/3)' : ''}',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: ending ? null : () => runner.extend(10),
                          icon: const Icon(Icons.more_time),
                          label: const Text('+10 min'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: ending ? null : () => _confirmEnd(context, now),
                          icon: const Icon(Icons.stop),
                          label: const Text('End class'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// Teacher decides a student's status by hand (e.g. phone dead, or left without permission).
  Future<void> _markSheet(BuildContext context, String studentId, String name) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(name), subtitle: const Text('Set by you; saved even without internet')),
            for (final s in const ['PRESENT', 'LATE', 'LEFT_EARLY', 'ABSENT', 'EXCUSED'])
              ListTile(leading: StatusChip(s), onTap: () => Navigator.pop(ctx, s)),
            if (runner.markOf(studentId) != null)
              ListTile(
                leading: const Icon(Icons.undo),
                title: const Text('Back to automatic'),
                onTap: () => Navigator.pop(ctx, 'AUTO'),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    await runner.mark(studentId, choice == 'AUTO' ? null : choice);
  }

  Future<void> _surprise(BuildContext context) async {
    final m = ScaffoldMessenger.of(context);
    try {
      await runner.surpriseCheck();
      m.showSnackBar(
        const SnackBar(content: Text('Surprise check open for 2 minutes. Phones in the room check in by themselves.')),
      );
    } catch (e) {
      m.showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))));
    }
  }

  Future<void> _confirmEnd(BuildContext context, int now) async {
    final early = now < runner.plannedEnd - AppScope.read(context).policy.endWindowMin * minuteMs;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End class?'),
        content: Text(
          early
              ? 'The final check stays open for ${AppScope.read(context).policy.earlyEndWindowMin} more minutes so students can check out.'
              : 'Attendance will be finalised.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not yet')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('End')),
        ],
      ),
    );
    if (ok == true) await runner.end();
  }
}
