import { DEFAULT_POLICY, type Policy } from '../domain/policy.js';
import { prisma } from './db.js';

export async function loadPolicy(): Promise<Policy> {
  const row = await prisma.setting.findUnique({ where: { key: 'policy' } });
  return { ...DEFAULT_POLICY, ...((row?.value as Partial<Policy>) ?? {}) };
}
