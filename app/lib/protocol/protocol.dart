// Exist BLE protocol v1 — mirror of backend/src/crypto/protocol.ts.
// shared/test-vectors.json (checked in test/protocol_test.dart) keeps both in sync.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' as pc;

const protocolVersion = 1;
const slotMs = 5000;
const challengeCharUuid = '6a1f0001-7e57-4e1a-9d2b-3c5e0b1d7a01';
const checkinCharUuid = '6a1f0002-7e57-4e1a-9d2b-3c5e0b1d7a01';
const checkinBodyLen = 49;

enum Phase {
  arrive(1),
  mid(2),
  end(3);

  const Phase(this.code);
  final int code;
  static Phase fromCode(int c) => Phase.values.firstWhere((p) => p.code == c);
}

Uint8List _u8(int n) => Uint8List.fromList([n & 0xff]);
Uint8List _u32(int n) => Uint8List(4)..buffer.asByteData().setUint32(0, n & 0xffffffff);
Uint8List _u64(int n) => Uint8List(8)..buffer.asByteData().setUint64(0, n);
Uint8List _cat(List<List<int>> parts) => Uint8List.fromList([for (final p in parts) ...p]);
Uint8List _ascii(String s) => Uint8List.fromList(ascii.encode(s));
Uint8List _sha256(List<List<int>> parts) => Uint8List.fromList(sha256.convert(_cat(parts)).bytes);
int _readU32(List<int> b, int off) => ByteData.sublistView(Uint8List.fromList(b)).getUint32(off);

String uuidFromBytes(List<int> b) {
  final h = b.take(16).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20, 32)}';
}

