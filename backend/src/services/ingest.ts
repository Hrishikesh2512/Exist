// Accepts what a teacher phone collected (sessions it ran + student check-ins),
// online or long after the fact. Everything is re-verified here; the phone is not trusted
// to have checked signatures or tokens.
import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { decodeCheckIn, shortIdForKey, SLOT_MS, tokenFor, verifyCheckInSignature } from '../crypto/protocol.js';
import type { Interval } from '../domain/plan.js';
import { clampPlan, MIN, type Policy } from '../domain/policy.js';
import { startAllowed } from '../domain/schedule.js';
import { audit } from '../lib/audit.js';
import { prisma } from '../lib/db.js';
import { loadPolicy } from '../lib/policy.js';
import { openSecret, sealSecret } from '../lib/secrets.js';
import { recomputeSession, setOverride } from './attendance.js';
import { findOccurrence } from './occurrences.js';
import { teaches } from './teaching.js';

/** Max distance between the slot in a check-in and when the teacher phone received it. */
export const SLOT_TOLERANCE_MS = 3 * SLOT_MS;

const interval = z.tuple([z.number(), z.number()]).refine(([a, b]) => b >= a);

export const syncSchema = z.object({
  sessions: z
    .array(
      z.object({
        key: z.string().min(3).max(300),
        kind: z.enum(['TIMETABLE', 'ADHOC']),
        state: z.enum(['ACTIVE', 'ENDED', 'CANCELLED']),
        secretB64: z.string().length(44),
        sectionIds: z.array(z.string()).min(1).optional(), // ADHOC only
        title: z.string().max(200).optional(),
        scheduledStart: z.number().optional(), // ADHOC only
        scheduledEnd: z.number().optional(), // ADHOC only
        actualStart: z.number().nullable(),
        actualEnd: z.number().nullable(),
        plannedEnd: z.number(),
        activity: z.array(interval).max(2000),
        cancelReason: z.string().max(500).optional(),
        /** Teacher settings the phone used to plan this class (clamped to the allowed limits). */
        plan: z.record(z.string(), z.number()).optional(),
        /** Surprise checks the teacher triggered. */
        extraChecks: z.array(interval).max(3).optional(),
        pauses: z.array(interval).max(50).optional(),
      }),
    )
    .max(50)
    .default([]),
  checkins: z
    .array(z.object({ sessionKey: z.string(), rawB64: z.string().max(400), receivedAt: z.number() }))
    .max(5000)
    .default([]),
  /** Statuses the teacher set by hand on the phone (even offline, during class). */
  marks: z
    .array(
      z.object({
        sessionKey: z.string(),
        studentId: z.string(),
        status: z.enum(['PRESENT', 'LATE', 'LEFT_EARLY', 'FLAGGED', 'ABSENT', 'EXCUSED', 'MANUAL', 'UNVERIFIED']).nullable(),
        reason: z.string().max(300),
      }),
    )
    .max(2000)
    .default([]),
});
export type SyncPayload = z.infer<typeof syncSchema>;

function mergeIntervals(list: Interval[]): Interval[] {
  const out: Interval[] = [];
  for (const [a, b] of [...list].sort((x, y) => x[0] - y[0])) {
    const last = out[out.length - 1];
    if (last && a <= last[1] + 1_000) last[1] = Math.max(last[1], b);
    else out.push([a, b]);
  }
  return out;
}

type SessionIn = SyncPayload['sessions'][number];

