import type { Session } from '@prisma/client';
import { classView, evaluateStudent, type Evaluation, type Status } from '../domain/evaluate.js';
import { HttpError } from '../lib/http.js';
import { planChecks, withExtraChecks, type CheckWindow, type Interval, type SessionTimes } from '../domain/plan.js';
import { clampPlan, withPlan, type Policy } from '../domain/policy.js';
import { prisma } from '../lib/db.js';
import { loadPolicy } from '../lib/policy.js';
import { openSecret } from '../lib/secrets.js';
import { localDate } from './occurrences.js';

export function timesOf(s: Session): SessionTimes | null {
  if (!s.actualStart) return null;
  return {
    scheduledStart: s.scheduledStart.getTime(),
    scheduledEnd: s.scheduledEnd.getTime(),
    actualStart: s.actualStart.getTime(),
    actualEnd: s.actualEnd?.getTime() ?? null,
    plannedEnd: s.plannedEnd.getTime(),
  };
}

/** The plan exactly as the teacher's phone ran it: its settings, plus any surprise checks. */
export function windowsOf(s: Session, p: Policy): CheckWindow[] {
  const t = timesOf(s);
  if (!t || !s.secret) return [];
  const base = planChecks(openSecret(s.secret), t, withPlan(p, clampPlan(s.plan as Record<string, unknown>)));
  return withExtraChecks(base, (s.extraChecks as Interval[]) ?? []);
}

/** Per-student evaluation for a session (live while ACTIVE, final once ENDED). */
export async function evaluateSession(sessionId: string, p?: Policy) {
  p ??= await loadPolicy();
  const s = await prisma.session.findUniqueOrThrow({ where: { id: sessionId } });
  const windows = windowsOf(s, p);
  const activity = s.activity as Interval[];
  const date = localDate(s.scheduledStart.getTime());
  const [students, checkins, manual, excuses] = await Promise.all([
    prisma.user.findMany({
      where: { enrollments: { some: { sectionId: { in: s.sectionIds } } } },
      select: { id: true, name: true, rollNo: true },
      orderBy: { rollNo: 'asc' },
    }),
    prisma.checkIn.findMany({ where: { sessionId, valid: true }, select: { studentId: true, receivedAt: true } }),
    prisma.manualMark.findMany({ where: { sessionId } }),
    prisma.excuse.findMany({
      where: { fromDate: { lte: date }, toDate: { gte: date }, OR: [{ sectionIds: { isEmpty: true } }, { sectionIds: { hasSome: s.sectionIds } }] },
    }),
  ]);
  const times = new Map<string, number[]>();
  for (const c of checkins) if (c.studentId) times.set(c.studentId, [...(times.get(c.studentId) ?? []), c.receivedAt.getTime()]);
  const manualSet = new Set(manual.map((m) => m.studentId));
  const excusedSet = new Set(excuses.map((e) => e.studentId));
  const view = classView(windows, students.map((st) => times.get(st.id) ?? []), students.length, p);
  const rows: { student: (typeof students)[number]; evaluation: Evaluation }[] = students.map((student) => ({
    student,
    evaluation: evaluateStudent(view, activity, {
      checkinTimes: times.get(student.id) ?? [],
      excused: excusedSet.has(student.id),
      manual: manualSet.has(student.id),
    }, p),
  }));
  return { session: s, windows: view.windows, rows };
}

/** Store final statuses. Sessions that did not happen hold no attendance. */
export async function recomputeSession(sessionId: string) {
  const s = await prisma.session.findUniqueOrThrow({ where: { id: sessionId } });
  if (s.state !== 'ENDED') {
    await prisma.attendance.deleteMany({ where: { sessionId, override: null } });
    return;
  }
  const { rows } = await evaluateSession(sessionId);
  await prisma.$transaction(
    rows.map(({ student, evaluation }) =>
      prisma.attendance.upsert({
        where: { sessionId_studentId: { sessionId, studentId: student.id } },
        create: { sessionId, studentId: student.id, computed: evaluation.status, reasons: evaluation.reasons },
        update: { computed: evaluation.status, reasons: evaluation.reasons },
      }),
    ),
  );
}

/**
 * Teacher's decision for one student in one class. Works during class too (the row is created
 * and later computations keep the override). status null removes the override.
 */
export async function setOverride(sessionId: string, sectionIds: string[], studentId: string, status: Status | null, by: string, reason: string) {
  if (!(await prisma.enrollment.count({ where: { studentId, sectionId: { in: sectionIds } } }))) throw new HttpError(404, 'student not in this class');
  const key = { sessionId_studentId: { sessionId, studentId } };
  const before = await prisma.attendance.findUnique({ where: key });
  const data = { override: status, overrideBy: status ? by : null, overrideReason: status ? reason : null };
  if (before) await prisma.attendance.update({ where: key, data });
  else if (status) await prisma.attendance.create({ data: { sessionId, studentId, computed: 'UNVERIFIED', reasons: [], ...data } });
  return before;
}
