// Offline-first layer: everything a teacher or student looks at is saved on the phone, and changes
// made without internet are queued and sent later, in order. The server stays the source of truth.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'api.dart';
import 'store.dart';

/// Data from the server, or the copy saved on the phone (then [savedAt] says when).
class Cached<T> {
  final T data;
  final DateTime? savedAt; // null = fresh from the server
  const Cached(this.data, this.savedAt);
  bool get isStale => savedAt != null;
}

/// Result of a change: sent now, or waiting on the phone until there is internet.
class SendResult {
  final dynamic data;
  final bool queued;
  const SendResult(this.data, this.queued);
}

class Offline extends ChangeNotifier {
  final Api api;
  final Store store;
  Offline(this.api, this.store) {
    _queue = [...(store.read<List>('offline.queue') ?? const [])].map((e) => Map<String, dynamic>.from(e)).toList();
    _failed = [...(store.read<List>('offline.failed') ?? const [])].map((e) => Map<String, dynamic>.from(e)).toList();
  }

  late List<Map<String, dynamic>> _queue;
  late List<Map<String, dynamic>> _failed;
  bool _flushing = false;

  int get pending => _queue.length;
  List<Map<String, dynamic>> get queue => List.unmodifiable(_queue);
  List<Map<String, dynamic>> get failed => List.unmodifiable(_failed);

  static String localId() => 'local-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';
  static bool isLocal(Object? id) => id is String && id.startsWith('local-');

  // ------------------------------------------------------------------ reading

  /// Fresh from the server when online (and saved); otherwise the saved copy.
  Future<Cached<dynamic>> get(String path) async {
    try {
      final data = await api.get(path);
      await store.write('cache:$path', {'at': DateTime.now().millisecondsSinceEpoch, 'data': data});
      return Cached(data, null);
    } on ApiException catch (e) {
      final saved = store.read<Map<String, dynamic>>('cache:$path');
      if (e.isOffline && saved != null) return Cached(saved['data'], DateTime.fromMillisecondsSinceEpoch(saved['at']));
      rethrow;
    }
  }

  /// The saved copy only (no network).
  dynamic saved(String path) => store.read<Map<String, dynamic>>('cache:$path')?['data'];

  /// Change the saved copy so the screen shows an offline edit right away.
  Future<void> patchSaved(String path, dynamic Function(dynamic data) change) async {
    final saved = store.read<Map<String, dynamic>>('cache:$path');
    if (saved == null) return;
    saved['data'] = change(saved['data']);
    await store.write('cache:$path', saved);
  }

  /// Load these in the background so they're available offline later.
  Future<void> prefetch(Iterable<String> paths) async {
    for (final p in paths) {
      try {
        await get(p);
      } on ApiException catch (e) {
        if (e.isOffline) return; // no point continuing
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------------ changing

  /// Send a change now, or keep it on the phone until there is internet.
  /// [label] is what the user sees in "waiting to sync". [localId] ties an offline-created item to its
  /// later deletion (deleting something never sent just drops it from the queue).
  Future<SendResult> send(String method, String path, {Object? body, required String label, String? localId}) async {
    if (_queue.isEmpty) {
      try {
        return SendResult(await _call(method, path, body), false);
      } on ApiException catch (e) {
        if (!e.isOffline) rethrow;
      }
    }
    // Offline, or earlier changes still waiting: keep the order.
    _queue.add({
      'method': method,
      'path': path,
      'body': body,
      'label': label,
      'localId': localId,
      'at': DateTime.now().millisecondsSinceEpoch,
    });
    await _save();
    notifyListeners();
    return const SendResult(null, true);
  }

  /// Drop a queued create (the item was deleted before it was ever sent). Returns true if found.
  Future<bool> cancelLocal(String localId) async {
    final before = _queue.length;
    _queue.removeWhere((q) => q['localId'] == localId);
    if (_queue.length == before) return false;
    await _save();
    notifyListeners();
    return true;
  }

  Future<dynamic> _call(String method, String path, Object? body) => switch (method) {
    'POST' => api.post(path, body),
    'PUT' => api.put(path, body),
    'PATCH' => api.patch(path, body),
    'DELETE' => api.delete(path),
    _ => api.get(path),
  };

  /// Send everything waiting, oldest first. Stops at the first sign of no internet.
  /// A change the server refuses (e.g. class already deleted) moves to "couldn't sync".
  Future<void> flush() async {
    if (_flushing || _queue.isEmpty) return;
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        final q = _queue.first;
        try {
          await _call(q['method'], q['path'], q['body']);
        } on ApiException catch (e) {
          if (e.isOffline) break;
          if (e.status == 401) break; // signed out; keep for after sign-in
          _failed.add({...q, 'error': e.message, 'failedAt': DateTime.now().millisecondsSinceEpoch});
        }
        _queue.removeAt(0);
        await _save();
      }
    } finally {
      _flushing = false;
      notifyListeners();
    }
  }

  Future<void> clearFailed() async {
    _failed.clear();
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    await store.write('offline.queue', _queue);
    await store.write('offline.failed', _failed.length > 50 ? _failed.sublist(_failed.length - 50) : _failed);
  }
}

String savedAtText(DateTime t) {
  final now = DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
  return sameDay ? hm : '${t.day}/${t.month} $hm';
}

/// "Offline: showing what was saved at 10:42."
class SavedBanner extends StatelessWidget {
  final DateTime? savedAt;
  const SavedBanner(this.savedAt, {super.key});
  @override
  Widget build(BuildContext context) {
    if (savedAt == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: Colors.blueGrey.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text('Offline: showing what was saved at ${savedAtText(savedAt!)}', style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// Shown after a change: sent, or saved on the phone to send later.
void showSent(BuildContext context, SendResult r, {String sent = 'Saved'}) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(r.queued ? 'Saved on this phone. It will sync when there is internet.' : sent)));
}
