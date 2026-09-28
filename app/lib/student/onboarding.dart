import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/app_state.dart';
import '../core/format.dart';
import '../core/native.dart';

/// One-time setup: permissions, background exemption, and binding this phone.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _pending;

  Future<void> _permissions() async {
    final sdk = Platform.isAndroid ? ((await Native.state())['sdk'] as int? ?? 31) : 0;
    final bt = Platform.isIOS ? [Permission.bluetooth] : [Permission.bluetoothScan, Permission.bluetoothConnect];
    // Android 12+: Bluetooth only. Android 11 and older can only scan with location permission.
    // iPhone: waking up for class uses iBeacon region monitoring, which is a location API.
    final needsLocation = Platform.isIOS || sdk <= 30;
    final res = await [...bt, if (needsLocation) Permission.locationWhenInUse, Permission.notification].request();
    if (!bt.every((p) => res[p]?.isGranted ?? false)) {
      throw Exception('Bluetooth permission is needed to mark attendance. Allow it in Settings.');
    }
    if (needsLocation && !(res[Permission.locationWhenInUse]?.isGranted ?? false)) {
      throw Exception('This phone needs location permission to use Bluetooth. Exist never reads your GPS position.');
    }
    // "Allow all the time": needed to wake up for class with the app closed (iPhone; Android 10–11).
    if (Platform.isIOS || (sdk >= 29 && sdk <= 30)) await Permission.locationAlways.request();
  }

  Future<void> _next() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_step == 0) {
        await _permissions();
        setState(() => _step = 1);
      } else if (_step == 1) {
        if (Platform.isAndroid) await Native.requestBackgroundExemption();
        setState(() => _step = 2);
      } else {
        final r = await AppScope.read(context).bindDevice();
        if (r['status'] == 'PENDING') setState(() => _pending = r);
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = [
      (
        'Allow Bluetooth',
        'Exist uses Bluetooth to find your teacher\'s phone, only for your own classes. Some phones also ask for location because of how Bluetooth works; Exist never reads your GPS position.',
        Icons.bluetooth,
      ),
      (
        'Keep running in background',
        'So attendance is marked even when your phone is in your pocket. Android may ask you to allow unrestricted battery use.',
        Icons.battery_saver,
      ),
      (
        'Register this phone',
        'Your account will be locked to this phone. Changing phones later takes 48 hours or an admin\'s approval.',
        Icons.phonelink_lock,
      ),
    ];
    final (title, body, icon) = steps[_step];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up'),
        actions: [TextButton(onPressed: () => AppScope.read(context).logout(), child: const Text('Sign out'))],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: (_step + 1) / steps.length),
              const Spacer(),
              Icon(icon, size: 64, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 16),
              Text(title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(body, textAlign: TextAlign.center),
              if (_pending != null) ...[
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Your account is registered on another phone. This phone becomes active on '
                      '${dayLabel(_pending!['eligibleAt'], DateTime.now().millisecondsSinceEpoch)} at ${hm(_pending!['eligibleAt'])}, '
                      'or sooner if an admin approves it.',
                    ),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ],
              const Spacer(),
              FilledButton(
                onPressed: _busy ? null : _next,
                child: Text(_pending != null ? 'Check again' : (_step == 2 ? 'Register this phone' : 'Continue')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
