import { DateTime } from 'luxon';
import { expandTimetable, type Occurrence } from '../domain/schedule.js';
import { config } from '../lib/config.js';
import { prisma } from '../lib/db.js';
import { loadCalendar } from './calendar.js';

export const localDate = (ms: number) => DateTime.fromMillis(ms, { zone: config.zone }).toISODate()!;
export const today = () => localDate(Date.now());
export const addDays = (date: string, n: number) => DateTime.fromISO(date, { zone: config.zone }).plus({ days: n }).toISODate()!;

export interface OccurrenceWithOverride extends Occurrence {
  cancelled: boolean;
  cancelReason: string | null;
  substituteId: string | null;
}

/** Timetable occurrences in a date range, with cancellations/substitutions applied. */
export async function occurrencesBetween(from: string, to: string, where: { sectionIds?: string[]; teacherId?: string } = {}) {
  const [slots, calendar, overrides] = await Promise.all([
    prisma.timetableSlot.findMany({
      where: where.sectionIds ? { sectionId: { in: where.sectionIds } } : {},
    }),
    loadCalendar(from, to),
    prisma.occurrenceOverride.findMany(),
  ]);
  // Combined sessions must be merged across all sections, so expand every slot of the
  // teachers involved, then filter.
  const teacherIds = new Set(slots.map((s) => s.teacherId));
  const allSlots = where.sectionIds ? await prisma.timetableSlot.findMany({ where: { teacherId: { in: [...teacherIds] } } }) : slots;
  const byKey = new Map(overrides.map((o) => [o.sessionKey, o]));
  return expandTimetable(allSlots, from, to, config.zone, calendar.lookup)
    .map((o): OccurrenceWithOverride => {
      const ov = byKey.get(o.key);
      return { ...o, cancelled: ov?.cancelled ?? false, cancelReason: ov?.reason ?? null, substituteId: ov?.substituteId ?? null };
    })
    .filter((o) => {
      if (where.sectionIds && !o.sectionIds.some((s) => where.sectionIds!.includes(s))) return false;
      if (where.teacherId && o.teacherId !== where.teacherId && o.substituteId !== where.teacherId) return false;
      return true;
    });
}

/** Timetable keys look like tt:YYYY-MM-DD:startMin:sections. */
export async function findOccurrence(key: string): Promise<OccurrenceWithOverride | null> {
  const m = /^tt:(\d{4}-\d{2}-\d{2}):/.exec(key);
  if (!m) return null;
  return (await occurrencesBetween(m[1], m[1])).find((o) => o.key === key) ?? null;
}
