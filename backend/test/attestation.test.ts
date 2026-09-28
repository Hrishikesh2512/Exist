import { describe, expect, it } from 'vitest';
import { children, parseKeyDescription, readDer, verifyAndroid } from '../src/lib/attestation.js';
import { generateKeyPairSync } from 'node:crypto';

// Tiny DER writer to build test structures.
const len = (n: number) => (n < 128 ? Buffer.from([n]) : n < 256 ? Buffer.from([0x81, n]) : Buffer.from([0x82, n >> 8, n & 0xff]));
const tlv = (tag: number[] | number, body: Buffer) => Buffer.concat([Buffer.from(Array.isArray(tag) ? tag : [tag]), len(body.length), body]);
const seq = (...x: Buffer[]) => tlv(0x30, Buffer.concat(x));
const int = (n: number) => tlv(0x02, Buffer.from([n]));
const en = (n: number) => tlv(0x0a, Buffer.from([n]));
const oct = (b: Buffer) => tlv(0x04, b);
const bool = (v: boolean) => tlv(0x01, Buffer.from([v ? 0xff : 0]));
const ctx = (tagNo: number, body: Buffer) => tlv([0xbf, 0x80 | (tagNo >> 7), tagNo & 0x7f], body); // tags >= 128

function keyDescription(o: { level: number; challenge: string; locked: boolean; boot: number; pkg: string }) {
  const rot = seq(oct(Buffer.alloc(32)), bool(o.locked), en(o.boot));
  const appId = seq(tlv(0x31, seq(oct(Buffer.from(o.pkg)), int(1))), tlv(0x31, oct(Buffer.alloc(32))));
  const hw = seq(ctx(704, rot));
  const sw = seq(ctx(709, oct(appId)));
  return seq(int(4), en(o.level), int(4), en(o.level), oct(Buffer.from(o.challenge)), oct(Buffer.alloc(0)), sw, hw);
}

describe('Android key attestation', () => {
  it('reads high-numbered context tags', () => {
    const b = ctx(704, seq(int(1)));
    const el = readDer(b, 0);
    expect([el.cls, el.tag, el.constructed]).toEqual([2, 704, true]);
    expect(children(b, el)).toHaveLength(1);
  });

  it('parses a genuine-phone KeyDescription', () => {
    const f = parseKeyDescription(keyDescription({ level: 1, challenge: 'exist-device-key-v1', locked: true, boot: 0, pkg: 'edu.exist.exist' }));
    expect(f).toMatchObject({ securityLevel: 1, deviceLocked: true, verifiedBootState: 0, packages: ['edu.exist.exist'] });
    expect(f.challenge.toString()).toBe('exist-device-key-v1');
  });

  it('parses a rooted-phone KeyDescription', () => {
    const f = parseKeyDescription(keyDescription({ level: 1, challenge: 'x', locked: false, boot: 2, pkg: 'edu.exist.exist' }));
    expect([f.deviceLocked, f.verifiedBootState]).toEqual([false, 2]);
  });

  it('rejects an empty chain', async () => {
    const { publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    const r = await verifyAndroid([], publicKey.export({ type: 'spki', format: 'der' }).toString('base64'), new Set());
    expect(r).toEqual({ verified: false, detail: 'no certificate chain' });
  });
});