async function upsertSession(teacherId: string, s: SessionIn, p: Policy, now: number) {
  let sectionIds: string[];
  let scheduledStart: number;
  let scheduledEnd: number;
  let substitutePending = false;
  let roomId: string | null = null;

  if (s.kind === 'TIMETABLE') {
    const occ = await findOccurrence(s.key);
    if (!occ) throw new Error('unknown timetable session');
    if (occ.cancelled) throw new Error('session was cancelled');
    ({ sectionIds, scheduledStart, scheduledEnd, roomId } = occ);
    if (!(await teaches(teacherId, occ.sectionIds))) throw new Error('not your class');
    if (s.actualStart !== null) {
      const ok = startAllowed(occ, s.actualStart, p);
      if (!ok.ok) throw new Error(`start not allowed: ${ok.reason}`);
    }
  } else {
    if (!s.key.startsWith('adhoc:') || !s.sectionIds || !s.scheduledStart || !s.scheduledEnd) throw new Error('bad adhoc session');
    if (s.scheduledEnd <= s.scheduledStart || s.scheduledEnd - s.scheduledStart > 6 * 60 * MIN) throw new Error('bad adhoc times');
    if (!(await teaches(teacherId, s.sectionIds))) throw new Error('you do not teach these subjects');
    ({ sectionIds, scheduledStart, scheduledEnd } = { sectionIds: s.sectionIds, scheduledStart: s.scheduledStart, scheduledEnd: s.scheduledEnd });
  }
  if (s.actualStart !== null && s.actualStart > now + 2 * MIN) throw new Error('start is in the future');
  if (s.plannedEnd < scheduledEnd || s.plannedEnd > scheduledEnd + 90 * MIN) throw new Error('bad planned end');

  const existing = await prisma.session.findUnique({ where: { key: s.key } });
  if (existing?.secret && !openSecret(existing.secret).equals(Buffer.from(s.secretB64, 'base64')))
    throw new Error('session already registered from another device');
  if (existing && existing.teacherId !== teacherId && existing.state !== 'TEACHER_NO_SHOW') throw new Error('session belongs to another teacher');
  if (existing?.state === 'ENDED' && s.state === 'ACTIVE') return existing; // late duplicate from the phone

  const activity = mergeIntervals([...((existing?.activity as Interval[]) ?? []), ...s.activity]);
  const plan = existing?.secret ? (existing.plan as object) : clampPlan(s.plan); // fixed once the class started
  const extraChecks = s.extraChecks ?? (existing?.extraChecks as Interval[]) ?? [];
  const endBound = (s.actualEnd ?? s.plannedEnd) + p.earlyEndWindowMin * MIN;
  for (const [a, b] of extraChecks) {
    if (s.actualStart === null || a < s.actualStart || b > endBound || Math.abs(b - a - p.midWindowMin * MIN) > 1_000) throw new Error('bad surprise check');
  }
  const data = {
    teacherId,
    sectionIds,
    roomId,
    title: s.title ?? null,
    scheduledStart: new Date(scheduledStart),
    scheduledEnd: new Date(scheduledEnd),
    actualStart: s.actualStart ? new Date(s.actualStart) : null,
    actualEnd: s.actualEnd ? new Date(s.actualEnd) : null,
    plannedEnd: new Date(s.plannedEnd),
    activity,
    plan,
    extraChecks,
    pauses: s.pauses ?? (existing?.pauses as Interval[]) ?? [],
    state: s.state,
    cancelReason: s.cancelReason ?? null,
    substitutePending: existing ? existing.substitutePending || substitutePending : substitutePending,
  };
  const row = existing
    ? await prisma.session.update({
        where: { id: existing.id },
        data: existing.secret ? data : { ...data, secret: sealSecret(Buffer.from(s.secretB64, 'base64')) },
      })
    : await prisma.session.create({
        data: { ...data, key: s.key, kind: s.kind, shortId: shortIdForKey(s.key) | 0, secret: sealSecret(Buffer.from(s.secretB64, 'base64')) },
      });

  if (!existing || existing.state === 'TEACHER_NO_SHOW' || existing.state === 'SCHEDULED') {
    if (existing?.state === 'TEACHER_NO_SHOW') await audit(teacherId, 'session.revived', s.key, { note: 'teacher phone was offline' });
    if (s.kind === 'ADHOC' && !existing) await audit(teacherId, 'session.adhoc', s.key, { sectionIds });
  }
  if (s.state === 'CANCELLED' && existing?.state !== 'CANCELLED') await audit(teacherId, 'session.cancelled', s.key, { reason: s.cancelReason });
  return row;
}

export interface SyncResult {
  sessions: { key: string; ok: boolean; error?: string }[];
  checkins: { index: number; ok: boolean; duplicate?: boolean; error?: string }[];
  marks: { index: number; ok: boolean; error?: string }[];
}

