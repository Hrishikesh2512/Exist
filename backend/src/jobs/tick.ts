// Runs every minute. Every step is idempotent, so a crash or a second server instance
// only repeats harmless work.
import type { FastifyBaseLogger } from 'fastify';
import { MIN } from '../domain/policy.js';
import { lifecycleActions } from '../domain/schedule.js';
import type { Interval } from '../domain/plan.js';
import { prisma } from '../lib/db.js';
import { notify, studentsOf } from '../lib/notify.js';
import { loadPolicy } from '../lib/policy.js';
import { secretlessNoShow } from '../services/noshow.js';
import { evaluateSession, recomputeSession } from '../services/attendance.js';
import { approveDeviceChange } from '../services/devices.js';
import { addDays, localDate, occurrencesBetween } from '../services/occurrences.js';
import { attendanceSummary, sectionReport } from '../services/reports.js';
import { teachersOf } from '../services/teaching.js';

const teachersOfAll = async (sectionIds: string[]) => [...new Set((await Promise.all(sectionIds.map(teachersOf))).flat())];
import { DateTime } from 'luxon';
import { config } from '../lib/config.js';

async function markSent(sessionKey: string, notice: string) {
  await prisma.setting.upsert({
    where: { key: `notice:${sessionKey}:${notice}` },
    create: { key: `notice:${sessionKey}:${notice}`, value: Date.now() },
    update: {},
  });
}

async function sentNotices(keys: string[]): Promise<Map<string, Set<string>>> {
  const rows = await prisma.setting.findMany({ where: { key: { in: keys.flatMap((k) => ['NOTIFY_STUDENTS_TEACHER_LATE', 'REMIND_TEACHER'].map((n) => `notice:${k}:${n}`)) } } });
  const m = new Map<string, Set<string>>();
  for (const r of rows) {
    const [, ...rest] = r.key.split(':');
    const notice = rest.pop()!;
    const key = rest.join(':');
    m.set(key, (m.get(key) ?? new Set()).add(notice));
  }
  return m;
}

