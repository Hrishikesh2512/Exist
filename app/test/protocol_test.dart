import 'dart:convert';
import 'dart:io';

import 'package:exist/domain/plan.dart';
import 'package:exist/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> hex(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];
String toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final v = jsonDecode(File('../shared/test-vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final secret = hex(v['secretHex']);

  test('ids and token match the server', () {
    expect(shortIdForKey(v['sessionKey']), v['shortId']);
    expect(tokenFor(secret, v['shortId'], v['slot']), v['token']);
    final id = SectionIdentity(v['sectionId']);
    expect(id.sectionShortId, v['sectionIdentity']['sectionShortId']);
    expect(id.service, v['sectionIdentity']['service']);
    expect(id.region, v['sectionIdentity']['region']);
  });

  test('challenge bytes match', () {
    final c = Challenge(shortId: v['shortId'], slot: v['slot'], token: v['token'], phase: Phase.mid, windowIndex: 1);
    expect(toHex(c.encode()), v['challengeHex']);
    final d = Challenge.decode(hex(v['challengeHex']));
    expect([d.shortId, d.slot, d.token, d.phase, d.windowIndex], [v['shortId'], v['slot'], v['token'], Phase.mid, 1]);
  });

  test('check-in body matches and the server-made signature verifies in Dart', () {
    final body = CheckIn.encodeBody(
      shortId: v['shortId'],
      slot: v['slot'],
      token: v['token'],
      deviceId: '11111111-2222-4333-8444-555555555555',
      nonce: hex('0102030405060708'),
      clientTs: 1780000000000,
    );
    expect(toHex(body), v['checkInBodyHex']);
    final c = CheckIn.decode(hex(v['checkInHex']));
    expect(c.deviceId, '11111111-2222-4333-8444-555555555555');
    expect(c.verify(v['publicKeySpkiB64']), isTrue);
    final tampered = hex(v['checkInHex'])..[10] ^= 1;
    expect(CheckIn.decode(tampered).verify(v['publicKeySpkiB64']), isFalse);
  });

  test('check windows match the server exactly', () {
    for (final plan in v['plans'] as List) {
      final t = plan['times'];
      final got = withExtraChecks(
        planChecks(
          secret,
          SessionTimes(
            scheduledStart: t['scheduledStart'],
            scheduledEnd: t['scheduledEnd'],
            actualStart: t['actualStart'],
            plannedEnd: t['plannedEnd'],
            actualEnd: t['actualEnd'],
          ),
          const Policy().withPlan(Map<String, dynamic>.from(plan['plan'])),
        ),
        [for (final e in plan['extra'] as List) List<int>.from(e)],
      );
      expect(got.map((w) => w.toJson()).toList(), plan['windows']);
    }
  });
}
