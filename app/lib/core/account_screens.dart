import 'package:flutter/material.dart';

import 'app_state.dart';
import 'native.dart';

/// Privacy notice + consent. Shown after sign-in until accepted (and again if the notice changes).
class ConsentScreen extends StatefulWidget {
  /// When opened from Settings just to read it.
  final bool readOnly;
  const ConsentScreen({super.key, this.readOnly = false});
  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  Map<String, dynamic>? _notice;
  bool _agree = false, _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppScope.read(context).api
        .get('/consent')
        .then((n) {
          if (mounted) setState(() => _notice = Map<String, dynamic>.from(n));
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = e.toString());
        });
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await AppScope.read(context).acceptConsent(_notice!['version']);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = _notice;
    return Scaffold(
      appBar: AppBar(title: Text(n?['title'] ?? 'Privacy'), automaticallyImplyLeading: widget.readOnly),
      body: n == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                for (final s in n['sections'] as List) ...[
                  Text(s['heading'], style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(s['body']),
                  const SizedBox(height: 16),
                ],
                if (!widget.readOnly) ...[
                  CheckboxListTile(
                    value: _agree,
                    onChanged: (v) => setState(() => _agree = v ?? false),
                    title: const Text('I have read this and agree to Exist recording my attendance.'),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 8),
                  FilledButton(onPressed: _agree && !_busy ? _accept : null, child: const Text('Agree and continue')),
                  TextButton(onPressed: () => AppScope.read(context).logout(), child: const Text('I do not agree (sign out)')),
                ],
              ],
            ),
    );
  }
}

/// Change password. [forced] on first sign-in with a password given by the institution.
class ChangePasswordScreen extends StatefulWidget {
  final bool forced;
  const ChangePasswordScreen({super.key, this.forced = false});
  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _cur = TextEditingController(), _new = TextEditingController(), _again = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    if (_new.text.length < 8) return setState(() => _error = 'Use at least 8 characters');
    if (_new.text != _again.text) return setState(() => _error = 'The new passwords do not match');
    setState(() {
      _busy = true;
      _error = null;
    });
    final nav = Navigator.of(context);
    try {
      await AppScope.read(context).changePassword(_cur.text, _new.text);
      if (!widget.forced && nav.canPop()) nav.pop();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration d(String l) => InputDecoration(labelText: l, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: const Text('Change password'), automaticallyImplyLeading: !widget.forced),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (widget.forced)
            const Padding(padding: EdgeInsets.only(bottom: 16), child: Text('Choose your own password before you continue.')),
          TextField(
            controller: _cur,
            obscureText: true,
            decoration: d(widget.forced ? 'Password you were given' : 'Current password'),
          ),
          const SizedBox(height: 12),
          TextField(controller: _new, obscureText: true, decoration: d('New password (8+ characters)')),
          const SizedBox(height: 12),
          TextField(controller: _again, obscureText: true, decoration: d('New password again'), onSubmitted: (_) => _save()),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Save password')),
          if (widget.forced) TextButton(onPressed: () => AppScope.read(context).logout(), child: const Text('Sign out')),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _delete(BuildContext context) async {
    final app = AppScope.read(context);
    final pw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete my account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              app.role == 'STUDENT'
                  ? 'Your name, email, phone and calendar are erased and attendance stops. Class registers keep your past entries without your name. This cannot be undone.'
                  : 'Your name, email and calendar are erased. Your classes stay with any co-teachers. This cannot be undone.',
            ),
            TextField(
              controller: pw,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Your password'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.api.post('/me/delete', {'password': pw.text});
      await Native.studentConfigure(deviceId: '', subjects: const [], windows: const []).catchError((_) {});
      await app.logout();
      if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final me = app.me ?? {};
    void open(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person)),
            title: Text(me['name'] ?? ''),
            subtitle: Text(
              [
                me['email'],
                if (me['rollNo'] != null) 'Roll ${me['rollNo']}',
                if ((me['classes'] as List?)?.isNotEmpty ?? false) 'Class ${(me['classes'] as List).join(', ')}',
              ].whereType<String>().join('\n'),
            ),
            isThreeLine: true,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.password),
            title: const Text('Change password'),
            onTap: () => open(const ChangePasswordScreen()),
          ),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy notice'),
            onTap: () => open(const ConsentScreen(readOnly: true)),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () async {
              await app.logout();
              if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
          ListTile(
            leading: Icon(Icons.no_accounts, color: Theme.of(context).colorScheme.error),
            subtitle: const Text('Also withdraws consent'),
            title: Text('Delete my account', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => _delete(context),
          ),
        ],
      ),
    );
  }
}
