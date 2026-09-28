import type { Occurrence } from '../domain/schedule.js';
import { audit } from '../lib/audit.js';
import { prisma } from '../lib/db.js';

/**
 * Record that a timetabled class did not happen. If the teacher's phone was merely offline
 * and syncs later, ingest revives the session (state TEACHER_NO_SHOW -> ACTIVE/ENDED).
 */
export async function secretlessNoShow(o: Occurrence) {
  const existing = await prisma.session.findUnique({ where: { key: o.key } });
  if (existing) return;
  await prisma.session.create({
    data: {
      key: o.key, shortId: o.shortId | 0, kind: 'TIMETABLE', sectionIds: o.sectionIds, teacherId: o.teacherId, roomId: o.roomId,
      scheduledStart: new Date(o.scheduledStart), scheduledEnd: new Date(o.scheduledEnd), plannedEnd: new Date(o.scheduledEnd),
      state: 'TEACHER_NO_SHOW',
    },
  });
  await audit(null, 'session.teacher_no_show', o.key, { teacherId: o.teacherId });
}