export async function tick(now = Date.now()) {
  const p = await loadPolicy();

  // 1. Timetabled classes: late teacher notices, no-shows, forgotten sessions.
  const occ = (await occurrencesBetween(addDays(localDate(now), -1), localDate(now))).filter((o) => !o.cancelled && o.scheduledStart <= now);
  const sessions = new Map((await prisma.session.findMany({ where: { key: { in: occ.map((o) => o.key) } } })).map((s) => [s.key, s]));
  const sent = await sentNotices(occ.map((o) => o.key));
  for (const o of occ) {
    const s = sessions.get(o.key);
    const state = s && s.state !== 'SCHEDULED' ? {
      state: s.state as 'ACTIVE' | 'ENDED' | 'CANCELLED' | 'TEACHER_NO_SHOW',
      actualEnd: s.actualEnd?.getTime() ?? null,
      plannedEnd: s.plannedEnd.getTime(),
      lastActivityAt: (s.activity as Interval[]).at(-1)?.[1] ?? null,
    } : null;
    for (const a of lifecycleActions(o, state, now, sent.get(o.key) ?? new Set(), p)) {
      if (a.type === 'NOTIFY_STUDENTS_TEACHER_LATE') {
        await notify(await studentsOf(o.sectionIds), 'teacher.late', 'Teacher has not started class yet',
          'Stay in class. You will not be marked late for the teacher arriving late.', { sessionKey: o.key });
        await markSent(o.key, a.type);
      } else if (a.type === 'REMIND_TEACHER') {
        await notify(await teachersOfAll(o.sectionIds), 'teacher.reminder', 'Attendance not started',
          'Your class started 20 minutes ago but attendance is not running. Open Exist and tap Start, or cancel the class.', { sessionKey: o.key });
        await markSent(o.key, a.type);
      } else if (a.type === 'MARK_TEACHER_NO_SHOW') {
        await secretlessNoShow(o);
        await notify(await studentsOf(o.sectionIds), 'teacher.no_show', 'Class did not happen', 'It will not count against your attendance.', { sessionKey: o.key });
      } else if (a.type === 'AUTO_CLOSE' && s) {
        await prisma.session.update({ where: { id: s.id }, data: { state: 'ENDED', actualEnd: new Date(a.at) } });
        await recomputeSession(s.id);
        await notify([s.teacherId], 'session.auto_closed', 'Class closed automatically', 'You did not end the class; it was closed for you.', { sessionKey: s.key });
      }
    }
  }

  // 2. Extra classes: auto-close, and announced ones that never started.
  for (const s of await prisma.session.findMany({ where: { kind: 'ADHOC', state: { in: ['ACTIVE', 'SCHEDULED'] } } })) {
    if (s.state === 'SCHEDULED' && now > s.scheduledEnd.getTime()) {
      await prisma.session.update({ where: { id: s.id }, data: { state: 'TEACHER_NO_SHOW' } });
    } else if (s.state === 'ACTIVE' && !s.actualEnd && now >= s.plannedEnd.getTime() + p.autoCloseAfterMin * MIN) {
      const last = (s.activity as Interval[]).at(-1)?.[1] ?? s.plannedEnd.getTime();
      await prisma.session.update({ where: { id: s.id }, data: { state: 'ENDED', actualEnd: new Date(Math.min(last, s.plannedEnd.getTime())) } });
      await recomputeSession(s.id);
    }
  }

  // 3. Nudge students who have not checked in once START has closed (only when the teacher
  //    phone is syncing live, otherwise we cannot know).
  for (const s of await prisma.session.findMany({ where: { state: 'ACTIVE' } })) {
    // Phone auto-started on time, but nobody could reach it: the teacher is probably not in the room yet.
    const began = Math.max(s.actualStart?.getTime() ?? now, s.scheduledStart.getTime());
    const live = now - ((s.activity as Interval[]).at(-1)?.[1] ?? 0) < 2 * MIN;
    if (live && !(await prisma.checkIn.count({ where: { sessionId: s.id, valid: true } }))) {
      for (const [after, who, notice] of [
        [p.studentLateNoticeMin, 'students', 'EMPTY_STUDENTS'],
        [p.teacherReminderMin, 'teacher', 'EMPTY_TEACHER'],
      ] as const) {
        const k = `notice:${s.key}:${notice}`;
        if (now < began + after * MIN || (await prisma.setting.findUnique({ where: { key: k } }))) continue;
        if (who === 'students')
          await notify(await studentsOf(s.sectionIds), 'teacher.late', 'Teacher not in class yet',
            'Stay in class. You will not be marked late for the teacher arriving late.', { sessionKey: s.key });
        else
          await notify([s.teacherId], 'teacher.reminder', 'No student has checked in yet',
            'Is your phone in the classroom with Bluetooth on? Students check in automatically when it is nearby.', { sessionKey: s.key });
        await prisma.setting.create({ data: { key: k, value: now } });
      }
      continue;
    }
    const noticeKey = `notice:${s.key}:NUDGE_START`;
    if (await prisma.setting.findUnique({ where: { key: noticeKey } })) continue;
    const { windows, rows } = await evaluateSession(s.id, p);
    const start = windows.find((w) => w.kind === 'START');
    const lastSeen = (s.activity as Interval[]).at(-1)?.[1] ?? 0;
    if (!start || now < start.to || now - lastSeen > 2 * MIN) continue;
    const missing = rows.filter((r) => !r.evaluation.checks[0]?.passed && r.evaluation.status !== 'EXCUSED').map((r) => r.student.id);
    await notify(missing, 'checkin.missing', 'You are not checked in', 'If you are in class, open Exist near the teacher now.', { sessionKey: s.key });
    await prisma.setting.create({ data: { key: noticeKey, value: now } });
  }

  // 4. Device changes whose cooldown has passed.
  for (const r of await prisma.deviceChangeRequest.findMany({ where: { status: 'PENDING', eligibleAt: { lte: new Date(now) } } })) {
    await approveDeviceChange(r.id, 'auto');
  }

  // 5. After each class: summary to the teacher, and a personal note to anyone not marked present.
  const since = new Date(now - p.disputeWindowHours * 60 * MIN);
  for (const s of await prisma.session.findMany({ where: { state: 'ENDED', actualEnd: { gte: since } } })) {
    const key = `notice:${s.key}:SUMMARY`;
    if (await prisma.setting.findUnique({ where: { key } })) continue;
    if (now - ((s.activity as Interval[]).at(-1)?.[1] ?? 0) < 2 * MIN) continue; // phone still uploading
    await prisma.setting.create({ data: { key, value: now } });
    const rows = await prisma.attendance.findMany({ where: { sessionId: s.id } });
    if (!rows.length) continue;
    const counts: Record<string, number> = {};
    for (const r of rows) counts[r.override ?? r.computed] = (counts[r.override ?? r.computed] ?? 0) + 1;
    const label: Record<string, string> = { PRESENT: 'present', LATE: 'late', LEFT_EARLY: 'left early', FLAGGED: 'need review', ABSENT: 'absent', EXCUSED: 'excused', MANUAL: 'marked by you', UNVERIFIED: 'unverified' };
    const name = s.title ?? s.sectionIds.join(' + ');
    await notify([s.teacherId], 'class.summary', `${name}: attendance ready`,
      Object.entries(counts).map(([k, v]) => `${v} ${label[k] ?? k}`).join(', ') + (counts.FLAGGED ? '. Review flagged students in the app.' : '.'),
      { sessionKey: s.key });
    for (const r of rows) {
      const st = r.override ?? r.computed;
      if (!['ABSENT', 'LATE', 'LEFT_EARLY', 'FLAGGED'].includes(st)) continue;
      await notify([r.studentId], 'attendance.marked', `${name}: marked ${label[st]}`,
        `${r.reasons.join(', ') || 'See details in the app'}. If this is wrong, dispute it within ${p.disputeWindowHours} h.`, { sessionKey: s.key });
    }
  }

  // 6. Once a day: low-attendance warnings.
  const dayKey = `daily:${localDate(now)}`;
  if (!(await prisma.setting.findUnique({ where: { key: dayKey } }))) {
    await prisma.setting.create({ data: { key: dayKey, value: now } });
    for (const st of await prisma.user.findMany({ where: { role: 'STUDENT' }, select: { id: true } })) {
      const sum = await attendanceSummary(st.id);
      const low = sum.sections.filter((s) => s.total >= 5 && s.percent < sum.threshold);
      if (low.length)
        await notify([st.id], 'attendance.low', 'Attendance below requirement',
          low.map((s) => `${s.sectionId}: ${s.percent}%`).join(', '));
    }
    await absenceStreaks();
    if (DateTime.fromMillis(now, { zone: config.zone }).weekday === 1) await weeklyDigest(p.lowAttendanceThreshold);
  }
}

