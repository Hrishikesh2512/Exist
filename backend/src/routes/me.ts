import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { decodeCheckIn } from '../crypto/protocol.js';
import { MIN } from '../domain/policy.js';
import { requireRole } from '../lib/auth.js';
import { prisma } from '../lib/db.js';
import { bad, forbidden } from '../lib/http.js';
import { loadPolicy } from '../lib/policy.js';
import { ingestCheckIn } from '../services/ingest.js';
import { recomputeSession } from '../services/attendance.js';
import { addDays, today } from '../services/occurrences.js';
import { listSessions, mySubjects } from '../services/userSessions.js';
import { attendanceSummary, studentHistory } from '../services/reports.js';

export async function meRoutes(app: FastifyInstance) {
  /**
   * Everything a phone needs to run the next few days offline: sessions with their
   * BLE identifiers, and for teachers the roster with student public keys.
   */
  app.get('/me/schedule', { preHandler: requireRole('STUDENT', 'TEACHER') }, async (req) => {
    const { days } = z.object({ days: z.coerce.number().min(1).max(14).default(7) }).parse(req.query);
    const me = req.user;
    const p = await loadPolicy();
    const now = Date.now();
    const sessions = await listSessions(me, addDays(today(), -1), addDays(today(), days), now, p);

    const subjects = await mySubjects(me, p);
    let roster: Record<string, { id: string; name: string; rollNo: string | null; deviceId: string | null; publicKeySpki: string | null }[]> | undefined;
    if (me.role === 'TEACHER') {
      // Every subject group the teacher teaches (classes can be started at any time), plus any in the schedule.
      const sectionIds = [...new Set([...subjects.map((s) => s.id), ...sessions.flatMap((s) => s.sectionIds)])];
      const enr = await prisma.enrollment.findMany({
        where: { sectionId: { in: sectionIds } },
        include: { student: { select: { id: true, name: true, rollNo: true, devices: { where: { revokedAt: null } } } } },
      });
      roster = {};
      for (const e of enr) {
        const d = e.student.devices[0];
        (roster[e.sectionId] ??= []).push({ id: e.student.id, name: e.student.name, rollNo: e.student.rollNo, deviceId: d?.id ?? null, publicKeySpki: d?.publicKeySpki ?? null });
      }
    }
    return { serverNow: now, policy: p, sessions, subjects, roster };
  });

  app.get('/me/attendance', { preHandler: requireRole('STUDENT') }, async (req) => attendanceSummary(req.user.id));

  /** My attendance sheet for one class, class by class. */
  app.get('/me/classes/:id/sheet', { preHandler: requireRole('STUDENT') }, async (req) => {
    const { id } = req.params as { id: string };
    if (!(await prisma.enrollment.count({ where: { sectionId: id, studentId: req.user.id } }))) throw forbidden('you are not in this class');
    return studentHistory(id, req.user.id);
  });

  app.get('/me/notifications', { preHandler: requireRole() }, async (req) => {
    const { since } = z.object({ since: z.coerce.number().default(0) }).parse(req.query);
    return prisma.notification.findMany({
      where: { userId: req.user.id, createdAt: { gt: new Date(since) } },
      orderBy: { createdAt: 'desc' },
      take: 100,
    });
  });

  app.post('/me/notifications/read', { preHandler: requireRole() }, async (req) => {
    await prisma.notification.updateMany({ where: { userId: req.user.id, readAt: null }, data: { readAt: new Date() } });
    return { ok: true };
  });

  /** Backup path: student scans the rotating QR shown on the classroom screen. */
  app.post('/checkins/qr', { preHandler: requireRole('STUDENT') }, async (req) => {
    const { sessionKey, rawB64 } = z.object({ sessionKey: z.string(), rawB64: z.string().max(400) }).parse(req.body);
    const device = await prisma.device.findFirst({ where: { userId: req.user.id, revokedAt: null } });
    if (!device) throw bad('bind this phone first');
    let deviceId: string;
    try {
      deviceId = decodeCheckIn(Buffer.from(rawB64, 'base64')).deviceId;
    } catch {
      throw bad('malformed check-in');
    }
    if (deviceId !== device.id) throw forbidden('check-in must come from your own phone');
    const r = await ingestCheckIn(null, sessionKey, rawB64, Date.now(), 'qr', await loadPolicy());
    if (r.ok) await recomputeSession(r.sessionId!);
    return r;
  });

  app.post('/disputes', { preHandler: requireRole('STUDENT') }, async (req) => {
    const { sessionKey, message } = z.object({ sessionKey: z.string(), message: z.string().min(3).max(1000) }).parse(req.body);
    const p = await loadPolicy();
    const s = await prisma.session.findUnique({ where: { key: sessionKey } });
    if (!s || s.state !== 'ENDED') throw bad('you can only dispute a finished class');
    const endedAt = (s.actualEnd ?? s.plannedEnd).getTime();
    if (Date.now() > endedAt + p.disputeWindowHours * 60 * MIN) throw bad(`disputes close ${p.disputeWindowHours}h after class`);
    const enrolled = await prisma.enrollment.count({ where: { studentId: req.user.id, sectionId: { in: s.sectionIds } } });
    if (!enrolled) throw forbidden();
    return prisma.dispute.upsert({
      where: { sessionId_studentId: { sessionId: s.id, studentId: req.user.id } },
      create: { sessionId: s.id, studentId: req.user.id, message },
      update: { message, status: 'PENDING' },
    });
  });
}
