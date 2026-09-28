// Expands the weekly timetable into dated occurrences, and decides what to do when a
// teacher is late, absent, or forgets to end a class.
import { DateTime } from 'luxon';
import { shortIdForKey } from '../crypto/protocol.js';
import { openDay, type DayLookup } from './calendar.js';
import { MIN, type Policy } from './policy.js';

export interface TimetableSlot {
  id: string;
  sectionId: string;
  teacherId: string;
  roomId: string | null;
  weekday: number; // 1 = Monday … 7 = Sunday (ISO)
  startMin: number; // minutes from local midnight
  endMin: number;
  validFrom: string; // YYYY-MM-DD (inclusive)
  validTo: string; // YYYY-MM-DD (inclusive)
}

export interface Occurrence {
  key: string;
  shortId: number;
  date: string;
  sectionIds: string[];
  slotIds: string[];
  teacherId: string;
  roomId: string | null;
  scheduledStart: number;
  scheduledEnd: number;
}

export function sessionKey(date: string, startMin: number, sectionIds: string[]): string {
  return `tt:${date}:${startMin}:${[...sectionIds].sort().join('+')}`;
}

/**
 * Occurrences between two local dates (inclusive). Slots taught by the same teacher at the
 * same time are merged into one combined session (e.g. two sections in one hall).
 */
export function expandTimetable(
  slots: TimetableSlot[],
  fromDate: string,
  toDate: string,
  zone: string,
  calendar: DayLookup | Set<string> = openDay, // a Set is a plain list of holiday dates
  cancelledSlotDates: Set<string> = new Set(), // `${slotId}@${date}`
): Occurrence[] {
  const lookup: DayLookup =
    calendar instanceof Set ? (d, w) => ({ weekday: w, blocked: () => (calendar.has(d) ? 'holiday' : null) }) : calendar;
  const out: Occurrence[] = [];
  let day = DateTime.fromISO(fromDate, { zone });
  const last = DateTime.fromISO(toDate, { zone });
  while (day <= last) {
    const date = day.toISODate()!;
    const plan = lookup(date, day.weekday);
    {
      const groups = new Map<string, TimetableSlot[]>();
      for (const s of slots) {
        if (s.weekday !== plan.weekday || date < s.validFrom || date > s.validTo) continue;
        if (plan.blocked(s.sectionId)) continue;
        if (cancelledSlotDates.has(`${s.id}@${date}`)) continue;
        const g = `${s.teacherId}|${s.startMin}|${s.endMin}`;
        groups.set(g, [...(groups.get(g) ?? []), s]);
      }
      for (const g of groups.values()) {
        const sectionIds = [...new Set(g.map((s) => s.sectionId))].sort();
        const key = sessionKey(date, g[0].startMin, sectionIds);
        out.push({
          key,
          shortId: shortIdForKey(key),
          date,
          sectionIds,
          slotIds: g.map((s) => s.id),
          teacherId: g[0].teacherId,
          roomId: g[0].roomId,
          scheduledStart: day.startOf('day').plus({ minutes: g[0].startMin }).toMillis(),
          scheduledEnd: day.startOf('day').plus({ minutes: g[0].endMin }).toMillis(),
        });
      }
    }
    day = day.plus({ days: 1 });
  }
  return out.sort((a, b) => a.scheduledStart - b.scheduledStart);
}

/** Whether a teacher may start this occurrence at `now`. */
export function startAllowed(o: { scheduledStart: number; scheduledEnd: number }, now: number, p: Policy): { ok: true } | { ok: false; reason: string } {
  if (now < o.scheduledStart - p.teacherEarlyStartMin * MIN) return { ok: false, reason: 'too early' };
  if (now > o.scheduledEnd - p.minSessionMin * MIN) return { ok: false, reason: 'too late; create an extra class instead' };
  return { ok: true };
}

export type LifecycleAction =
  | { type: 'NOTIFY_STUDENTS_TEACHER_LATE' }
  | { type: 'REMIND_TEACHER' }
  | { type: 'MARK_TEACHER_NO_SHOW' }
  | { type: 'AUTO_CLOSE'; at: number };

export interface SessionState {
  state: 'ACTIVE' | 'ENDED' | 'CANCELLED' | 'TEACHER_NO_SHOW';
  actualEnd: number | null;
  plannedEnd: number;
  lastActivityAt: number | null;
}

/**
 * What the server should do for an occurrence right now. `sent` holds notice types
 * already sent, so every action fires at most once.
 */
export function lifecycleActions(
  o: Occurrence,
  session: SessionState | null,
  now: number,
  sent: Set<string>,
  p: Policy,
): LifecycleAction[] {
  const actions: LifecycleAction[] = [];
  if (!session) {
    const late = now - o.scheduledStart;
    const noShowAt = o.scheduledEnd - p.minSessionMin * MIN;
    if (now >= noShowAt) return [{ type: 'MARK_TEACHER_NO_SHOW' }];
    if (late >= p.studentLateNoticeMin * MIN && !sent.has('NOTIFY_STUDENTS_TEACHER_LATE'))
      actions.push({ type: 'NOTIFY_STUDENTS_TEACHER_LATE' });
    if (late >= p.teacherReminderMin * MIN && !sent.has('REMIND_TEACHER'))
      actions.push({ type: 'REMIND_TEACHER' });
    return actions;
  }
  if (session.state === 'ACTIVE' && session.actualEnd === null && now >= session.plannedEnd + p.autoCloseAfterMin * MIN) {
    // Teacher forgot to end, or the phone died. Close at the last sign of life.
    actions.push({ type: 'AUTO_CLOSE', at: Math.min(session.lastActivityAt ?? session.plannedEnd, session.plannedEnd) });
  }
  return actions;
}
