// Exist BLE protocol v1. Byte layouts here are mirrored exactly in
// app/lib/protocol/protocol.dart; shared/test-vectors.json keeps them in sync.
import { createHash, createHmac, createPublicKey, verify as cryptoVerify } from 'node:crypto';

export const PROTOCOL_VERSION = 1;
export const SLOT_MS = 5_000;

/** Fixed GATT characteristic UUIDs (the service UUID is per session). */
export const CHALLENGE_CHAR_UUID = '6a1f0001-7e57-4e1a-9d2b-3c5e0b1d7a01';
export const CHECKIN_CHAR_UUID = '6a1f0002-7e57-4e1a-9d2b-3c5e0b1d7a01';

export enum Phase {
  ARRIVE = 1, // session running, no timed window open: late arrivals check in here
  MID = 2,
  END = 3,
}

const u8 = (n: number) => Buffer.from([n & 0xff]);
const u32 = (n: number) => {
  const b = Buffer.alloc(4);
  b.writeUInt32BE(n >>> 0);
  return b;
};
const u64 = (n: number | bigint) => {
  const b = Buffer.alloc(8);
  b.writeBigUInt64BE(BigInt(n));
  return b;
};
const sha256 = (...parts: Buffer[]) => createHash('sha256').update(Buffer.concat(parts)).digest();
const ascii = (s: string) => Buffer.from(s, 'ascii');

export function uuidFromBytes(b: Buffer): string {
  const h = b.subarray(0, 16).toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}

export function uuidToBytes(uuid: string): Buffer {
  const hex = uuid.replace(/-/g, '');
  if (!/^[0-9a-fA-F]{32}$/.test(hex)) throw new Error(`bad uuid: ${uuid}`);
  return Buffer.from(hex, 'hex');
}

/** 32-bit id derived from the session key; students can compute it from their timetable. */
export function shortIdForKey(sessionKey: string): number {
  return sha256(Buffer.from(sessionKey, 'utf8')).readUInt32BE(0);
}

export const slotAt = (ms: number) => Math.floor(ms / SLOT_MS);

/** Rotating 32-bit token. Only holders of the session secret can produce it. */
export function tokenFor(secret: Buffer, shortId: number, slot: number): number {
  return createHmac('sha256', secret)
    .update(Buffer.concat([ascii('EXST-TOK'), u32(shortId), u64(slot)]))
    .digest()
    .readUInt32BE(0);
}

/**
 * Every subject group (section) has permanent Bluetooth identities, so a student's phone can
 * detect *any* class of its own subjects, even one the teacher starts without notice, and
 * ignores all other classes. Each identity exists in two variants (toggle 0/1): the teacher's
 * phone flips the toggle whenever a check opens or closes, which wakes the students' phones.
 */
export const sectionShortId = (sectionId: string) => shortIdForKey(`sec:${sectionId}`);

/** GATT service UUID the teacher phone advertises for a subject group. */
export function serviceUuid(sectionShort: number, toggle: 0 | 1): string {
  return uuidFromBytes(sha256(ascii('EXST-SVC'), u32(sectionShort), u8(toggle)));
}

/** iBeacon UUID (iOS region monitoring wakes the student app on entry). */
export function regionUuid(sectionShort: number, toggle: 0 | 1): string {
  return uuidFromBytes(sha256(ascii('EXST-REG'), u32(sectionShort), u8(toggle)));
}

/** Everything a phone needs to recognise one subject group. */
export function sectionIdentity(sectionId: string) {
  const id = sectionShortId(sectionId);
  return {
    sectionShortId: id,
    service: [serviceUuid(id, 0), serviceUuid(id, 1)] as const,
    region: [regionUuid(id, 0), regionUuid(id, 1)] as const,
  };
}

// ---- Challenge (teacher -> student, read from CHALLENGE characteristic), 19 bytes
export interface Challenge {
  shortId: number;
  slot: number;
  token: number;
  phase: Phase;
  windowIndex: number;
}

export function encodeChallenge(c: Challenge): Buffer {
  return Buffer.concat([u8(PROTOCOL_VERSION), u32(c.shortId), u64(c.slot), u32(c.token), u8(c.phase), u8(c.windowIndex)]);
}

export function decodeChallenge(b: Buffer): Challenge {
  if (b.length !== 19 || b[0] !== PROTOCOL_VERSION) throw new Error('bad challenge');
  return {
    shortId: b.readUInt32BE(1),
    slot: Number(b.readBigUInt64BE(5)),
    token: b.readUInt32BE(13),
    phase: b[17] as Phase,
    windowIndex: b[18],
  };
}

// ---- Check-in (student -> teacher, written to CHECKIN characteristic)
// body (49 bytes): ver u8 | shortId u32 | slot u64 | token u32 | deviceId 16B | nonce 8B | clientTs u64
// then: sigLen u8 | ECDSA-P256-SHA256 DER signature over ("EXST-CHK" || body)
export const CHECKIN_BODY_LEN = 49;

export interface CheckInBody {
  shortId: number;
  slot: number;
  token: number;
  deviceId: string; // uuid
  nonce: Buffer; // 8 bytes
  clientTs: number;
}

export interface CheckIn extends CheckInBody {
  body: Buffer;
  signature: Buffer;
}

export function encodeCheckInBody(c: CheckInBody): Buffer {
  if (c.nonce.length !== 8) throw new Error('nonce must be 8 bytes');
  return Buffer.concat([
    u8(PROTOCOL_VERSION),
    u32(c.shortId),
    u64(c.slot),
    u32(c.token),
    uuidToBytes(c.deviceId),
    c.nonce,
    u64(c.clientTs),
  ]);
}

export const signedMessage = (body: Buffer) => Buffer.concat([ascii('EXST-CHK'), body]);

export function encodeCheckIn(body: Buffer, signature: Buffer): Buffer {
  return Buffer.concat([body, u8(signature.length), signature]);
}

export function decodeCheckIn(b: Buffer): CheckIn {
  if (b.length < CHECKIN_BODY_LEN + 1 || b[0] !== PROTOCOL_VERSION) throw new Error('bad check-in');
  const sigLen = b[CHECKIN_BODY_LEN];
  if (b.length !== CHECKIN_BODY_LEN + 1 + sigLen) throw new Error('bad check-in length');
  const body = b.subarray(0, CHECKIN_BODY_LEN);
  return {
    shortId: body.readUInt32BE(1),
    slot: Number(body.readBigUInt64BE(5)),
    token: body.readUInt32BE(13),
    deviceId: uuidFromBytes(body.subarray(17, 33)),
    nonce: Buffer.from(body.subarray(33, 41)),
    clientTs: Number(body.readBigUInt64BE(41)),
    body: Buffer.from(body),
    signature: Buffer.from(b.subarray(CHECKIN_BODY_LEN + 1)),
  };
}

/** Verify with the device's registered P-256 public key (SPKI DER, base64). */
export function verifyCheckInSignature(c: CheckIn, publicKeySpkiB64: string): boolean {
  try {
    const key = createPublicKey({ key: Buffer.from(publicKeySpkiB64, 'base64'), format: 'der', type: 'spki' });
    return cryptoVerify('sha256', signedMessage(c.body), { key, dsaEncoding: 'der' }, c.signature);
  } catch {
    return false;
  }
}