Uint8List uuidToBytes(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(hex)) throw FormatException('bad uuid $uuid');
  return Uint8List.fromList([for (var i = 0; i < 32; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);
}

int shortIdForKey(String sessionKey) => _readU32(_sha256([utf8.encode(sessionKey)]), 0);

int slotAt(int ms) => ms ~/ slotMs;

int tokenFor(List<int> secret, int shortId, int slot) {
  final mac = Hmac(sha256, secret).convert(_cat([_ascii('EXST-TOK'), _u32(shortId), _u64(slot)]));
  return _readU32(mac.bytes, 0);
}

/// Permanent Bluetooth identities of a subject group (see backend protocol.ts). Two variants each;
/// the teacher phone flips the toggle whenever a check opens or closes, waking students' phones.
int sectionShortId(String sectionId) => shortIdForKey('sec:$sectionId');

String serviceUuid(int sectionShort, int toggle) => uuidFromBytes(_sha256([_ascii('EXST-SVC'), _u32(sectionShort), _u8(toggle)]));

String regionUuid(int sectionShort, int toggle) => uuidFromBytes(_sha256([_ascii('EXST-REG'), _u32(sectionShort), _u8(toggle)]));

class SectionIdentity {
  final int sectionShortId;
  final List<String> service, region;
  SectionIdentity(String sectionId)
    : sectionShortId = shortIdForKey('sec:$sectionId'),
      service = [serviceUuid(shortIdForKey('sec:$sectionId'), 0), serviceUuid(shortIdForKey('sec:$sectionId'), 1)],
      region = [regionUuid(shortIdForKey('sec:$sectionId'), 0), regionUuid(shortIdForKey('sec:$sectionId'), 1)];

  Map<String, dynamic> toNative() => {'service0': service[0], 'service1': service[1], 'region0': region[0], 'region1': region[1]};
}

class Challenge {
  final int shortId, slot, token, windowIndex;
  final Phase phase;
  const Challenge({
    required this.shortId,
    required this.slot,
    required this.token,
    required this.phase,
    required this.windowIndex,
  });

  Uint8List encode() => _cat([_u8(protocolVersion), _u32(shortId), _u64(slot), _u32(token), _u8(phase.code), _u8(windowIndex)]);

  static Challenge decode(List<int> b) {
    if (b.length != 19 || b[0] != protocolVersion) throw const FormatException('bad challenge');
    final d = ByteData.sublistView(Uint8List.fromList(b));
    return Challenge(
      shortId: d.getUint32(1),
      slot: d.getUint64(5),
      token: d.getUint32(13),
      phase: Phase.fromCode(b[17]),
      windowIndex: b[18],
    );
  }
}

class CheckIn {
  final int shortId, slot, token, clientTs;
  final String deviceId;
  final Uint8List nonce, body, signature, raw;
  CheckIn._(this.shortId, this.slot, this.token, this.deviceId, this.nonce, this.clientTs, this.body, this.signature, this.raw);

  String get nonceHex => nonce.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List encodeBody({
    required int shortId,
    required int slot,
    required int token,
    required String deviceId,
    required List<int> nonce,
    required int clientTs,
  }) {
    if (nonce.length != 8) throw ArgumentError('nonce must be 8 bytes');
    return _cat([_u8(protocolVersion), _u32(shortId), _u64(slot), _u32(token), uuidToBytes(deviceId), nonce, _u64(clientTs)]);
  }

  static Uint8List signedMessage(List<int> body) => _cat([_ascii('EXST-CHK'), body]);

  static Uint8List encode(List<int> body, List<int> signature) => _cat([body, _u8(signature.length), signature]);

  static CheckIn decode(List<int> raw) {
    if (raw.length < checkinBodyLen + 1 || raw[0] != protocolVersion) throw const FormatException('bad check-in');
    final sigLen = raw[checkinBodyLen];
    if (raw.length != checkinBodyLen + 1 + sigLen) throw const FormatException('bad check-in length');
    final b = Uint8List.fromList(raw);
    final d = ByteData.sublistView(b);
    return CheckIn._(
      d.getUint32(1),
      d.getUint64(5),
      d.getUint32(13),
      uuidFromBytes(b.sublist(17, 33)),
      b.sublist(33, 41),
      d.getUint64(41),
      b.sublist(0, checkinBodyLen),
      b.sublist(checkinBodyLen + 1),
      b,
    );
  }

  /// Verify against the student's registered key (P-256 SPKI DER, base64).
  bool verify(String publicKeySpkiB64) {
    try {
      final q = _p256PointFromSpki(base64.decode(publicKeySpkiB64));
      final sig = _parseDerSignature(signature);
      final verifier = pc.Signer('SHA-256/ECDSA')..init(false, pc.PublicKeyParameter<pc.ECPublicKey>(pc.ECPublicKey(q, _curve)));
      return verifier.verifySignature(signedMessage(body), sig);
    } catch (_) {
      return false;
    }
  }
}

final _curve = pc.ECCurve_secp256r1();

// SPKI for P-256 = fixed 26-byte header + uncompressed point (0x04 || X || Y).
pc.ECPoint _p256PointFromSpki(List<int> spki) {
  if (spki.length != 91 || spki[26] != 0x04) throw const FormatException('not a P-256 SPKI key');
  return _curve.curve.decodePoint(spki.sublist(26))!;
}

BigInt _bigInt(List<int> bytes) => bytes.fold(BigInt.zero, (a, b) => (a << 8) | BigInt.from(b));

pc.ECSignature _parseDerSignature(List<int> der) {
  // SEQUENCE { INTEGER r, INTEGER s }
  var i = 0;
  if (der[i++] != 0x30) throw const FormatException('bad sig');
  if (der[i] & 0x80 != 0) i += der[i] & 0x7f;
  i++;
  BigInt readInt() {
    if (der[i++] != 0x02) throw const FormatException('bad sig');
    final len = der[i++];
    final v = _bigInt(der.sublist(i, i + len));
    i += len;
    return v;
  }

  final r = readInt();
  final s = readInt();
  return pc.ECSignature(r, s);
}
