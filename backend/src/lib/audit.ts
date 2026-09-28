import { prisma } from './db.js';
export function audit(actorId: string | null, action: string, target: string, payload: object = {}) {
  return prisma.auditLog.create({ data: { actorId, action, target, payload } });
}
