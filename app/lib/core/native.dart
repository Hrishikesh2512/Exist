import 'dart:async';

import 'package:flutter/services.dart';

/// Bridge to the platform code in android/…/exist/ and ios/Runner/Exist*.swift.
class Native {
  static const _m = MethodChannel('exist/native');
  static const _e = EventChannel('exist/native/events');
  static Stream<Map<String, dynamic>>? _events;

  static Stream<Map<String, dynamic>> get events =>
      _events ??= _e.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map)).asBroadcastStream();

  // ---- Hardware-backed device key (Android Keystore / iOS Secure Enclave)
  static Future<String> publicKey() async => (await _m.invokeMethod<String>('keys.publicKey'))!;
  static Future<Uint8List> sign(Uint8List data) async => (await _m.invokeMethod<Uint8List>('keys.sign', data))!;
  static Future<String> attest(String challengeB64) async =>
      (await _m.invokeMethod<String>('keys.attest', {'challenge': challengeB64})) ?? '';
  static Future<void> resetKey() => _m.invokeMethod('keys.reset');

  // ---- Bluetooth / system state
  static Future<Map<String, dynamic>> state() async => Map<String, dynamic>.from((await _m.invokeMethod<Map>('system.state'))!);
  static Future<void> requestBackgroundExemption() => _m.invokeMethod('system.requestBackgroundExemption');

  /// Show a normal phone notification (free replacement for push: shown whenever the app is awake).
  static Future<void> notify(String title, String body) => _m.invokeMethod('system.notify', {'title': title, 'body': body});

  // ---- Teacher: advertise the class's subject identities + GATT server
  /// [targets]: one SectionIdentity.toNative() per subject group in the class.
  static Future<void> teacherStart({
    required List<Map<String, dynamic>> targets,
    required int toggle,
    required Uint8List challenge,
  }) => _m.invokeMethod('teacher.start', {'targets': targets, 'toggle': toggle, 'challenge': challenge});
  static Future<void> teacherUpdate({required int toggle, required Uint8List challenge}) =>
      _m.invokeMethod('teacher.update', {'toggle': toggle, 'challenge': challenge});

  /// Answer a student's check-in write: 0 accepted, 1 not in this class, 2 invalid/try again.
  static Future<void> teacherRespond(int id, int code) => _m.invokeMethod('teacher.respond', {'id': id, 'code': code});
  static Future<void> teacherStop() => _m.invokeMethod('teacher.stop');

  /// Wake the app (Android) / show a reminder (iOS) at these times (epoch ms).
  static Future<void> scheduleTeacherAlarms(List<Map<String, dynamic>> items) =>
      _m.invokeMethod('teacher.scheduleAlarms', {'items': items});

  // ---- Student: native code checks in by itself for any class of the student's subjects.
  /// [subjects]: {sectionId, title, service0, service1, region0, region1}; [windows]: timetabled
  /// class times {from, to, title} used for extra-reliable listening and reminders.
  static Future<void> studentConfigure({
    required String deviceId,
    required List<Map<String, dynamic>> subjects,
    required List<Map<String, dynamic>> windows,
  }) => _m.invokeMethod('student.configure', {'deviceId': deviceId, 'subjects': subjects, 'windows': windows});
  static Future<List<Map<String, dynamic>>> studentLog() async =>
      ((await _m.invokeMethod<List>('student.log')) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  /// "Check in now": look for the teacher's phone of any of my subjects.
  static Future<Map<String, dynamic>> studentCheckNow() async =>
      Map<String, dynamic>.from((await _m.invokeMethod<Map>('student.checkNow', {}))!);
}
