// The classes a user sees (timetable occurrences + extra classes), merged with what
// actually happened. Used by the schedule, the calendar and the .ics feed.
import { sectionShortId } from '../crypto/protocol.js';
import { MIN, type Policy } from '../domain/policy.js';
import { startAllowed } from '../domain/schedule.js';
import type { AuthUser } from '../lib/auth.js';
import { prisma } from '../lib/db.js';
import { occurrencesBetween } from './occurrences.js';
import { settingsBySection } from './settings.js';
import { classLabel, currentSections, sectionInfo, taughtSections } from './teaching.js';

export type UiState = 'UPCOMING' | 'WAITING_TEACHER' | 'SCHEDULED' | 'ACTIVE' | 'ENDED' | 'CANCELLED' | 'TEACHER_NO_SHOW';

export async function listSessions(me: AuthUser, from: string, to: string, now: number, p: Policy) {
  const mySections =
    me.role === 'STUDENT' ? (await prisma.enrollment.findMany({ where: { studentId: me.id } })).map((e) => e.sectionId) : await taughtSections(me.id);
  const occ = await occurrencesBetween(from, to, me.role === 'STUDENT' ? { sectionIds: mySections } : { teacherId: me.id });
  const fromMs = new Date(`${from}T00:00:00Z`).getTime() - 24 * 60 * MIN;
  const toMs = new Date(`${to}T23:59:59Z`).getTime() + 24 * 60 * MIN;
  const rows = await prisma.session.findMany({
    where: {
      scheduledStart: { gte: new Date(fromMs), lte: new Date(toMs) },
      ...(me.role === 'STUDENT' ? { sectionIds: { hasSome: mySections } } : { OR: [{ teacherId: me.id }, { sectionIds: { hasSome: mySections } }] }),
    },
  });
  const byKey = new Map(rows.map((r) => [r.key, r]));
  const attendance =
    me.role === 'STUDENT'
      ? new Map(
          (await prisma.attendance.findMany({ where: { studentId: me.id, sessionId: { in: rows.map((r) => r.id) } } })).map((a) => [a.sessionId, a]),
        )
      : new Map();

  const items = [
    ...occ.map((o) => ({ ...o, kind: 'TIMETABLE' as const, title: null as string | null })),
    ...rows
      .filter((r) => r.kind === 'ADHOC')
      .map((r) => ({
        key: r.key, shortId: r.shortId >>> 0, sectionIds: r.sectionIds, teacherId: r.teacherId, roomId: r.roomId,
        scheduledStart: r.scheduledStart.getTime(), scheduledEnd: r.scheduledEnd.getTime(), kind: 'ADHOC' as const,
        title: r.title, cancelled: r.state === 'CANCELLED', cancelReason: r.cancelReason, substituteId: null,
      })),
  ];
  const teacherNames = new Map(
    (await prisma.user.findMany({ where: { id: { in: [...new Set(items.map((i) => i.teacherId))] } }, select: { id: true, name: true } })).map((u) => [u.id, u.name]),
  );
  const allSections = [...new Set(items.flatMap((i) => i.sectionIds))];
  const [settings, info] = await Promise.all([settingsBySection(allSections, p), sectionInfo(allSections)]);

  return items
    .sort((a, b) => a.scheduledStart - b.scheduledStart)
    .map((o) => {
      const s = byKey.get(o.key);
      let state: UiState = s?.state ?? 'UPCOMING';
      if (o.cancelled) state = 'CANCELLED';
      else if (!s && now >= o.scheduledStart) state = 'WAITING_TEACHER';
      const a = s && attendance.get(s.id);
      const set = [...o.sectionIds].sort().map((id) => settings.get(id)).find(Boolean);
      return {
        key: o.key,
        shortId: o.shortId,
        kind: o.kind,
        title: o.title,
        label: o.title ?? classLabel(info, o.sectionIds),
        subject: info.get(o.sectionIds[0])?.subject ?? null,
        sectionIds: o.sectionIds,
        teacherId: s?.teacherId ?? o.teacherId,
        teacherName: teacherNames.get(o.teacherId) ?? null,
        roomId: o.roomId,
        scheduledStart: o.scheduledStart,
        scheduledEnd: o.scheduledEnd,
        state,
        cancelReason: o.cancelReason ?? s?.cancelReason ?? null,
        actualStart: s?.actualStart?.getTime() ?? null,
        actualEnd: s?.actualEnd?.getTime() ?? null,
        plannedEnd: s?.plannedEnd.getTime() ?? o.scheduledEnd,
        substitutePending: s?.substitutePending ?? false,
        myStatus: a ? (a.override ?? a.computed) : null,
        myReasons: a?.reasons ?? [],
        canStart: me.role === 'TEACHER' && !s && !o.cancelled && startAllowed(o, now, p).ok,
        // Teacher's settings for this class (the phone plans with exactly these).
        plan: set?.plan ?? {},
        autoStart: set?.autoStart ?? true,
      };
    });
}

/** The subjects (sections) a user studies or teaches this semester, with labels and teacher settings. */
export async function mySubjects(me: AuthUser, p: Policy) {
  const all =
    me.role === 'STUDENT' ? (await prisma.enrollment.findMany({ where: { studentId: me.id } })).map((e) => e.sectionId) : await taughtSections(me.id);
  const ids = await currentSections(all);
  const [info, settings] = await Promise.all([sectionInfo(ids), settingsBySection(ids, p)]);
  return ids.map((id) => ({ ...info.get(id)!, sectionShortId: sectionShortId(id), plan: settings.get(id)?.plan ?? {}, autoStart: settings.get(id)?.autoStart ?? true }));
}
