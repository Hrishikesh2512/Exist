// Backup: when the teacher's phone is missing, the classroom screen shows a rotating QR.
// The check-in is still signed by this phone's hardware key.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/app_state.dart';
import '../core/native.dart';
import '../protocol/protocol.dart';

class QrCheckinScreen extends StatefulWidget {
  const QrCheckinScreen({super.key});
  @override
  State<QrCheckinScreen> createState() => _QrCheckinScreenState();
}

class _QrCheckinScreenState extends State<QrCheckinScreen> {
  bool _busy = false;
  String? _msg;

  Future<void> _onDetect(BarcodeCapture cap) async {
    if (_busy) return;
    final raw = cap.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    Map<String, dynamic> j;
    try {
      j = jsonDecode(raw);
      if (j['v'] != 1) throw const FormatException();
    } catch (_) {
      setState(() => _msg = 'Not an Exist code');
      return;
    }
    setState(() {
      _busy = true;
      _msg = 'Checking in…';
    });
    final app = AppScope.read(context);
    try {
      final c = Challenge.decode(base64.decode(j['c']));
      final rnd = Random.secure();
      final body = CheckIn.encodeBody(
        shortId: c.shortId,
        slot: c.slot,
        token: c.token,
        deviceId: app.deviceId!,
        nonce: List<int>.generate(8, (_) => rnd.nextInt(256)),
        clientTs: app.now(),
      );
      final sig = await Native.sign(CheckIn.signedMessage(body));
      final r = await app.api.post('/checkins/qr', {'sessionKey': j['k'], 'rawB64': base64.encode(CheckIn.encode(body, sig))});
      setState(() => _msg = r['ok'] == true ? 'Checked in ✓' : 'Rejected: ${r['error']}');
    } catch (e) {
      setState(() => _msg = 'Failed: $e');
    } finally {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan classroom code')),
      body: Stack(
        children: [
          MobileScanner(onDetect: _onDetect),
          if (_msg != null)
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(12)),
                child: Text(_msg!, style: const TextStyle(color: Colors.white)),
              ),
            ),
        ],
      ),
    );
  }
}
