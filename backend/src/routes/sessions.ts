import { randomBytes, randomUUID } from 'node:crypto';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { encodeChallenge, Phase, shortIdForKey, slotAt, tokenFor } from '../crypto/protocol.js';
import { currentPhase } from '../domain/plan.js';
import { MIN } from '../domain/policy.js';
import { startAllowed } from '../domain/schedule.js';
import { requireRole } from '../lib/auth.js';
import { config } from '../lib/config.js';
import { audit } from '../lib/audit.js';
import { prisma } from '../lib/db.js';
import { bad, forbidden, notFound } from '../lib/http.js';
import { notify, studentsOf } from '../lib/notify.js';
import { loadPolicy } from '../lib/policy.js';
import { openSecret, sealSecret } from '../lib/secrets.js';
import { evaluateSession, recomputeSession, setOverride } from '../services/attendance.js';
import { ingestSync, syncSchema } from '../services/ingest.js';
import { findOccurrence, localDate } from '../services/occurrences.js';
import { settingsFor } from '../services/settings.js';
import { taughtSections, teaches } from '../services/teaching.js';

const statusEnum = z.enum(['PRESENT', 'LATE', 'LEFT_EARLY', 'FLAGGED', 'ABSENT', 'EXCUSED', 'MANUAL', 'UNVERIFIED']);
const fmtTime = (ms: number) => new Date(ms).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', timeZone: config.zone });

async function ownedSession(req: FastifyRequest, key: string) {
  const s = await prisma.session.findUnique({ where: { key } });
  if (!s) throw notFound('session not found');
  if (s.teacherId !== req.user.id && !(await teaches(req.user.id, s.sectionIds))) throw forbidden('not your class');
  return s;
}

