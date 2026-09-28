// Writes shared/test-vectors.json: known-answer tests the Dart app must reproduce.
import { generateKeyPairSync, sign } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import {
  encodeChallenge, encodeCheckIn, encodeCheckInBody, Phase, sectionIdentity,
  shortIdForKey, signedMessage, tokenFor,
} from '../src/crypto/protocol.js';
import { planChecks, withExtraChecks } from '../src/domain/plan.js';
import { DEFAULT_POLICY, MIN } from '../src/domain/policy.js';

const secret = Buffer.from('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f', 'hex');
const key = 'tt:2026-09-28:570:CS-A+CS-B';
const shortId = shortIdForKey(key);
const slot = 356_000_000;
const token = tokenFor(secret, shortId, slot);
const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
const body = encodeCheckInBody({
  shortId, slot, token, deviceId: '11111111-2222-4333-8444-555555555555',
  nonce: Buffer.from('0102030405060708', 'hex'), clientTs: 1_780_000_000_000,
});
const sig = sign('sha256', signedMessage(body), { key: privateKey, dsaEncoding: 'der' });
const T0 = Date.UTC(2026, 8, 28, 4, 0);
const times = { scheduledStart: T0, scheduledEnd: T0 + 60 * MIN, actualStart: T0 + 3 * MIN, actualEnd: null, plannedEnd: T0 + 60 * MIN };
const lab = { ...times, scheduledEnd: T0 + 180 * MIN, plannedEnd: T0 + 180 * MIN };

const vectors = {
  secretHex: secret.toString('hex'),
  sessionKey: key,
  shortId,
  slot,
  token,
  sectionId: 'CS301-CSE-A',
  sectionIdentity: sectionIdentity('CS301-CSE-A'),
  challengeHex: encodeChallenge({ shortId, slot, token, phase: Phase.MID, windowIndex: 1 }).toString('hex'),
  checkInBodyHex: body.toString('hex'),
  checkInHex: encodeCheckIn(body, sig).toString('hex'),
  publicKeySpkiB64: publicKey.export({ format: 'der', type: 'spki' }).toString('base64'),
  plans: [
    { times, plan: {}, extra: [], windows: planChecks(secret, times, DEFAULT_POLICY) },
    { times: lab, plan: {}, extra: [], windows: planChecks(secret, lab, DEFAULT_POLICY) },
    {
      times: lab,
      plan: { midChecks: 2, startWindowMin: 15, endWindowMin: 5 },
      extra: [[T0 + 100 * MIN, T0 + 102 * MIN]],
      windows: withExtraChecks(planChecks(secret, lab, { ...DEFAULT_POLICY, midChecks: 2, startWindowMin: 15, endWindowMin: 5 }), [[T0 + 100 * MIN, T0 + 102 * MIN]]),
    },
    { times, plan: { midChecks: 0 }, extra: [], windows: planChecks(secret, times, { ...DEFAULT_POLICY, midChecks: 0 }) },
  ],
};
writeFileSync(new URL('../../shared/test-vectors.json', import.meta.url), JSON.stringify(vectors, null, 2) + '\n');
console.log('wrote shared/test-vectors.json');
