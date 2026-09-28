import { generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import {
  decodeChallenge, decodeCheckIn, encodeChallenge, encodeCheckIn, encodeCheckInBody, Phase,
  sectionIdentity, shortIdForKey, signedMessage, tokenFor, verifyCheckInSignature,
} from '../src/crypto/protocol.js';

const secret = randomBytes(32);

function makeCheckIn() {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const body = encodeCheckInBody({
    shortId: 42, slot: 1000, token: tokenFor(secret, 42, 1000),
    deviceId: '11111111-2222-4333-8444-555555555555', nonce: randomBytes(8), clientTs: Date.now(),
  });
  const sig = sign('sha256', signedMessage(body), { key: privateKey, dsaEncoding: 'der' });
  return { raw: encodeCheckIn(body, sig), spki: publicKey.export({ format: 'der', type: 'spki' }).toString('base64') };
}

describe('protocol', () => {
  it('token changes every slot and depends on the secret', () => {
    expect(tokenFor(secret, 1, 10)).not.toBe(tokenFor(secret, 1, 11));
    expect(tokenFor(secret, 1, 10)).not.toBe(tokenFor(randomBytes(32), 1, 10));
  });

  it('each subject group has distinct identities per toggle, different from other groups', () => {
    const a = sectionIdentity('CS301-A'), b = sectionIdentity('CS301-B');
    expect(new Set([...a.service, ...a.region, ...b.service, ...b.region]).size).toBe(8);
    expect(sectionIdentity('CS301-A')).toEqual(a); // permanent
  });

  it('challenge round-trips', () => {
    const c = { shortId: 7, slot: 123456789, token: 0xdeadbeef, phase: Phase.END, windowIndex: 0 };
    expect(decodeChallenge(encodeChallenge(c))).toEqual(c);
  });

  it('signed check-in verifies; tampering or wrong key fails', () => {
    const { raw, spki } = makeCheckIn();
    const c = decodeCheckIn(raw);
    expect(c.shortId).toBe(42);
    expect(verifyCheckInSignature(c, spki)).toBe(true);
    expect(verifyCheckInSignature(c, makeCheckIn().spki)).toBe(false);
    const bad = Buffer.from(raw); bad[10] ^= 1;
    expect(verifyCheckInSignature(decodeCheckIn(bad), spki)).toBe(false);
  });

  it('check-in fits in one GATT write (<= 182 bytes, iOS default MTU)', () => {
    expect(makeCheckIn().raw.length).toBeLessThanOrEqual(182);
  });

  it('shared vectors still match this implementation', () => {
    const v = JSON.parse(readFileSync(new URL('../../shared/test-vectors.json', import.meta.url), 'utf8'));
    expect(shortIdForKey(v.sessionKey)).toBe(v.shortId);
    expect(tokenFor(Buffer.from(v.secretHex, 'hex'), v.shortId, v.slot)).toBe(v.token);
    expect(verifyCheckInSignature(decodeCheckIn(Buffer.from(v.checkInHex, 'hex')), v.publicKeySpkiB64)).toBe(true);
  });
});
