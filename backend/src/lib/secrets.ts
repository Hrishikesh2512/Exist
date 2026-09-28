// Session secrets are encrypted at rest with AES-256-GCM when SECRETS_KEY is set.
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { config } from './config.js';

const key = () => (config.secretsKey ? Buffer.from(config.secretsKey, 'base64') : null);

export function sealSecret(secret: Buffer): string {
  const k = key();
  if (!k) return `plain:${secret.toString('base64')}`;
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', k, iv);
  const enc = Buffer.concat([c.update(secret), c.final()]);
  return `gcm:${Buffer.concat([iv, c.getAuthTag(), enc]).toString('base64')}`;
}

export function openSecret(stored: string): Buffer {
  const [kind, b64] = stored.split(':');
  const raw = Buffer.from(b64, 'base64');
  if (kind === 'plain') return raw;
  const k = key();
  if (!k) throw new Error('SECRETS_KEY missing');
  const d = createDecipheriv('aes-256-gcm', k, raw.subarray(0, 12));
  d.setAuthTag(raw.subarray(12, 28));
  return Buffer.concat([d.update(raw.subarray(28)), d.final()]);
}