export async function ingestSync(teacherId: string, payload: SyncPayload, now = Date.now()): Promise<SyncResult> {
  const p = await loadPolicy();
  const result: SyncResult = { sessions: [], checkins: [], marks: [] };
  const touched = new Set<string>();

  for (const s of payload.sessions) {
    try {
      const row = await upsertSession(teacherId, s, p, now);
      touched.add(row.id);
      result.sessions.push({ key: s.key, ok: true });
    } catch (e) {
      result.sessions.push({ key: s.key, ok: false, error: (e as Error).message });
    }
  }

  for (const [index, c] of payload.checkins.entries()) {
    const r = await ingestCheckIn(teacherId, c.sessionKey, c.rawB64, c.receivedAt, 'gatt', p);
    if (r.sessionId) touched.add(r.sessionId);
    result.checkins.push({ index, ok: r.ok, duplicate: r.duplicate, error: r.error });
  }

  for (const [index, m] of payload.marks.entries()) {
    try {
      const s = await prisma.session.findUnique({ where: { key: m.sessionKey } });
      if (!s) throw new Error('session not found');
      if (s.teacherId !== teacherId) throw new Error('not your session');
      await setOverride(s.id, s.sectionIds, m.studentId, m.status, teacherId, m.reason);
      await audit(teacherId, 'attendance.override', `${s.key}/${m.studentId}`, { to: m.status, reason: m.reason, offline: true });
      result.marks.push({ index, ok: true });
    } catch (e) {
      result.marks.push({ index, ok: false, error: (e as Error).message });
    }
  }
  for (const id of touched) await recomputeSession(id);
  return result;
}

export async function ingestCheckIn(
  teacherId: string | null,
  sessionKey: string,
  rawB64: string,
  receivedAt: number,
  via: 'gatt' | 'qr',
  p: Policy,
): Promise<{ ok: boolean; duplicate?: boolean; error?: string; sessionId?: string }> {
  const session = await prisma.session.findUnique({ where: { key: sessionKey } });
  if (!session || !session.secret) return { ok: false, error: 'unknown session' };
  if (teacherId && session.teacherId !== teacherId) return { ok: false, error: 'not your session' };

  let c;
  try {
    c = decodeCheckIn(Buffer.from(rawB64, 'base64'));
  } catch {
    return { ok: false, error: 'malformed' };
  }

  const device = await prisma.device.findUnique({ where: { id: c.deviceId } });
  const reject = async (reason: string) => {
    await prisma.checkIn
      .create({
        data: {
          sessionId: session.id, studentId: device?.userId ?? null, deviceId: c.deviceId, nonce: c.nonce.toString('hex'),
          slot: BigInt(c.slot), receivedAt: new Date(receivedAt), raw: rawB64, via, valid: false, rejectReason: reason,
        },
      })
      .catch(() => undefined); // duplicate nonce of a rejected record
    return { ok: false, error: reason, sessionId: session.id };
  };

  const dup = await prisma.checkIn.findUnique({ where: { deviceId_nonce: { deviceId: c.deviceId, nonce: c.nonce.toString('hex') } } });
  if (dup) return dup.raw === rawB64 && dup.sessionId === session.id ? { ok: dup.valid, duplicate: true, sessionId: session.id } : { ok: false, error: 'nonce reused' };

  if (!device) return reject('unknown device');
  if (device.revokedAt && device.revokedAt.getTime() <= receivedAt) return reject('device revoked');
  if ((c.shortId | 0) !== session.shortId) return reject('wrong session');
  if (!verifyCheckInSignature(c, device.publicKeySpki)) return reject('bad signature');
  if (tokenFor(openSecret(session.secret), c.shortId, c.slot) !== c.token) return reject('bad token');
  if (Math.abs(c.slot * SLOT_MS - receivedAt) > SLOT_TOLERANCE_MS) return reject('stale token');
  const start = session.actualStart?.getTime() ?? Infinity;
  const end = (session.actualEnd?.getTime() ?? session.plannedEnd.getTime()) + p.earlyEndWindowMin * MIN;
  if (receivedAt < start || receivedAt > end) return reject('outside session');
  const enrolled = await prisma.enrollment.count({ where: { studentId: device.userId, sectionId: { in: session.sectionIds } } });
  if (!enrolled) return reject('not enrolled');

  await prisma.checkIn.create({
    data: {
      id: randomUUID(), sessionId: session.id, studentId: device.userId, deviceId: device.id, nonce: c.nonce.toString('hex'),
      slot: BigInt(c.slot), receivedAt: new Date(receivedAt), raw: rawB64, via, valid: true,
    },
  });
  return { ok: true, sessionId: session.id };
}
