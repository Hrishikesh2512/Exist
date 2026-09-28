// Teacher controls: per-section settings, section overview, whole-class actions, reschedule.
import { randomBytes, randomUUID } from 'node:crypto';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { shortIdForKey } from '../crypto/protocol.js';
import { MIN } from '../domain/policy.js';
import { requireRole } from '../lib/auth.js';
import { audit } from '../lib/audit.js';
import { config } from '../lib/config.js';
import { prisma } from '../lib/db.js';
import { bad, forbidden, notFound } from '../lib/http.js';
import { notify, studentsOf } from '../lib/notify.js';
import { loadPolicy } from '../lib/policy.js';
import { findOccurrence } from '../services/occurrences.js';
import { sectionReport, studentHistory } from '../services/reports.js';
import { hashPassword } from '../lib/passwords.js';
import { settingsFor } from '../services/settings.js';
import { sectionInfo, taughtSections, teaches } from '../services/teaching.js';

const statusEnum = z.enum(['PRESENT', 'LATE', 'LEFT_EARLY', 'FLAGGED', 'ABSENT', 'EXCUSED', 'MANUAL', 'UNVERIFIED']);
const fmt = (ms: number) =>
  new Date(ms).toLocaleString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit', timeZone: config.zone });

async function assertTeaches(req: FastifyRequest, sectionId: string) {
  if (!(await teaches(req.user.id, [sectionId]))) throw forbidden('you do not teach this subject');
}

export const settingsBody = z.object({
  autoStart: z.boolean().optional(),
  midChecks: z.number().int().min(0).max(3).nullable().optional(),
  startWindowMin: z.number().int().min(5).max(30).nullable().optional(),
  endWindowMin: z.number().int().min(3).max(20).nullable().optional(),
  lateWeight: z.number().min(0).max(1).nullable().optional(),
  leftEarlyWeight: z.number().min(0).max(1).nullable().optional(),
  manualQuota: z.number().int().min(0).max(10).nullable().optional(),
});

