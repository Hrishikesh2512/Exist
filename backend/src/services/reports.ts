import type { AttendanceStatus } from '@prisma/client';
import { prisma } from '../lib/db.js';
import { loadPolicy } from '../lib/policy.js';
import { settingsBySection, settingsFor } from './settings.js';
import { classLabel, currentSections, sectionInfo } from './teaching.js';

const COUNTED: AttendanceStatus[] = ['PRESENT', 'LATE', 'LEFT_EARLY', 'FLAGGED', 'ABSENT', 'MANUAL', 'UNVERIFIED'];

export interface SectionStat {
  sectionId: string;
  total: number; // sessions that count (excused ones excluded)
  score: number; // weighted attended
  percent: number;
  counts: Partial<Record<AttendanceStatus, number>>;
}

/** Per-section summary for one student, plus recent records. */
export async function attendanceSummary(studentId: string) {
  const p = await loadPolicy();
  const rows = await prisma.attendance.findMany({
    where: { studentId },
    include: { session: { select: { key: true, sectionIds: true, scheduledStart: true, title: true } } },
    orderBy: { session: { scheduledStart: 'desc' } },
  });
  const sections = (await prisma.enrollment.findMany({ where: { studentId } })).map((e) => e.sectionId);
  const stats = new Map<string, SectionStat>(sections.map((id) => [id, { sectionId: id, total: 0, score: 0, percent: 100, counts: {} }]));
  const settings = await settingsBySection(sections, p);
  for (const r of rows) {
    const status = r.override ?? r.computed;
    for (const sec of r.session.sectionIds) {
      const st = stats.get(sec);
      if (!st) continue;
      st.counts[status] = (st.counts[status] ?? 0) + 1;
      if (COUNTED.includes(status)) {
        st.total++;
        st.score += (settings.get(sec)?.weights ?? p.weights)[status as keyof typeof p.weights];
      }
    }
  }
  for (const st of stats.values()) st.percent = st.total ? Math.round((st.score / st.total) * 1000) / 10 : 100;
  const current = new Set(await currentSections(sections));
  const info = await sectionInfo(sections);
  const all = [...stats.values()].filter((s) => current.has(s.sectionId));
  const total = all.reduce((a, s) => a + s.total, 0);
  const score = all.reduce((a, s) => a + s.score, 0);
  return {
    threshold: p.lowAttendanceThreshold * 100,
    /** This semester, all subjects together. */
    overall: { total, attended: Math.round(score * 10) / 10, percent: total ? Math.round((score / total) * 1000) / 10 : 100 },
    sections: [...stats.values()].map((s) => ({ ...s, current: current.has(s.sectionId), label: info.get(s.sectionId)?.label ?? s.sectionId, subject: info.get(s.sectionId)?.subject ?? null })),
    recent: rows.slice(0, 100).map((r) => ({
      label: r.session.title ?? classLabel(info, r.session.sectionIds),
      sessionKey: r.session.key, title: r.session.title, sectionIds: r.session.sectionIds,
      scheduledStart: r.session.scheduledStart.getTime(), status: r.override ?? r.computed, reasons: r.reasons, overridden: !!r.override,
    })),
  };
}

/** Section register: one row per student. */
export async function sectionReport(sectionId: string, from?: Date, to?: Date) {
  const p = await loadPolicy();
  const { weights } = await settingsFor([sectionId], p);
  const sessions = await prisma.session.findMany({
    where: { sectionIds: { has: sectionId }, state: 'ENDED', scheduledStart: { gte: from, lte: to } },
    orderBy: { scheduledStart: 'asc' },
  });
  const students = await prisma.user.findMany({
    where: { enrollments: { some: { sectionId } } }, select: { id: true, name: true, rollNo: true }, orderBy: { rollNo: 'asc' },
  });
  const att = await prisma.attendance.findMany({ where: { sessionId: { in: sessions.map((s) => s.id) } } });
  const cell = new Map(att.map((a) => [`${a.sessionId}|${a.studentId}`, a.override ?? a.computed]));
  return {
    sessions: sessions.map((s) => ({ key: s.key, start: s.scheduledStart.getTime(), substitutePending: s.substitutePending })),
    students: students.map((st) => {
      const statuses = sessions.map((s) => cell.get(`${s.id}|${st.id}`) ?? null);
      const counted = statuses.filter((x): x is AttendanceStatus => !!x && COUNTED.includes(x));
      const score = counted.reduce((a, s) => a + weights[s as keyof typeof weights], 0);
      return { ...st, statuses, percent: counted.length ? Math.round((score / counted.length) * 1000) / 10 : 100 };
    }),
  };
}

export function toCsv(r: Awaited<ReturnType<typeof sectionReport>>): string {
  const esc = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`;
  const head = ['Roll No', 'Name', ...r.sessions.map((s) => new Date(s.start).toISOString().slice(0, 16)), 'Percent'];
  const lines = r.students.map((s) => [s.rollNo, s.name, ...s.statuses.map((x) => x ?? ''), s.percent].map(esc).join(','));
  return [head.map(esc).join(','), ...lines].join('\n') + '\n';
}

/** One student's record in one subject group, class by class (for the teacher). */
export async function studentHistory(sectionId: string, studentId: string) {
  const rows = await prisma.attendance.findMany({
    where: { studentId, session: { sectionIds: { has: sectionId }, state: 'ENDED' } },
    include: { session: { select: { key: true, title: true, scheduledStart: true, actualStart: true } } },
    orderBy: { session: { scheduledStart: 'desc' } },
  });
  const student = await prisma.user.findUniqueOrThrow({ where: { id: studentId }, select: { id: true, name: true, rollNo: true } });
  const report = await sectionReport(sectionId);
  return {
    student,
    percent: report.students.find((s) => s.id === studentId)?.percent ?? null,
    records: rows.map((r) => ({
      sessionKey: r.session.key, title: r.session.title, start: (r.session.actualStart ?? r.session.scheduledStart).getTime(),
      status: r.override ?? r.computed, computed: r.computed, overridden: !!r.override, overrideReason: r.overrideReason, reasons: r.reasons,
    })),
  };
}
