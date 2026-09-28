// Hardware attestation for device binding (free, no Google/Apple service account needed).
//
// Android: the phone sends the Key Attestation certificate chain of its signing key. We check
//   - the chain is signed up to a Google attestation root (src/lib/google-attestation-roots.json,
//     from https://android.googleapis.com/attestation/root) and no certificate is revoked;
//   - the attested key is exactly the key being bound, generated with our challenge;
//   - the key lives in secure hardware (TEE/StrongBox), not software;
//   - the phone's bootloader is locked with a verified OS (not rooted / custom ROM);
//   - the key belongs to our app package.
// iOS: App Attest verification needs the Apple Team ID of a paid developer account; until then
//   iOS devices are recorded as "not verified" (never silently trusted).
//
// ATTESTATION_MODE: dev = skip · record = verify and show the result to admins (default) ·
//                   strict = refuse phones that fail.
import { createPublicKey, X509Certificate } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { config } from './config.js';

export const ANDROID_PACKAGE = process.env.ANDROID_PACKAGE ?? 'edu.exist.exist';
const CHALLENGE = Buffer.from('exist-device-key-v1');
const KEY_DESCRIPTION_OID = Buffer.from([0x2b, 0x06, 0x01, 0x04, 0x01, 0xd6, 0x79, 0x02, 0x01, 0x11]); // 1.3.6.1.4.1.11129.2.1.17

// Works from src/lib (tests, tsx) and dist/src/lib (compiled; tsc does not copy the JSON).
const rootsFile = ['./google-attestation-roots.json', '../../../src/lib/google-attestation-roots.json']
  .map((p) => new URL(p, import.meta.url))
  .find((u) => existsSync(u));
if (!rootsFile) throw new Error('google-attestation-roots.json not found');
const roots: string[] = JSON.parse(readFileSync(rootsFile, 'utf8'));
const rootKeys = new Set(roots.map((pem) => new X509Certificate(pem).publicKey.export({ type: 'spki', format: 'der' }).toString('base64')));

// ---- Minimal DER reader (enough for X.509 extensions and the KeyDescription structure).
export interface Der {
  cls: number; // 0 universal, 2 context
  constructed: boolean;
  tag: number;
  start: number; // content start
  end: number; // content end
  next: number; // offset after this element
}

export function readDer(b: Buffer, off: number): Der {
  const first = b[off];
  let p = off + 1;
  let tag = first & 0x1f;
  if (tag === 0x1f) {
    tag = 0;
    let byte;
    do {
      byte = b[p++];
      tag = (tag << 7) | (byte & 0x7f);
    } while (byte & 0x80);
  }
  let len = b[p++];
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4) throw new Error('bad DER length');
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + b[p++];
  }
  if (p + len > b.length) throw new Error('DER overflow');
  return { cls: first >> 6, constructed: !!(first & 0x20), tag, start: p, end: p + len, next: p + len };
}

export function children(b: Buffer, el: Der): Der[] {
  const out: Der[] = [];
  for (let p = el.start; p < el.end; ) {
    const c = readDer(b, p);
    out.push(c);
    p = c.next;
  }
  return out;
}

const intOf = (b: Buffer, el: Der) => b.subarray(el.start, el.end).reduce((a, x) => a * 256 + x, 0);

/** The raw KeyDescription extension value of an attestation leaf certificate, if present. */
export function keyDescription(certDer: Buffer): Buffer | null {
  const cert = readDer(certDer, 0);
  const tbs = children(certDer, cert)[0];
  const ext = children(certDer, tbs).find((e) => e.cls === 2 && e.tag === 3);
  if (!ext) return null;
  const list = children(certDer, ext)[0];
  for (const e of children(certDer, list)) {
    const parts = children(certDer, e);
    const oid = certDer.subarray(parts[0].start, parts[0].end);
    if (oid.equals(KEY_DESCRIPTION_OID)) {
      const value = parts[parts.length - 1]; // OCTET STRING
      return Buffer.from(certDer.subarray(value.start, value.end));
    }
  }
  return null;
}

export interface KeyFacts {
  securityLevel: number; // 0 software, 1 TEE, 2 StrongBox
  challenge: Buffer;
  deviceLocked: boolean | null;
  verifiedBootState: number | null; // 0 verified, 1 self-signed, 2 unverified, 3 failed
  packages: string[];
}