/** Three absences in a row in a section: tell the student and the teachers of that section. */
async function absenceStreaks() {
  const rows = await prisma.attendance.findMany({
    where: { session: { state: 'ENDED' } },
    include: { session: { select: { id: true, sectionIds: true, scheduledStart: true } } },
    orderBy: { session: { scheduledStart: 'desc' } },
  });
  const seen = new Map<string, typeof rows>(); // student|section -> latest rows
  for (const r of rows) {
    for (const sec of r.session.sectionIds) {
      const k = `${r.studentId}|${sec}`;
      const list = seen.get(k) ?? [];
      if (list.length < 3) seen.set(k, [...list, r]);
    }
  }
  for (const [k, list] of seen) {
    if (list.length < 3 || !list.every((r) => (r.override ?? r.computed) === 'ABSENT')) continue;
    const [studentId, sectionId] = k.split('|');
    const key = `streak:${k}:${list[0].sessionId}`;
    if (await prisma.setting.findUnique({ where: { key } })) continue;
    await prisma.setting.create({ data: { key, value: Date.now() } });
    const student = await prisma.user.findUnique({ where: { id: studentId }, select: { name: true, rollNo: true } });
    const teachers = await teachersOf(sectionId);
    await notify([studentId], 'attendance.streak', `Missed 3 classes in a row: ${sectionId}`, 'Talk to your teacher if something is wrong.');
    await notify(teachers, 'attendance.streak', `${student?.name ?? 'A student'} missed 3 in a row`, `${sectionId} · ${student?.rollNo ?? ''}`, { studentId, sectionId });
  }
}

/** Monday digest: each teacher's sections with average and at-risk students. */
async function weeklyDigest(threshold: number) {
  const slots = [...(await prisma.timetableSlot.findMany()), ...(await prisma.sectionTeacher.findMany())];
  const byTeacher = new Map<string, Set<string>>();
  for (const s of slots) byTeacher.set(s.teacherId, (byTeacher.get(s.teacherId) ?? new Set()).add(s.sectionId));
  for (const [teacherId, sections] of byTeacher) {
    const lines: string[] = [];
    for (const sec of [...sections].sort()) {
      const r = await sectionReport(sec);
      const counted = r.students.filter((s) => s.statuses.some(Boolean));
      if (!counted.length) continue;
      const avg = Math.round(counted.reduce((a, s) => a + s.percent, 0) / counted.length);
      const risk = counted.filter((s) => s.percent < threshold * 100).length;
      lines.push(`${sec}: ${avg}% avg${risk ? `, ${risk} below ${Math.round(threshold * 100)}%` : ''}`);
    }
    if (lines.length) await notify([teacherId], 'digest.weekly', 'Weekly attendance', lines.join('\n'));
  }
}

export function startJobs(log: FastifyBaseLogger) {
  let running = false;
  const run = async () => {
    if (running) return;
    running = true;
    try {
      await tick();
    } catch (e) {
      log.error(e, 'tick failed');
    } finally {
      running = false;
    }
  };
  setInterval(run, 60_000).unref();
  void run();
}
