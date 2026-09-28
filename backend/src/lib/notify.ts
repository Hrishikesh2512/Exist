// Every notification is stored (the app polls /me/notifications). Push delivery
// (FCM/APNs) plugs in through PushProvider; until configured, pushes are logged only.
import { prisma } from './db.js';

export interface PushProvider {
  send(userIds: string[], title: string, body: string, data: object): Promise<void>;
}

let provider: PushProvider = {
  async send(userIds, title) {
    if (process.env.NODE_ENV !== 'test') console.info(`[push:log] ${userIds.length} user(s): ${title}`);
  },
};
export const setPushProvider = (p: PushProvider) => (provider = p);

export async function notify(userIds: string[], kind: string, title: string, body: string, data: object = {}) {
  const ids = [...new Set(userIds)];
  if (!ids.length) return;
  await prisma.notification.createMany({ data: ids.map((userId) => ({ userId, kind, title, body, data })) });
  await provider.send(ids, title, body, { kind, ...data }).catch((e) => console.error('push failed', e));
}

export async function studentsOf(sectionIds: string[]): Promise<string[]> {
  const rows = await prisma.enrollment.findMany({ where: { sectionId: { in: sectionIds } }, select: { studentId: true } });
  return [...new Set(rows.map((r) => r.studentId))];
}