export async function teacherRoutes(app: FastifyInstance) {
  const staff = { preHandler: requireRole('TEACHER') };

  /** My sections at a glance: size, average attendance, students at risk. */
  app.get('/teacher/sections', staff, async (req) => {
    const p = await loadPolicy();
    const sectionIds = await taughtSections(req.user.id);
    return Promise.all(
      sectionIds.map(async (id) => {
        const [section, r, settings] = await Promise.all([
          prisma.section.findUnique({ where: { id }, include: { course: true } }),
          sectionReport(id),
          prisma.sectionSettings.findUnique({ where: { sectionId: id } }),
        ]);
        const counted = r.students.filter((s) => s.statuses.some(Boolean));
        const avg = counted.length ? counted.reduce((a, s) => a + s.percent, 0) / counted.length : null;
        return {
          sectionId: id,
          course: section?.course ? { code: section.course.code, name: section.course.name } : null,
          students: r.students.length,
          classesHeld: r.sessions.length,
          averagePercent: avg === null ? null : Math.round(avg * 10) / 10,
          atRisk: r.students.filter((s) => s.statuses.some(Boolean) && s.percent < p.lowAttendanceThreshold * 100)
            .map((s) => ({ id: s.id, name: s.name, rollNo: s.rollNo, percent: s.percent })),
          settings,
        };
      }),
    );
  });

  /** Every student of a subject group with their attendance so far. */
  app.get('/sections/:id/students', staff, async (req) => {
    const { id } = req.params as { id: string };
    await assertTeaches(req, id);
    const r = await sectionReport(id);
    const info = (await sectionInfo([id])).get(id)!;
    return {
      section: info,
      classesHeld: r.sessions.length,
      students: r.students.map((s) => ({
        id: s.id, name: s.name, rollNo: s.rollNo, percent: s.percent,
        attended: s.statuses.filter((x) => x && ['PRESENT', 'LATE', 'MANUAL'].includes(x)).length,
        counted: s.statuses.filter((x) => x && x !== 'EXCUSED').length,
      })),
    };
  });

  app.get('/sections/:id/students/:studentId', staff, async (req) => {
    const { id, studentId } = req.params as { id: string; studentId: string };
    await assertTeaches(req, id);
    if (!(await prisma.enrollment.count({ where: { sectionId: id, studentId } }))) throw notFound('student is not in this subject');
    return studentHistory(id, studentId);
  });

  /** Forgot password: a teacher can reset it for their own students, an admin for anyone. */
  app.post('/users/:id/reset-password', staff, async (req) => {
    const { id } = req.params as { id: string };
    const u = await prisma.user.findUniqueOrThrow({ where: { id } });
    if (u.role !== 'STUDENT') throw forbidden();
    const mine = await taughtSections(req.user.id);
    if (!(await prisma.enrollment.count({ where: { studentId: id, sectionId: { in: mine } } }))) throw forbidden('not your student');
    const temp = randomBytes(6).toString('base64url');
    await prisma.user.update({ where: { id }, data: { passwordHash: await hashPassword(temp), mustChangePassword: true, sessionVersion: { increment: 1 } } });
    await audit(req.user.id, 'password.reset', id);
    return { temporaryPassword: temp };
  });

  app.get('/sections/:id/settings', staff, async (req) => {
    const { id } = req.params as { id: string };
    await assertTeaches(req, id);
    const p = await loadPolicy();
    return {
      stored: await prisma.sectionSettings.findUnique({ where: { sectionId: id } }),
      effective: await settingsFor([id], p),
      defaults: { startWindowMin: p.startWindowMin, endWindowMin: p.endWindowMin, midChecks: null, weights: p.weights, manualQuota: p.manualQuotaPerTerm },
    };
  });

  /** Changes apply to classes started after saving (a running class keeps its plan). */
  app.put('/sections/:id/settings', staff, async (req) => {
    const { id } = req.params as { id: string };
    await assertTeaches(req, id);
    const b = settingsBody.parse(req.body);
    const row = await prisma.sectionSettings.upsert({
      where: { sectionId: id },
      create: { sectionId: id, ...b, updatedBy: req.user.id },
      update: { ...b, updatedBy: req.user.id },
    });
    await audit(req.user.id, 'section.settings', id, b);
    return row;
  });

  /** Whole-class decision, e.g. field trip ("everyone present") or a class that shouldn't count. */
  app.post('/sessions/:key/bulk', staff, async (req) => {
    const s = await prisma.session.findUnique({ where: { key: (req.params as { key: string }).key } });
    if (!s) throw notFound();
    if (!(await teaches(req.user.id, s.sectionIds))) throw forbidden();
    if (s.state !== 'ENDED') throw bad('class has not ended');
    const b = z.object({ status: statusEnum, onlyNotPresent: z.boolean().default(true), reason: z.string().min(2).max(300) }).parse(req.body);
    const rows = await prisma.attendance.findMany({ where: { sessionId: s.id } });
    const targets = rows.filter((r) => !b.onlyNotPresent || !['PRESENT', 'MANUAL', 'EXCUSED'].includes(r.override ?? r.computed));
    await prisma.$transaction(
      targets.map((r) =>
        prisma.attendance.update({
          where: { sessionId_studentId: { sessionId: s.id, studentId: r.studentId } },
          data: { override: b.status, overrideBy: req.user.id, overrideReason: b.reason },
        }),
      ),
    );
    await audit(req.user.id, 'attendance.bulk', s.key, { ...b, count: targets.length });
    return { updated: targets.length };
  });

  /** Move a class: the original is cancelled and an extra class is created at the new time. */
  app.post('/sessions/reschedule', { preHandler: requireRole('TEACHER') }, async (req) => {
    const b = z.object({ key: z.string(), scheduledStart: z.number(), scheduledEnd: z.number(), reason: z.string().max(300).default('Class moved') }).parse(req.body);
    if (b.scheduledEnd <= b.scheduledStart || b.scheduledEnd - b.scheduledStart > 6 * 60 * MIN) throw bad('bad times');
    if (b.scheduledStart < Date.now() - 5 * MIN) throw bad('new time is in the past');
    const existing = await prisma.session.findUnique({ where: { key: b.key } });
    if (existing && existing.state !== 'SCHEDULED') throw bad('class already started or finished');
    let sectionIds: string[];
    let roomId: string | null = null;
    if (existing) {
      if (existing.teacherId !== req.user.id) throw forbidden();
      sectionIds = existing.sectionIds;
      await prisma.session.update({ where: { id: existing.id }, data: { state: 'CANCELLED', cancelReason: `${b.reason} → ${fmt(b.scheduledStart)}` } });
    } else {
      const occ = await findOccurrence(b.key);
      if (!occ) throw notFound();
      if (occ.teacherId !== req.user.id && occ.substituteId !== req.user.id) throw forbidden();
      if (occ.cancelled) throw bad('class is cancelled');
      ({ sectionIds, roomId } = occ);
      await prisma.occurrenceOverride.upsert({
        where: { sessionKey: b.key },
        create: { sessionKey: b.key, cancelled: true, reason: `${b.reason} → ${fmt(b.scheduledStart)}`, createdBy: req.user.id },
        update: { cancelled: true, reason: `${b.reason} → ${fmt(b.scheduledStart)}` },
      });
    }
    const key = `adhoc:${randomUUID()}`;
    await prisma.session.create({
      data: {
        key, shortId: shortIdForKey(key) | 0, kind: 'ADHOC', sectionIds, teacherId: req.user.id, roomId, title: `${sectionIds.join(' + ')} (moved)`,
        scheduledStart: new Date(b.scheduledStart), scheduledEnd: new Date(b.scheduledEnd), plannedEnd: new Date(b.scheduledEnd), state: 'SCHEDULED',
      },
    });
    await notify(await studentsOf(sectionIds), 'class.moved', 'Class moved', `${sectionIds.join(' + ')} is now on ${fmt(b.scheduledStart)}. ${b.reason}`, { sessionKey: key, from: b.key });
    await audit(req.user.id, 'session.rescheduled', b.key, { to: key, ...b });
    return { key };
  });
}

