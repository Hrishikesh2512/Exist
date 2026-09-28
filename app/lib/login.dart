import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/signup_screens.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController(), _pw = TextEditingController();
  bool _busy = false;
  String? _error;

  String? _institution;

  @override
  void initState() {
    super.initState();
    AppScope.read(context).api
        .get('/setup/status')
        .then((r) {
          if (mounted) setState(() => _institution = r['institution']);
        })
        .catchError((Object _) {});
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).login(_email.text, _pw.text);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(Icons.how_to_reg_rounded, size: 56, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 12),
                    Text('Exist', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 4),
                    Text(_institution ?? 'Attendance that marks itself', textAlign: TextAlign.center),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _email,
                      decoration: const InputDecoration(labelText: 'College email', border: OutlineInputBorder()),
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pw,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                      autofillHints: const [AutofillHints.password],
                      onSubmitted: (_) => _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Sign in'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ForgotPasswordScreen(email: _email.text.trim())),
                      ),
                      child: const Text('Forgot password?'),
                    ),
                    const Divider(height: 32),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateAccountScreen())),
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Create an account'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