export async function sessionRoutes(app: FastifyInstance) {
  const teacher = { preHandler: requireRole('TEACHER') };
  const staff = { preHandler: requireRole('TEACHER') };

  /** Main path for the teacher app: upload sessions + check-ins (live or after being offline). */
  app.post('/sessions/sync', teacher, async (req) => ingestSync(req.user.id, syncSchema.parse(req.body)));

  /**
   * Announce an extra class. Students' phones must learn its key in advance so they
   * can wake up for it, so this needs internet; the teacher phone keeps the secret.
   */
  app.post('/sessions/adhoc', teacher, async (req) => {
    const b = z
      .object({ sectionIds: z.array(z.string()).min(1), title: z.string().max(200).optional(), scheduledStart: z.number(), scheduledEnd: z.number() })
      .parse(req.body);
    if (b.scheduledEnd <= b.scheduledStart || b.scheduledEnd - b.scheduledStart > 6 * 60 * MIN) throw bad('bad times');
    if (b.scheduledEnd < Date.now()) throw bad('class is in the past');
    if (!(await teaches(req.user.id, b.sectionIds))) throw forbidden('you do not teach these subjects');
    const key = `adhoc:${randomUUID()}`;
    await prisma.session.create({
      data: {
        key, shortId: shortIdForKey(key) | 0, kind: 'ADHOC', sectionIds: b.sectionIds, teacherId: req.user.id, title: b.title,
        scheduledStart: new Date(b.scheduledStart), scheduledEnd: new Date(b.scheduledEnd), plannedEnd: new Date(b.scheduledEnd), state: 'SCHEDULED',
      },
    });
    await notify(await studentsOf(b.sectionIds), 'class.extra', 'Extra class scheduled', `${b.title ?? 'Extra class'} at ${fmtTime(b.scheduledStart)}`, { sessionKey: key });
    await audit(req.user.id, 'session.adhoc_announced', key);
    return { key, shortId: shortIdForKey(key) };
  });

  /** Cancel a class before it starts (teacher ill, event, …). It won't count against anyone. */
  app.post('/sessions/cancel', staff, async (req) => {
    const { key, reason } = z.object({ key: z.string(), reason: z.string().min(2).max(500) }).parse(req.body);
    const existing = await prisma.session.findUnique({ where: { key } });
    if (existing && existing.state !== 'SCHEDULED') throw bad('class already started; end it instead');
    let sectionIds: string[];
    if (existing) {
      if (!(await teaches(req.user.id, existing.sectionIds))) throw forbidden();
      await prisma.session.update({ where: { id: existing.id }, data: { state: 'CANCELLED', cancelReason: reason } });
      sectionIds = existing.sectionIds;
    } else {
      const occ = await findOccurrence(key);
      if (!occ) throw notFound();
      if (!(await teaches(req.user.id, occ.sectionIds))) throw forbidden();
      await prisma.occurrenceOverride.upsert({
        where: { sessionKey: key },
        create: { sessionKey: key, cancelled: true, reason, createdBy: req.user.id },
        update: { cancelled: true, reason },
      });
      sectionIds = occ.sectionIds;
    }
    await notify(await studentsOf(sectionIds), 'class.cancelled', 'Class cancelled', reason, { sessionKey: key });
    await audit(req.user.id, 'session.cancelled', key, { reason });
    return { ok: true };
  });

  // ---- Backup when the teacher phone is missing: run the session from the web dashboard.
  // The server holds the secret and shows a rotating QR; these check-ins are marked via=qr.
  app.post('/sessions/start-web', teacher, async (req) => {
    const { key } = z.object({ key: z.string() }).parse(req.body);
    const p = await loadPolicy();
    const now = Date.now();
    const existing = await prisma.session.findUnique({ where: { key } });
    if (existing && existing.state !== 'SCHEDULED' && existing.state !== 'TEACHER_NO_SHOW') throw bad('session already started from a phone');
    const occ = key.startsWith('tt:') ? await findOccurrence(key) : null;
    const base = occ ?? existing;
    if (!base) throw notFound();
    if (!(await teaches(req.user.id, base.sectionIds))) throw forbidden('not your class');
    const times = occ
      ? { scheduledStart: occ.scheduledStart, scheduledEnd: occ.scheduledEnd }
      : { scheduledStart: existing!.scheduledStart.getTime(), scheduledEnd: existing!.scheduledEnd.getTime() };
    if (occ?.cancelled) throw bad('class is cancelled');
    const ok = startAllowed(times, now, p);
    if (!ok.ok) throw bad(ok.reason);
    const data = {
      teacherId: req.user.id, state: 'ACTIVE' as const, actualStart: new Date(now), plannedEnd: new Date(times.scheduledEnd),
      activity: [[now, now]], secret: sealSecret(randomBytes(32)),
    };
    if (existing) await prisma.session.update({ where: { id: existing.id }, data });
    else
      await prisma.session.create({
        data: {
          ...data, key, kind: 'TIMETABLE', shortId: shortIdForKey(key) | 0, sectionIds: occ!.sectionIds, roomId: occ!.roomId,
          scheduledStart: new Date(times.scheduledStart), scheduledEnd: new Date(times.scheduledEnd),
        },
      });
    await audit(req.user.id, 'session.started_web', key);
    return { ok: true };
  });

  /** Current QR payload; the dashboard polls this every few seconds (and it doubles as a heartbeat). */
  app.get('/sessions/:key/challenge', teacher, async (req) => {
    const s = await ownedSession(req, (req.params as { key: string }).key);
    if (s.state !== 'ACTIVE' || !s.secret) throw bad('session not active');
    const now = Date.now();
    const act = s.activity as [number, number][];
    const last = act[act.length - 1];
    if (last && now - last[1] < 60_000) last[1] = now;
    else act.push([now, now]);
    await prisma.session.update({ where: { id: s.id }, data: { activity: act } });
    const { windows } = await evaluateSession(s.id);
    const ph = currentPhase(windows, now);
    const slot = slotAt(now);
    const shortId = s.shortId >>> 0;
    const challenge = encodeChallenge({ shortId, slot, token: tokenFor(openSecret(s.secret), shortId, slot), phase: Phase[ph.phase], windowIndex: ph.index });
    return { sessionKey: s.key, challengeB64: challenge.toString('base64'), validForMs: 5_000 - (now % 5_000) };
  });

  app.post('/sessions/:key/end', teacher, async (req) => {
    const s = await ownedSession(req, (req.params as { key: string }).key);
    if (s.state !== 'ACTIVE') throw bad('session not active');
    await prisma.session.update({ where: { id: s.id }, data: { state: 'ENDED', actualEnd: new Date() } });
    await recomputeSession(s.id);
    return { ok: true };
  });

  /** Live roster (during class) or final result, with each student's checks. */
  app.get('/sessions/:key', staff, async (req) => {
    const s = await ownedSession(req, (req.params as { key: string }).key);
    const { windows, rows } = await evaluateSession(s.id);
    const stored = new Map((await prisma.attendance.findMany({ where: { sessionId: s.id } })).map((a) => [a.studentId, a]));
    return {
      session: { ...s, secret: undefined, shortId: s.shortId >>> 0 },
      windows,
      students: rows.map(({ student, evaluation }) => {
        const a = stored.get(student.id);
        return {
          ...student,
          status: a?.override ?? evaluation.status,
          computed: evaluation.status,
          overridden: !!a?.override,
          reasons: evaluation.reasons,
          checks: evaluation.checks.map((c) => ({ kind: c.window.kind, index: c.window.index, ran: c.ran, passed: c.passed })),
        };
      }),
    };
  });

  /** Student came without a working phone; teacher vouches. Limited per term. */
  app.post('/sessions/:key/manual', staff, async (req) => {
    const s = await ownedSession(req, (req.params as { key: string }).key);
    const { studentId, reason } = z.object({ studentId: z.string(), reason: z.string().min(2).max(300) }).parse(req.body);
    const p = await loadPolicy();
    const todayStr = localDate(Date.now());
    const term = await prisma.term.findFirst({ where: { startDate: { lte: todayStr }, endDate: { gte: todayStr } } });
    const since = term ? new Date(`${term.startDate}T00:00:00Z`) : new Date(Date.now() - 180 * 24 * 60 * MIN);
    const used = await prisma.manualMark.count({
      where: { studentId, createdAt: { gte: since }, sessionId: { in: (await prisma.session.findMany({ where: { sectionIds: { hasSome: s.sectionIds } }, select: { id: true } })).map((x) => x.id) } },
    });
    const quota = (await settingsFor(s.sectionIds, p)).manualQuota;
    if (used >= quota) throw forbidden(`manual quota (${quota}) used; ask an admin`);
    await prisma.manualMark.upsert({
      where: { sessionId_studentId: { sessionId: s.id, studentId } },
      create: { sessionId: s.id, studentId, markedBy: req.user.id, reason },
      update: { reason },
    });
    await audit(req.user.id, 'attendance.manual', `${s.key}/${studentId}`, { reason });
    await recomputeSession(s.id);
    return { ok: true, used: used + 1, quota };
  });

  app.post('/sessions/:key/override', staff, async (req) => {
    const s = await ownedSession(req, (req.params as { key: string }).key);
    const b = z.object({ studentId: z.string(), status: statusEnum.nullable(), reason: z.string().min(2).max(300) }).parse(req.body);
    const a = await setOverride(s.id, s.sectionIds, b.studentId, b.status, req.user.id, b.reason);
    await audit(req.user.id, 'attendance.override', `${s.key}/${b.studentId}`, { from: a?.override ?? a?.computed ?? null, to: b.status, reason: b.reason });
    return { ok: true };
  });

  app.get('/disputes', staff, async (req) => {
    const mine = await taughtSections(req.user.id);
    const where = { sessionId: { in: (await prisma.session.findMany({ where: { sectionIds: { hasSome: mine } }, select: { id: true } })).map((s) => s.id) } };
    return prisma.dispute.findMany({ where: { ...where, status: 'PENDING' }, orderBy: { createdAt: 'asc' } });
  });

  app.post('/disputes/:id/resolve', staff, async (req) => {
    const { id } = req.params as { id: string };
    const b = z.object({ accept: z.boolean(), status: statusEnum.default('PRESENT'), resolution: z.string().min(2).max(500) }).parse(req.body);
    const d = await prisma.dispute.findUniqueOrThrow({ where: { id } });
    const s = await prisma.session.findUniqueOrThrow({ where: { id: d.sessionId } });
    if (!(await teaches(req.user.id, s.sectionIds))) throw forbidden();
    await prisma.dispute.update({ where: { id }, data: { status: b.accept ? 'APPROVED' : 'REJECTED', resolvedBy: req.user.id, resolution: b.resolution } });
    if (b.accept)
      await prisma.attendance.update({
        where: { sessionId_studentId: { sessionId: s.id, studentId: d.studentId } },
        data: { override: b.status, overrideBy: req.user.id, overrideReason: `dispute: ${b.resolution}` },
      });
    await notify([d.studentId], 'dispute.resolved', b.accept ? 'Dispute accepted' : 'Dispute rejected', b.resolution, { sessionKey: s.key });
    await audit(req.user.id, 'dispute.resolved', id, b);
    return { ok: true };
  });
}
