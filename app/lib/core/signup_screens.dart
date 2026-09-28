import 'package:flutter/material.dart';

import 'app_state.dart';

InputDecoration _field(String label, {String? hint}) =>
    InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder());

/// Create your own account as a student or a teacher. Students can join their first class with
/// its code right away; teachers may need the institution's teacher code.
class CreateAccountScreen extends StatefulWidget {
  const CreateAccountScreen({super.key});
  @override
  State<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends State<CreateAccountScreen> {
  final _name = TextEditingController(), _email = TextEditingController(), _roll = TextEditingController();
  final _pw = TextEditingController(), _pw2 = TextEditingController(), _code = TextEditingController();
  String _role = 'STUDENT';
  bool _teacherCodeRequired = false, _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    AppScope.read(context).api
        .get('/setup/status')
        .then((r) {
          if (mounted) setState(() => _teacherCodeRequired = r['teacherCodeRequired'] == true);
        })
        .catchError((Object _) {});
  }

  Future<void> _create() async {
    final student = _role == 'STUDENT';
    if (_name.text.trim().length < 2) return setState(() => _error = 'Enter your full name');
    if (student && _roll.text.trim().isEmpty) return setState(() => _error = 'Enter your roll number');
    if (!student && _teacherCodeRequired && _code.text.trim().isEmpty) return setState(() => _error = 'Enter the teacher code');
    if (_pw.text.length < 8) return setState(() => _error = 'Password: at least 8 characters');
    if (_pw.text != _pw2.text) return setState(() => _error = 'The passwords do not match');
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = AppScope.read(context);
    final nav = Navigator.of(context);
    try {
      await app.register(
        role: _role,
        name: _name.text.trim(),
        email: _email.text.trim(),
        password: _pw.text,
        rollNo: student ? _roll.text.trim() : null,
        classCode: student && _code.text.trim().isNotEmpty ? _code.text.trim() : null,
        teacherCode: !student && _code.text.trim().isNotEmpty ? _code.text.trim() : null,
      );
      nav.popUntil((r) => r.isFirst);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final student = _role == 'STUDENT';
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'STUDENT', icon: Icon(Icons.school), label: Text("I'm a student")),
              ButtonSegment(value: 'TEACHER', icon: Icon(Icons.co_present), label: Text("I'm a teacher")),
            ],
            selected: {_role},
            onSelectionChanged: (v) => setState(() {
              _role = v.first;
              _code.clear();
            }),
          ),
          const SizedBox(height: 16),
          TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: _field('Full name')),
          const SizedBox(height: 12),
          TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: _field('Email')),
          if (student) ...[const SizedBox(height: 12), TextField(controller: _roll, decoration: _field('Roll number'))],
          const SizedBox(height: 12),
          TextField(controller: _pw, obscureText: true, decoration: _field('Password (8+ characters)')),
          const SizedBox(height: 12),
          TextField(controller: _pw2, obscureText: true, decoration: _field('Password again')),
          const SizedBox(height: 12),
          if (student || _teacherCodeRequired)
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: _field(
                student ? 'Class code (optional)' : 'Teacher code',
                hint: student ? 'From your teacher; you can also join classes later' : 'From your institution',
              ),
            ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : _create, child: const Text('Create account')),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }
}

/// Forgot password: a 6-digit code by email, or "ask your teacher" if email isn't set up.
class ForgotPasswordScreen extends StatefulWidget {
  final String email;
  const ForgotPasswordScreen({super.key, this.email = ''});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController(), _pw = TextEditingController(), _pw2 = TextEditingController();
  bool _sent = false, _busy = false, _done = false;
  String? _message, _error;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await AppScope.read(context).api.post('/auth/forgot', {'email': _email.text.trim()});
      setState(() {
        _sent = r['emailSent'] == true;
        _message = r['message'];
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reset() async {
    if (_pw.text.length < 8) return setState(() => _error = 'Password: at least 8 characters');
    if (_pw.text != _pw2.text) return setState(() => _error = 'The passwords do not match');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(
        context,
      ).api.post('/auth/reset', {'email': _email.text.trim(), 'code': _code.text.trim(), 'password': _pw.text});
      setState(() => _done = true);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Forgot password')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (_done) ...[
            const Text('Password changed. Sign in with your new password.'),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Back to sign in')),
          ] else if (!_sent) ...[
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: _field('Your email')),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _send, child: const Text('Send reset code')),
            if (_message != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_message!)),
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Text('No email? Students can ask their teacher and teachers their admin to reset it in the app.'),
            ),
          ] else ...[
            Text(_message ?? ''),
            const SizedBox(height: 16),
            TextField(controller: _code, keyboardType: TextInputType.number, maxLength: 6, decoration: _field('6-digit code')),
            TextField(controller: _pw, obscureText: true, decoration: _field('New password (8+ characters)')),
            const SizedBox(height: 12),
            TextField(controller: _pw2, obscureText: true, decoration: _field('New password again')),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _reset, child: const Text('Change password')),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
