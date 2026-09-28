import { randomBytes } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { DateTime } from 'luxon';
import { z } from 'zod';
import { requireRole, type AuthUser } from '../lib/auth.js';
import { audit } from '../lib/audit.js';
import { config } from '../lib/config.js';
import { prisma } from '../lib/db.js';
import { bad, forbidden, notFound } from '../lib/http.js';
import { notify, studentsOf } from '../lib/notify.js';
import { loadPolicy } from '../lib/policy.js';
import { loadCalendar } from '../services/calendar.js';
import { addDays, localDate, today } from '../services/occurrences.js';
import { taughtSections } from '../services/teaching.js';
import { listSessions } from '../services/userSessions.js';

const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
const eventBody = z
  .object({
    kind: z.enum(['HOLIDAY', 'EXAM', 'EVENT', 'DAY_ORDER']),
    title: z.string().min(1).max(200),
    fromDate: date,
    toDate: date,
    noClasses: z.boolean().default(true),
    followsWeekday: z.number().int().min(1).max(7).nullable().default(null),
    sectionIds: z.array(z.string()).default([]),
  })
  .refine((e) => e.toDate >= e.fromDate, 'toDate before fromDate')
  .refine((e) => e.kind !== 'DAY_ORDER' || e.followsWeekday, 'DAY_ORDER needs followsWeekday');

async function mySections(me: AuthUser): Promise<string[]> {
  if (me.role === 'STUDENT') return (await prisma.enrollment.findMany({ where: { studentId: me.id } })).map((e) => e.sectionId);
  return taughtSections(me.id);
}

async function calendarFor(me: AuthUser, from: string, to: string) {
  const p = await loadPolicy();
  const [{ entries }, sessions, sections, personal] = await Promise.all([
    loadCalendar(from, to),
    listSessions(me, from, to, Date.now(), p),
    mySections(me),
    prisma.personalEvent.findMany({ where: { userId: me.id, date: { gte: from, lte: to } }, orderBy: [{ date: 'asc' }, { startMin: 'asc' }] }),
  ]);
  const events = entries.filter((e) => e.sectionIds.length === 0 || e.sectionIds.some((s) => sections.includes(s)));
  return { events, personal, sessions: sessions.filter((s) => localDate(s.scheduledStart) >= from && localDate(s.scheduledStart) <= to) };
}

// ---- iCalendar feed (RFC 5545), so classes and holidays show up in Google/Apple Calendar.
const icsText = (s: string) => s.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n');
const icsTime = (ms: number) => DateTime.fromMillis(ms, { zone: 'utc' }).toFormat("yyyyMMdd'T'HHmmss'Z'");
const icsDate = (d: string) => d.replace(/-/g, '');