/** Parse KeyDescription (see Android "Key and ID attestation" schema). */
export function parseKeyDescription(kd: Buffer): KeyFacts {
  const seq = children(kd, readDer(kd, 0));
  const facts: KeyFacts = {
    securityLevel: intOf(kd, seq[1]),
    challenge: Buffer.from(kd.subarray(seq[4].start, seq[4].end)),
    deviceLocked: null,
    verifiedBootState: null,
    packages: [],
  };
  for (const list of [seq[6], seq[7]]) {
    for (const item of children(kd, list)) {
      if (item.cls !== 2) continue;
      const inner = children(kd, item)[0];
      if (item.tag === 704 && !facts.deviceLocked) {
        // RootOfTrust ::= SEQUENCE { verifiedBootKey, deviceLocked BOOLEAN, verifiedBootState ENUMERATED, ... }
        const rot = children(kd, inner);
        facts.deviceLocked = kd[rot[1].start] !== 0;
        facts.verifiedBootState = intOf(kd, rot[2]);
      } else if (item.tag === 709) {
        // AttestationApplicationId (DER inside an OCTET STRING): SEQUENCE { SET OF { SEQUENCE { name, version } }, SET OF digest }
        const aid = kd.subarray(inner.start, inner.end);
        const pkgSet = children(aid, readDer(aid, 0))[0];
        for (const info of children(aid, pkgSet)) {
          const name = children(aid, info)[0];
          facts.packages.push(aid.subarray(name.start, name.end).toString('utf8'));
        }
      }
    }
  }
  return facts;
}

let revoked: { at: number; serials: Set<string> } | null = null;
async function revokedSerials(): Promise<Set<string>> {
  if (revoked && Date.now() - revoked.at < 24 * 3600_000) return revoked.serials;
  try {
    const r = await fetch('https://android.googleapis.com/attestation/status', { signal: AbortSignal.timeout(5000) });
    const j = (await r.json()) as { entries: Record<string, unknown> };
    revoked = { at: Date.now(), serials: new Set(Object.keys(j.entries).map((s) => s.toLowerCase())) };
  } catch {
    revoked ??= { at: 0, serials: new Set() }; // offline: roots and signatures are still checked
  }
  return revoked.serials;
}

export type AttestationResult = { ok: true; type: string; verified: boolean | null; detail: string } | { ok: false; reason: string };

export async function verifyAndroid(chainB64: string[], expectedSpkiB64: string, revokedSet?: Set<string>): Promise<{ verified: boolean; detail: string }> {
  if (chainB64.length < 2) return { verified: false, detail: 'no certificate chain' };
  const certs = chainB64.map((c) => new X509Certificate(Buffer.from(c, 'base64')));
  const now = new Date();
  for (let i = 0; i < certs.length - 1; i++) {
    if (!certs[i].verify(certs[i + 1].publicKey)) return { verified: false, detail: 'broken certificate chain' };
  }
  const root = certs[certs.length - 1].publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  if (!rootKeys.has(root)) return { verified: false, detail: 'not signed by Google' };
  const rev = revokedSet ?? (await revokedSerials());
  if (certs.some((c) => rev.has(c.serialNumber.toLowerCase()))) return { verified: false, detail: 'revoked certificate' };
  if (certs.slice(1).some((c) => new Date(c.validTo) < now)) return { verified: false, detail: 'expired certificate' };
  const leafKey = certs[0].publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  const expected = createPublicKey({ key: Buffer.from(expectedSpkiB64, 'base64'), format: 'der', type: 'spki' }).export({ type: 'spki', format: 'der' }).toString('base64');
  if (leafKey !== expected) return { verified: false, detail: 'attested key is not this key' };
  const kd = keyDescription(Buffer.from(chainB64[0], 'base64'));
  if (!kd) return { verified: false, detail: 'no attestation data' };
  const f = parseKeyDescription(kd);
  if (!f.challenge.equals(CHALLENGE)) return { verified: false, detail: 'wrong challenge' };
  if (f.securityLevel < 1) return { verified: false, detail: 'key is not in secure hardware' };
  if (f.deviceLocked === false || (f.verifiedBootState !== null && f.verifiedBootState !== 0)) {
    return { verified: false, detail: 'unlocked bootloader or modified OS (rooted?)' };
  }
  if (f.packages.length && !f.packages.includes(ANDROID_PACKAGE)) return { verified: false, detail: 'key made by another app' };
  return { verified: true, detail: f.securityLevel === 2 ? 'StrongBox' : 'TEE' };
}

export async function verifyAttestation(platform: string, publicKeySpki: string, attestation: string): Promise<AttestationResult> {
  if (config.attestationMode === 'dev') return { ok: true, type: 'dev', verified: null, detail: 'not checked (dev mode)' };
  let result: { verified: boolean | null; detail: string; type: string };
  try {
    if (platform === 'android') {
      const j = JSON.parse(attestation || '{}') as { chain?: string[] };
      const r = await verifyAndroid(j.chain ?? [], publicKeySpki);
      result = { ...r, type: 'android-key' };
    } else {
      result = { verified: null, detail: 'iOS App Attest not verified (needs Apple Team ID)', type: 'app-attest' };
    }
  } catch (e) {
    result = { verified: false, detail: `invalid attestation (${(e as Error).message})`, type: platform };
  }
  if (config.attestationMode === 'strict' && result.verified === false) return { ok: false, reason: result.detail };
  return { ok: true, ...result };
}
