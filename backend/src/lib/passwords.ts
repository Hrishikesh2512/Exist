import { randomBytes, scrypt as _scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
const scrypt = promisify(_scrypt) as (p: string, s: Buffer, n: number) => Promise<Buffer>;

export async function hashPassword(pw: string): Promise<string> {
  const salt = randomBytes(16);
  return `scrypt$${salt.toString('base64')}$${(await scrypt(pw, salt, 32)).toString('base64')}`;
}

export async function checkPassword(pw: string, stored: string): Promise<boolean> {
  const [alg, salt, hash] = stored.split('$');
  if (alg !== 'scrypt' || !salt || !hash) return false;
  const got = await scrypt(pw, Buffer.from(salt, 'base64'), 32);
  return timingSafeEqual(got, Buffer.from(hash, 'base64'));
}