export function toIcs(name: string, cal: Awaited<ReturnType<typeof calendarFor>>): string {
  const stamp = icsTime(Date.now());
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Exist//Attendance//EN', 'CALSCALE:GREGORIAN', `X-WR-CALNAME:${icsText(name)}`];
  for (const s of cal.sessions) {
    const status = s.state === 'CANCELLED' || s.state === 'TEACHER_NO_SHOW' ? 'CANCELLED' : 'CONFIRMED';
    lines.push(
      'BEGIN:VEVENT', `UID:${icsText(s.key)}@exist`, `DTSTAMP:${stamp}`, `DTSTART:${icsTime(s.scheduledStart)}`, `DTEND:${icsTime(s.scheduledEnd)}`,
      `SUMMARY:${icsText((s.title ?? s.sectionIds.join(' + ')) + (s.state === 'CANCELLED' ? ' (cancelled)' : ''))}`,
      ...(s.roomId ? [`LOCATION:${icsText(s.roomId)}`] : []),
      ...(s.teacherName ? [`DESCRIPTION:${icsText(`Teacher: ${s.teacherName}`)}`] : []),
      `STATUS:${status}`, 'END:VEVENT',
    );
  }
  for (const e of cal.events) {
    lines.push(
      'BEGIN:VEVENT', `UID:${e.id}@exist`, `DTSTAMP:${stamp}`, `DTSTART;VALUE=DATE:${icsDate(e.fromDate)}`,
      `DTEND;VALUE=DATE:${icsDate(DateTime.fromISO(e.toDate).plus({ days: 1 }).toISODate()!)}`,
      `SUMMARY:${icsText(e.title)}`, `CATEGORIES:${e.kind}`, 'TRANSP:TRANSPARENT', 'END:VEVENT',
    );
  }
  for (const e of cal.personal) {
    const day = DateTime.fromISO(e.date, { zone: config.zone });
    lines.push('BEGIN:VEVENT', `UID:${e.id}@exist`, `DTSTAMP:${stamp}`,
      ...(e.startMin === null
        ? [`DTSTART;VALUE=DATE:${icsDate(e.date)}`, `DTEND;VALUE=DATE:${icsDate(day.plus({ days: 1 }).toISODate()!)}`]
        : [`DTSTART:${icsTime(day.plus({ minutes: e.startMin }).toMillis())}`, `DTEND:${icsTime(day.plus({ minutes: e.endMin ?? e.startMin + 60 }).toMillis())}`]),
      `SUMMARY:${icsText(e.title)}`, ...(e.note ? [`DESCRIPTION:${icsText(e.note)}`] : []), 'END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  return lines.join('\r\n') + '\r\n';
}

export async function calendarRoutes(app: FastifyInstance) {
  /** Month view data: classes (with my status), holidays, exams, events and terms. */
  app.get('/me/calendar', { preHandler: requireRole() }, async (req) => {
    const q = z.object({ from: date, to: date }).parse(req.query);
    const span = DateTime.fromISO(q.to).diff(DateTime.fromISO(q.from), 'days').days;
    if (span < 0 || span > 62) throw bad('range must be 0–62 days');
    return calendarFor(req.user, q.from, q.to);
  });

  /** Private feed URL to subscribe to in a calendar app. */
  app.get('/me/calendar-link', { preHandler: requireRole('STUDENT', 'TEACHER') }, async (req) => {
    let u = await prisma.user.findUniqueOrThrow({ where: { id: req.user.id } });
    if (!u.calendarToken) u = await prisma.user.update({ where: { id: u.id }, data: { calendarToken: randomBytes(24).toString('base64url') } });
    return { path: `/calendar/${u.calendarToken}.ics` };
  });

  app.post('/me/calendar-link/reset', { preHandler: requireRole('STUDENT', 'TEACHER') }, async (req) => {
    const u = await prisma.user.update({ where: { id: req.user.id }, data: { calendarToken: randomBytes(24).toString('base64url') } });
    return { path: `/calendar/${u.calendarToken}.ics` };
  });

  app.get('/calendar/:file', async (req, rep) => {
    const { file } = req.params as { file: string };
    const token = file.replace(/\.ics$/, '');
    const u = token ? await prisma.user.findUnique({ where: { calendarToken: token } }) : null;
    if (!u || u.disabledAt) throw notFound();
    const cal = await calendarFor({ id: u.id, role: u.role }, addDays(today(), -14), addDays(today(), 60));
    return rep.header('content-type', 'text/calendar; charset=utf-8').send(toIcs(`Exist · ${u.name}`, cal));
  });

  // ---- Teacher: days for their own classes: no class (holiday), test, event.
  app.post('/calendar/section-event', { preHandler: requireRole('TEACHER') }, async (req) => {
    const b = eventBody.parse(req.body);
    if (b.kind === 'DAY_ORDER') throw bad('not available');
    const mine = await mySections(req.user);
    if (!b.sectionIds.length || !b.sectionIds.every((s) => mine.includes(s))) throw forbidden('only for your own classes');
    // A "no class" day only affects the chosen classes, which this teacher teaches.
    const e = await prisma.calendarEvent.create({ data: { ...b, noClasses: b.kind === 'HOLIDAY' ? true : b.noClasses, createdBy: req.user.id } });
    await announce(e, req.user.id);
    return e;
  });

  app.delete('/calendar/section-event/:id', { preHandler: requireRole('TEACHER') }, async (req) => {
    const e = await prisma.calendarEvent.findUniqueOrThrow({ where: { id: (req.params as { id: string }).id } });
    const mine = await mySections(req.user);
    if (e.createdBy !== req.user.id && !(e.sectionIds.length && e.sectionIds.every((x) => mine.includes(x)))) throw forbidden();
    await prisma.calendarEvent.delete({ where: { id: e.id } });
    return { ok: true };
  });
}

/** Everyone's own calendar entries (study plan, reminders). Only the owner sees them. */
export async function personalEventRoutes(app: FastifyInstance) {
  const me = { preHandler: requireRole() };
  const body = z.object({
    title: z.string().trim().min(1).max(200),
    date,
    start: z.string().regex(/^\d{1,2}:\d{2}$/).optional(),
    end: z.string().regex(/^\d{1,2}:\d{2}$/).optional(),
    note: z.string().max(1000).optional(),
  });
  const mins = (t?: string) => (t ? Number(t.split(':')[0]) * 60 + Number(t.split(':')[1]) : null);
  app.post('/me/events', me, async (req) => {
    const b = body.parse(req.body);
    const startMin = mins(b.start), endMin = mins(b.end);
    if (startMin !== null && endMin !== null && endMin <= startMin) throw bad('end must be after start');
    return prisma.personalEvent.create({ data: { userId: req.user.id, title: b.title, date: b.date, startMin, endMin, note: b.note } });
  });
  app.delete('/me/events/:id', me, async (req) => {
    await prisma.personalEvent.deleteMany({ where: { id: (req.params as { id: string }).id, userId: req.user.id } });
    return { ok: true };
  });
}

async function announce(
  e: { id: string; kind: string; title: string; fromDate: string; toDate: string; noClasses: boolean; followsWeekday: number | null; sectionIds: string[] },
  actor: string,
) {
  await audit(actor, 'calendar.created', e.id, e);
  if (e.fromDate < localDate(Date.now())) return;
  const who = await studentsOf(e.sectionIds);
  const when = e.fromDate === e.toDate ? e.fromDate : `${e.fromDate} to ${e.toDate}`;
  const days = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const suffix =
    e.kind === 'DAY_ORDER' ? ` ${days[e.followsWeekday ?? 0]}'s timetable runs.` : e.kind === 'HOLIDAY' || e.noClasses ? ' No classes.' : '';
  await notify(who, `calendar.${e.kind.toLowerCase()}`, e.title, `${when}.${suffix}`, { eventId: e.id });
}

export { calendarFor };
