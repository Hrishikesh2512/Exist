import 'dart:async';

import 'package:flutter/material.dart';

import 'core/account_screens.dart';
import 'core/app_state.dart';
import 'core/store.dart';
import 'login.dart';
import 'student/home.dart';
import 'student/onboarding.dart';
import 'teacher/autopilot.dart';
import 'teacher/home.dart';
import 'teacher/runner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState(await Store.open());
  final runner = TeacherRunner(state);
  // Starts classes on time even when no screen is open (Android alarm wake-ups).
  TeacherAutopilot(state, runner).start();
  // Students: keep the class list fresh whenever the app process is alive (Android keeps it
  // alive during class hours; iOS relaunches it on class wake-ups), so cancellations, moved
  // classes and holidays reach the native check-in code without opening the app.
  Timer.periodic(const Duration(minutes: 30), (_) {
    if (state.signedIn && state.role == 'STUDENT') state.refreshSchedule();
  });
  // Free alternative to push notifications: show new alerts whenever the app is awake.
  Timer.periodic(const Duration(minutes: 5), (_) => state.pollNotifications());
  runApp(
    AppScope(
      state: state,
      child: ExistApp(runner: runner),
    ),
  );
}

class ExistApp extends StatelessWidget {
  final TeacherRunner runner;
  const ExistApp({super.key, required this.runner});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final seed = const Color(0xFF2E6B5E);
    return MaterialApp(
      title: 'Exist',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, useMaterial3: true, brightness: Brightness.dark),
      home: !app.signedIn
          ? const LoginScreen()
          : app.mustChangePassword
          ? const ChangePasswordScreen(forced: true)
          : app.role == 'ADMIN'
          ? const _AdminNotice()
          : app.consentRequired
          ? const ConsentScreen()
          : app.isTeacher
          ? TeacherHome(runner: runner)
          : app.deviceId == null
          ? const OnboardingScreen()
          : const StudentHome(),
    );
  }
}

class _AdminNotice extends StatelessWidget {
  const _AdminNotice();
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Admins use the web dashboard.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => AppScope.read(context).logout(), child: const Text('Sign out')),
          ],
        ),
      ),
    ),
  );
}
