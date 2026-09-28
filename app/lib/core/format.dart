import 'package:flutter/material.dart';

String hm(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String dayLabel(int ms, int now) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final n = DateTime.fromMillisecondsSinceEpoch(now);
  final days = DateTime(d.year, d.month, d.day).difference(DateTime(n.year, n.month, n.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Tomorrow';
  if (days == -1) return 'Yesterday';
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${names[d.weekday - 1]} ${d.day}/${d.month}';
}

const statusLabels = {
  'PRESENT': 'Present',
  'LATE': 'Late',
  'LEFT_EARLY': 'Left early',
  'FLAGGED': 'Needs review',
  'ABSENT': 'Absent',
  'EXCUSED': 'Excused',
  'MANUAL': 'Present (teacher)',
  'UNVERIFIED': 'Unverified',
};

Color statusColor(BuildContext c, String? s) {
  final cs = Theme.of(c).colorScheme;
  return switch (s) {
    'PRESENT' || 'MANUAL' => Colors.green.shade600,
    'LATE' || 'LEFT_EARLY' => Colors.orange.shade700,
    'FLAGGED' || 'UNVERIFIED' => Colors.amber.shade800,
    'ABSENT' => cs.error,
    'EXCUSED' => Colors.blueGrey,
    _ => cs.outline,
  };
}

class StatusChip extends StatelessWidget {
  final String? status;
  const StatusChip(this.status, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = statusColor(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
      child: Text(
        statusLabels[status] ?? status ?? '—',
        style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 12),
      ),
    );
  }
}
