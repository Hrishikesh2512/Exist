// End-to-end against a real Postgres (run via scripts/test-integration.sh).
// Only teachers and students: no administrator anywhere.
import { generateKeyPairSync, randomBytes, sign, type KeyObject } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { DateTime } from 'luxon';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { decodeChallenge, encodeCheckIn, encodeCheckInBody, sectionShortId, shortIdForKey, signedMessage, slotAt, tokenFor } from '../src/crypto/protocol.js';
import { planChecks } from '../src/domain/plan.js';
import { DEFAULT_POLICY, MIN } from '../src/domain/policy.js';
import { tick } from '../src/jobs/tick.js';
import { prisma } from '../src/lib/db.js';
import { sentMail } from '../src/lib/mail.js';

const RUN = !!process.env.DATABASE_URL?.includes('exist_test');
const d = RUN ? describe : describe.skip;

// Monday 2026-09-21, IST. Rao: Data Structures for CSE-A and CSE-B together 09:30–10:30.
// Sen: Discrete Maths for CSE-A 10:30–11:30.
const T0 = Date.UTC(2026, 8, 21, 4, 0);
const A = 'CS301-CSE-A', B = 'CS301-CSE-B', M = 'MA201-CSE-A';
const K1 = `tt:2026-09-21:570:${A}+${B}`;
const K2 = `tt:2026-09-21:630:${M}`;

let app: FastifyInstance;
const tokens: Record<string, string> = {};
const ids: Record<string, string> = {};
const keys: Record<string, { priv: KeyObject; spki: string; deviceId?: string }> = {};
const codes: Record<string, string> = {};

async function api(who: string, method: string, url: string, body?: unknown) {
  const r = await app.inject({ method: method as 'GET', url, payload: body as object, headers: tokens[who] ? { authorization: `Bearer ${tokens[who]}` } : {} });
  return { status: r.statusCode, body: r.headers['content-type']?.includes('json') ? r.json() : r.body };
}

async function signup(who: string, role: 'TEACHER' | 'STUDENT', name: string, extra: Record<string, string> = {}) {
  const r = await api('', 'POST', '/auth/register', { role, name, email: `${who}@x.edu`, password: `${who}-password`, ...extra });
  expect(r.status).toBe(200);
  tokens[who] = r.body.token;
  ids[who] = r.body.user.id;
  await api(who, 'POST', '/me/consent', { version: 1 });
  return r.body;
}

function checkIn(student: string, sessionKey: string, secret: Buffer, at: number) {
  const k = keys[student];
  const shortId = shortIdForKey(sessionKey);
  const slot = slotAt(at);
  const body = encodeCheckInBody({ shortId, slot, token: tokenFor(secret, shortId, slot), deviceId: k.deviceId!, nonce: randomBytes(8), clientTs: at });
  return { sessionKey, rawB64: encodeCheckIn(body, sign('sha256', signedMessage(body), { key: k.priv, dsaEncoding: 'der' })).toString('base64'), receivedAt: at + 400 };
}

async function bindPhone(who: string, extra: Record<string, string> = {}) {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
  const prev = keys[who];
  keys[who] = { priv: privateKey, spki: publicKey.export({ format: 'der', type: 'spki' }).toString('base64') };
  const r = await api(who, 'POST', '/devices/bind', { platform: 'android', publicKeySpki: keys[who].spki, ...extra });
  keys[who].deviceId = r.body.deviceId ?? prev?.deviceId;
  return r;
}

d('Exist end to end (teachers and students only)', () => {
  const secret = randomBytes(32);

  beforeAll(async () => {
    for (const t of ['auditLog', 'notification', 'dispute', 'excuse', 'manualMark', 'attendance', 'checkIn', 'session', 'occurrenceOverride', 'calendarEvent', 'personalEvent',
      'sectionSettings', 'timetableSlot', 'room', 'enrollment', 'sectionTeacher', 'classMember', 'joinCode', 'section', 'classGroup', 'term', 'course',
      'deviceChangeRequest', 'device', 'setting', 'user'] as const)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      await (prisma[t] as any).deleteMany();
    // Rules are server settings now (no admin): allow disputes on last week's test classes.
    await prisma.setting.create({ data: { key: 'policy', value: { disputeWindowHours: 100_000 } } });
    app = await buildApp();
  });
  afterAll(async () => {
    await app?.close();
    await prisma.$disconnect();
  });

  // ------------------------------------------------------------------ accounts and classes
  it('teachers and students sign up themselves; an optional teacher code guards teacher sign-up', async () => {
    process.env.TEACHER_SIGNUP_CODE = 'STAFF2026';
    expect((await api('', 'GET', '/setup/status')).body.teacherCodeRequired).toBe(true);
    expect((await api('', 'POST', '/auth/register', { role: 'TEACHER', name: 'Fake', email: 'fake@x.edu', password: 'fake-password' })).status).toBe(403);
    await signup('rao', 'TEACHER', 'Dr Rao', { teacherCode: 'staff2026' });
    delete process.env.TEACHER_SIGNUP_CODE;
    await signup('sen', 'TEACHER', 'Dr Sen');
    expect((await api('', 'POST', '/auth/register', { role: 'STUDENT', name: 'No Roll', email: 'nr@x.edu', password: 'no-roll-pass' })).status).toBe(400);
  });

  it('a teacher creates classes; each gets a class code and a co-teacher code', async () => {
    const a = await api('rao', 'POST', '/classes', { subjectName: 'Data Structures', subjectCode: 'CS301', groupName: 'CSE-A' });
    const b = await api('rao', 'POST', '/classes', { subjectName: 'Data Structures', subjectCode: 'CS301', groupName: 'CSE-B' });
    const m = await api('sen', 'POST', '/classes', { subjectName: 'Discrete Maths', subjectCode: 'MA201', groupName: 'CSE-A' });
    expect([a.body.id, b.body.id, m.body.id]).toEqual([A, B, M]);
    expect(a.body.label).toBe('Data Structures · CSE-A');
    expect(a.body.codes.student).toMatch(/^[A-HJ-NP-Z2-9]{8}$/);
    codes.A = a.body.codes.student; codes.B = b.body.codes.student; codes.M = m.body.codes.student;
    expect((await api('sen', 'PATCH', `/classes/${A}`, { groupName: 'X' })).status).toBe(403);
  });

  it('students join with the class code (at sign-up or later) and see only their classes', async () => {
    await signup('s1', 'STUDENT', 'Asha', { rollNo: 'R1', classCode: codes.A });
    await signup('s2', 'STUDENT', 'Bilal', { rollNo: 'R2' });
    await signup('s3', 'STUDENT', 'Chen', { rollNo: 'R3', classCode: codes.B });
    await signup('s4', 'STUDENT', 'Dev, Jr', { rollNo: 'R4', classCode: codes.A });
    expect((await api('s2', 'POST', '/classes/join', { code: codes.A.toLowerCase() })).body.label).toBe('Data Structures · CSE-A');
    for (const s of ['s1', 's2', 's4']) await api(s, 'POST', '/classes/join', { code: codes.M });
    const mine = await api('s1', 'GET', '/classes');
    expect(mine.body.map((c: { label: string }) => c.label)).toEqual(['Data Structures · CSE-A', 'Discrete Maths · CSE-A']);
    expect(mine.body[0].codes).toBeUndefined();
    expect((await api('s1', 'GET', `/classes/${B}`)).status).toBe(403);
    expect((await api('sen', 'POST', '/classes/join', { code: codes.A })).status).toBe(400);
  });

  it('co-teaching with the co-teacher code', async () => {
    const t = (await api('rao', 'GET', `/classes/${B}`)).body.codes.teacher;
    await api('sen', 'POST', '/classes/join', { code: t });
    expect((await api('sen', 'GET', `/classes/${B}`)).body.teachers.map((x: { name: string }) => x.name).sort()).toEqual(['Dr Rao', 'Dr Sen']);
    await api('sen', 'POST', `/classes/${B}/leave`);
    expect((await api('sen', 'GET', `/classes/${B}`)).status).toBe(403);
    expect((await api('rao', 'POST', `/classes/${B}/leave`)).status).toBe(400);
  });

  it('teachers make the weekly timetable (no double-booking)', async () => {
    for (const id of [A, B]) expect((await api('rao', 'POST', `/classes/${id}/timetable`, { day: 'Mon', start: '09:30', end: '10:30', room: 'R101' })).status).toBe(200);
    expect((await api('sen', 'POST', `/classes/${M}/timetable`, { day: 'Mon', start: '10:30', end: '11:30' })).status).toBe(200);
    const extra = await api('rao', 'POST', '/classes', { subjectName: 'Lab', subjectCode: 'CS391', groupName: 'CSE-A' });
    expect((await api('rao', 'POST', `/classes/${extra.body.id}/timetable`, { day: 'Mon', start: '10:00', end: '11:00' })).status).toBe(400);
    expect((await api('rao', 'DELETE', `/classes/${extra.body.id}`)).body).toEqual({ deleted: true });
  });

  it('students register their phone after consent', async () => {
    for (const s of ['s1', 's2', 's3', 's4']) expect((await bindPhone(s)).body.status).toBe('BOUND');
  });

  // ------------------------------------------------------------------ a class day
  it('teacher late → students told at +10, the teacher reminded at +20, no-show later', async () => {
    await tick(T0 + 60 * MIN + 11 * MIN);
    await tick(T0 + 60 * MIN + 12 * MIN);
    expect(await prisma.notification.count({ where: { kind: 'teacher.late' } })).toBe(3);
    await tick(T0 + 60 * MIN + 21 * MIN);
    expect(await prisma.notification.count({ where: { kind: 'teacher.reminder', userId: ids.sen } })).toBe(1);
    await tick(T0 + 60 * MIN + 41 * MIN);
    expect((await prisma.session.findUniqueOrThrow({ where: { key: K2 } })).state).toBe('TEACHER_NO_SHOW');
    expect((await prisma.session.findUniqueOrThrow({ where: { key: K1 } })).state).toBe('TEACHER_NO_SHOW');
  });

  it('offline teacher phone syncs later: forged, relayed and replayed check-ins rejected', async () => {
    const times = { scheduledStart: T0, scheduledEnd: T0 + 60 * MIN, actualStart: T0 + 2 * MIN, actualEnd: T0 + 60 * MIN, plannedEnd: T0 + 60 * MIN };
    const [S, Mw, E] = planChecks(secret, times, DEFAULT_POLICY);
    const good = [
      checkIn('s1', K1, secret, S.from + 30_000), checkIn('s1', K1, secret, Mw.from + 10_000), checkIn('s1', K1, secret, E.from + 60_000),
      checkIn('s2', K1, secret, S.from + 60_000), checkIn('s2', K1, secret, E.from + 60_000),
      checkIn('s3', K1, secret, Mw.from + 5_000), checkIn('s3', K1, secret, E.from + 5_000),
    ];
    const forged = checkIn('s4', K1, randomBytes(32), S.from + 1000);
    const stale = { ...checkIn('s4', K1, secret, S.from + 1000), receivedAt: S.from + 60_000 };
    const r = await api('rao', 'POST', '/sessions/sync', {
      sessions: [{ key: K1, kind: 'TIMETABLE', state: 'ENDED', secretB64: secret.toString('base64'), ...times, activity: [[times.actualStart, times.actualEnd]] }],
      checkins: [...good, forged, stale, good[0]],
    });
    expect(r.body.sessions[0]).toEqual({ key: K1, ok: true });
    expect(r.body.checkins.map((c: { ok: boolean; error?: string }) => c.error ?? 'ok')).toEqual(['ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'ok', 'bad token', 'stale token', 'ok']);
    const live = await api('rao', 'GET', `/sessions/${encodeURIComponent(K1)}`);
    const st = Object.fromEntries(live.body.students.map((s: { rollNo: string; status: string }) => [s.rollNo, s.status]));
    expect(st).toEqual({ R1: 'PRESENT', R2: 'FLAGGED', R3: 'LATE', R4: 'ABSENT' });
  });

  it('only the class teacher can run or view its classes', async () => {
    expect((await api('sen', 'GET', `/sessions/${encodeURIComponent(K1)}`)).status).toBe(403);
    const r = await api('sen', 'POST', '/sessions/sync', {
      sessions: [{ key: K1, kind: 'TIMETABLE', state: 'ACTIVE', secretB64: randomBytes(32).toString('base64'), actualStart: T0, actualEnd: null, plannedEnd: T0 + 60 * MIN, activity: [] }],
    });
    expect(r.body.sessions[0].ok).toBe(false);
  });

  // ------------------------------------------------------------------ attendance sheets
  it('teacher sees the whole register (and CSV); student sees their own sheet', async () => {
    const reg = await api('rao', 'GET', `/classes/${A}/register`);
    expect(reg.body.students.map((s: { name: string; statuses: string[] }) => [s.name, s.statuses])).toEqual([
      ['Asha', ['PRESENT']], ['Bilal', ['FLAGGED']], ['Dev, Jr', ['ABSENT']],
    ]);
    const csv = await api('rao', 'GET', `/classes/${A}/register?format=csv`);
    expect(String(csv.body)).toContain('"Dev, Jr"');
    expect((await api('sen', 'GET', `/classes/${A}/register`)).status).toBe(403);
    const sheet = await api('s2', 'GET', `/me/classes/${A}/sheet`);
    expect(sheet.body.records.map((r: { status: string }) => r.status)).toEqual(['FLAGGED']);
    expect((await api('s3', 'GET', `/me/classes/${A}/sheet`)).status).toBe(403);
  });

  it('student dispute → teacher accepts → sheet updated', async () => {
    await api('s2', 'POST', '/disputes', { sessionKey: K1, message: 'I was there, phone lagged' });
    const list = await api('rao', 'GET', '/disputes');
    expect(list.body).toHaveLength(1);
    await api('rao', 'POST', `/disputes/${list.body[0].id}/resolve`, { accept: true, resolution: 'Seen in class' });
    expect((await api('s2', 'GET', `/me/classes/${A}/sheet`)).body.records[0]).toMatchObject({ status: 'PRESENT', overridden: true });
  });

  it('teacher edits any record, and excuses leave for their class only', async () => {
    await api('rao', 'POST', `/sessions/${encodeURIComponent(K1)}/override`, { studentId: ids.s4, status: 'LATE', reason: 'came late, phone off' });
    expect((await api('rao', 'GET', `/classes/${A}/register`)).body.students[2].statuses).toEqual(['LATE']);
    await api('rao', 'POST', `/sessions/${encodeURIComponent(K1)}/override`, { studentId: ids.s4, status: null, reason: 'undo' });
    await api('rao', 'POST', `/classes/${A}/excuse`, { studentId: ids.s4, fromDate: '2026-09-20', toDate: '2026-09-22', reason: 'medical' });
    expect((await prisma.attendance.findFirstOrThrow({ where: { studentId: ids.s4 } })).computed).toBe('EXCUSED');
    expect((await api('sen', 'POST', `/classes/${A}/excuse`, { studentId: ids.s4, fromDate: '2026-09-20', toDate: '2026-09-22', reason: 'nope' })).status).toBe(403);
  });

  it('student totals: overall and per class', async () => {
    const me = await api('s1', 'GET', '/me/attendance');
    expect(me.body.overall).toMatchObject({ total: 1, percent: 100 });
    expect(me.body.sections.find((x: { sectionId: string }) => x.sectionId === A)).toMatchObject({ label: 'Data Structures · CSE-A', percent: 100 });
  });

  it('manual "present without phone" with the per-class allowance', async () => {
    await api('rao', 'PUT', `/sections/${A}/settings`, { manualQuota: 1 });
    expect((await api('rao', 'POST', `/sessions/${encodeURIComponent(K1)}/manual`, { studentId: ids.s2, reason: 'phone dead' })).body.used).toBe(1);
    expect((await api('rao', 'POST', `/sessions/${encodeURIComponent(K1)}/manual`, { studentId: ids.s2, reason: 'again' })).status).toBe(403);
  });

  // ------------------------------------------------------------------ phones
  it("new phone: the student's teacher can approve it early", async () => {
    const r = await bindPhone('s1', { model: 'Pixel 8' });
    expect(r.body.status).toBe('PENDING');
    expect(await prisma.notification.count({ where: { kind: 'device.change', userId: ids.rao } })).toBe(1);
    expect((await api('sen', 'GET', '/teacher/device-requests')).body).toHaveLength(1); // Sen teaches s1 too
    const reqs = await api('rao', 'GET', '/teacher/device-requests');
    await api('rao', 'POST', `/teacher/device-requests/${reqs.body[0].id}`, { approve: true });
    const dev = await prisma.device.findFirstOrThrow({ where: { userId: ids.s1, revokedAt: null } });
    expect(dev.model).toBe('Pixel 8');
    keys.s1.deviceId = dev.id;
  });

  // ------------------------------------------------------------------ schedules and calendar
  it('teacher marks a "no class" day for their class; students\' calendars follow', async () => {
    const MON = '2026-10-05';
    const before = await api('s1', 'GET', `/me/calendar?from=${MON}&to=${MON}`);
    expect(before.body.sessions.map((s: { label: string }) => s.label).sort()).toEqual(['Data Structures · CSE-A + CSE-B', 'Discrete Maths · CSE-A']);
    await api('sen', 'POST', '/calendar/section-event', { kind: 'HOLIDAY', title: 'Seminar day', fromDate: MON, toDate: MON, sectionIds: [M] });
    const after = await api('s1', 'GET', `/me/calendar?from=${MON}&to=${MON}`);
    expect(after.body.sessions.map((s: { label: string }) => s.label)).toEqual(['Data Structures · CSE-A + CSE-B']);
    expect(after.body.events.map((e: { title: string }) => e.title)).toEqual(['Seminar day']);
    expect((await api('sen', 'POST', '/calendar/section-event', { kind: 'HOLIDAY', title: 'Nope', fromDate: MON, toDate: MON, sectionIds: [A] })).status).toBe(403);
    await api('rao', 'POST', '/calendar/section-event', { kind: 'EXAM', title: 'Unit test 1', fromDate: MON, toDate: MON, sectionIds: [A], noClasses: false });
    expect((await api('s1', 'GET', `/me/calendar?from=${MON}&to=${MON}`)).body.events.map((e: { title: string }) => e.title).sort()).toEqual(['Seminar day', 'Unit test 1']);
  });

  it('everyone keeps their own calendar entries; only they see them; they appear in the .ics feed', async () => {
    const e = await api('s1', 'POST', '/me/events', { title: 'Revise trees', date: '2026-10-06', start: '18:00', end: '19:00' });
    await api('s1', 'POST', '/me/events', { title: 'Library', date: '2026-10-07' });
    await api('rao', 'POST', '/me/events', { title: 'Prepare slides', date: '2026-10-06' });
    const s1 = await api('s1', 'GET', '/me/calendar?from=2026-10-01&to=2026-10-31');
    expect(s1.body.personal.map((p: { title: string }) => p.title)).toEqual(['Revise trees', 'Library']);
    expect((await api('s2', 'GET', '/me/calendar?from=2026-10-01&to=2026-10-31')).body.personal).toEqual([]);
    await api('s2', 'DELETE', `/me/events/${e.body.id}`);
    expect(await prisma.personalEvent.count({ where: { id: e.body.id } })).toBe(1); // not s2's to delete
    const link = await api('s1', 'GET', '/me/calendar-link');
    const ics = await app.inject({ method: 'GET', url: link.body.path });
    expect(ics.body).toContain('SUMMARY:Seminar day');
    expect(ics.body).toContain('SUMMARY:Revise trees');
  });

  it('class dates: no classes before start / after end; archiving keeps records', async () => {
    await api('rao', 'PATCH', `/classes/${B}`, { startDate: '2026-10-01', endDate: '2026-10-31' });
    const cal = await api('s3', 'GET', '/me/calendar?from=2026-09-28&to=2026-11-02');
    expect(cal.body.sessions.map((s: { key: string }) => s.key.slice(3, 13))).toEqual(['2026-10-05', '2026-10-12', '2026-10-19', '2026-10-26']);
    expect((await api('rao', 'DELETE', `/classes/${B}`)).body).toEqual({ archived: true });
    expect((await api('s3', 'GET', '/me/calendar?from=2026-10-01&to=2026-10-31')).body.sessions).toEqual([]);
    expect((await api('rao', 'GET', `/classes/${B}/register`)).body.students).toHaveLength(1);
  });

  // ------------------------------------------------------------------ anytime classes and controls
  it('teacher starts a class right now; only its students can check in; offline marks', async () => {
    const key = `adhoc:${randomBytes(8).toString('hex')}`;
    const now = Date.now();
    const sec = randomBytes(32);
    const r = await api('sen', 'POST', '/sessions/sync', {
      sessions: [{ key, kind: 'ADHOC', state: 'ENDED', secretB64: sec.toString('base64'), sectionIds: [M], title: 'Doubt clearing',
        scheduledStart: now - 60_000, scheduledEnd: now + 45 * MIN, actualStart: now - 60_000, actualEnd: now, plannedEnd: now + 45 * MIN, activity: [[now - 60_000, now + 3 * MIN]] }],
      checkins: [checkIn('s1', key, sec, now - 30_000), checkIn('s3', key, sec, now - 20_000)],
      marks: [{ sessionKey: key, studentId: ids.s2, status: 'PRESENT', reason: 'battery dead' }],
    });
    expect(r.body.sessions[0].ok).toBe(true);
    expect(r.body.checkins.map((c: { ok: boolean; error?: string }) => c.error ?? 'ok')).toEqual(['ok', 'not enrolled']);
    const byName = Object.fromEntries((await api('sen', 'GET', `/sessions/${encodeURIComponent(key)}`)).body.students.map((s: { name: string; status: string }) => [s.name, s.status]));
    expect(byName).toMatchObject({ Asha: 'PRESENT', Bilal: 'PRESENT', 'Dev, Jr': 'ABSENT' });
    const bad = await api('rao', 'POST', '/sessions/sync', {
      sessions: [{ key: `adhoc:${randomBytes(8).toString('hex')}`, kind: 'ADHOC', state: 'ACTIVE', secretB64: sec.toString('base64'), sectionIds: [M],
        scheduledStart: now, scheduledEnd: now + 30 * MIN, actualStart: now, actualEnd: null, plannedEnd: now + 30 * MIN, activity: [] }],
    });
    expect(bad.body.sessions[0]).toMatchObject({ ok: false, error: 'you do not teach these subjects' });
  });

  it('schedule gives each phone its classes and the Bluetooth identity of each', async () => {
    const r = await api('s1', 'GET', '/me/schedule?days=2');
    expect(r.body.subjects.map((x: { id: string }) => x.id).sort()).toEqual([A, M]);
    expect(r.body.subjects.find((x: { id: string }) => x.id === A).sectionShortId).toBe(sectionShortId(A));
    const t = await api('rao', 'GET', '/me/schedule?days=2');
    expect(t.body.subjects.map((x: { id: string }) => x.id)).toEqual([A]); // archived B is not current
    expect(Object.keys(t.body.roster)).toContain(A);
  });

  it('teacher moves and cancels classes; students are told', async () => {
    const sched = await api('sen', 'GET', '/me/schedule?days=14');
    const up = sched.body.sessions.filter((s: { state: string }) => s.state === 'UPCOMING');
    const start = up[0].scheduledStart + 2 * 60 * MIN;
    const moved = await api('sen', 'POST', '/sessions/reschedule', { key: up[0].key, scheduledStart: start, scheduledEnd: start + 60 * MIN, reason: 'Clash' });
    expect(moved.body.key).toMatch(/^adhoc:/);
    expect(await prisma.notification.count({ where: { kind: 'class.moved' } })).toBe(3);
    let s1 = await api('s1', 'GET', '/me/schedule?days=14');
    expect(s1.body.sessions.find((s: { key: string }) => s.key === up[0].key).state).toBe('CANCELLED');
    expect(s1.body.sessions.find((s: { key: string }) => s.key === moved.body.key).state).toBe('SCHEDULED');
    expect((await api('rao', 'POST', '/sessions/cancel', { key: moved.body.key, reason: 'not mine' })).status).toBe(403);
    expect((await api('sen', 'POST', '/sessions/cancel', { key: moved.body.key, reason: 'Unwell' })).body.ok).toBe(true);
    s1 = await api('s1', 'GET', '/me/schedule?days=14');
    expect(s1.body.sessions.find((s: { key: string }) => s.key === moved.body.key).state).toBe('CANCELLED');
  });

  it('after class: summaries to the teacher', async () => {
    await tick(Date.now() + 5 * MIN); // once the teacher's phone has stopped uploading
    expect(await prisma.notification.count({ where: { kind: 'class.summary', userId: ids.sen } })).toBeGreaterThanOrEqual(1);
  });

  // ------------------------------------------------------------------ backup without a teacher phone
  it("QR backup from the website: signed check-in from the student's own phone", async () => {
    const now = DateTime.now().setZone('Asia/Kolkata');
    if (now.hour >= 23) return;
    const startMin = Math.max(0, now.hour * 60 + now.minute - 5);
    await prisma.timetableSlot.create({ data: { sectionId: A, teacherId: ids.rao, weekday: now.weekday, startMin, endMin: Math.min(startMin + 60, 1439), validFrom: '2026-01-01', validTo: '2030-12-31' } });
    const key = `tt:${now.toISODate()}:${startMin}:${A}`;
    expect((await api('rao', 'POST', '/sessions/start-web', { key })).status).toBe(200);
    const c = decodeChallenge(Buffer.from((await api('rao', 'GET', `/sessions/${encodeURIComponent(key)}/challenge`)).body.challengeB64, 'base64'));
    const body = encodeCheckInBody({ shortId: c.shortId, slot: c.slot, token: c.token, deviceId: keys.s2.deviceId!, nonce: randomBytes(8), clientTs: Date.now() });
    const raw = encodeCheckIn(body, sign('sha256', signedMessage(body), { key: keys.s2.priv, dsaEncoding: 'der' })).toString('base64');
    expect((await api('s4', 'POST', '/checkins/qr', { sessionKey: key, rawB64: raw })).status).toBe(403);
    expect((await api('s2', 'POST', '/checkins/qr', { sessionKey: key, rawB64: raw })).body).toMatchObject({ ok: true });
  });

  // ------------------------------------------------------------------ passwords and privacy
  it('teacher resets a forgotten password for their own students only', async () => {
    expect((await api('sen', 'POST', `/users/${ids.s3}/reset-password`)).status).toBe(403);
    const r = await api('rao', 'POST', `/users/${ids.s3}/reset-password`);
    const login = await api('', 'POST', '/auth/login', { email: 's3@x.edu', password: r.body.temporaryPassword });
    expect(login.body.user.mustChangePassword).toBe(true);
  });

  it('forgot password by email code; old sign-ins end', async () => {
    await api('', 'POST', '/auth/forgot', { email: 's4@x.edu' });
    const code = /(\d{6})/.exec(sentMail.at(-1)!.text)![1];
    expect((await api('', 'POST', '/auth/reset', { email: 's4@x.edu', code, password: 'brand-new-pass' })).body.ok).toBe(true);
    expect((await api('s4', 'GET', '/me')).status).toBe(401);
    expect((await api('', 'POST', '/auth/login', { email: 's4@x.edu', password: 'brand-new-pass' })).status).toBe(200);
  });

  it('too many wrong passwords locks the account for a while', async () => {
    for (let i = 0; i < 8; i++) await api('', 'POST', '/auth/login', { email: 's2@x.edu', password: 'nope' });
    expect((await api('', 'POST', '/auth/login', { email: 's2@x.edu', password: 's2-password' })).status).toBe(429);
  });

  it('anyone can delete their own account; records stay anonymised', async () => {
    expect((await api('s1', 'POST', '/me/delete', { password: 'wrong' })).status).toBe(400);
    expect((await api('s1', 'POST', '/me/delete', { password: 's1-password' })).body.ok).toBe(true);
    expect((await api('', 'POST', '/auth/login', { email: 's1@x.edu', password: 's1-password' })).status).toBe(401);
    const u = await prisma.user.findUniqueOrThrow({ where: { id: ids.s1 } });
    expect([u.name, u.rollNo]).toEqual(['Deleted account', null]);
    expect(await prisma.attendance.count({ where: { studentId: ids.s1 } })).toBeGreaterThan(0);
  });

  it('a phone can only be registered after accepting the privacy notice', async () => {
    const r = await api('', 'POST', '/auth/register', { role: 'STUDENT', name: 'Esha', email: 'e5@x.edu', password: 'e5-password', rollNo: 'R5', classCode: codes.A });
    tokens.s5 = r.body.token; ids.s5 = r.body.user.id;
    expect((await api('s5', 'GET', '/me')).body.consentRequired).toBe(true);
    expect((await bindPhone('s5')).status).toBe(403);
    await api('s5', 'POST', '/me/consent', { version: 1 });
    expect((await bindPhone('s5')).body.status).toBe('BOUND');
  });

  it('whole-class decision after a field trip, and per-class settings with surprise checks', async () => {
    const r = await api('rao', 'POST', `/sessions/${encodeURIComponent(K1)}/bulk`, { status: 'PRESENT', reason: 'Field trip' });
    expect(r.body.updated).toBeGreaterThanOrEqual(1);
    expect((await api('rao', 'GET', `/classes/${A}/register`)).body.students.every((x: { statuses: string[] }) => x.statuses.every((st) => st === null || ['PRESENT', 'EXCUSED', 'MANUAL'].includes(st)))).toBe(true);
    await api('rao', 'PUT', `/sections/${A}/settings`, { midChecks: 0, autoStart: false });
    const sched = await api('rao', 'GET', '/me/schedule?days=8');
    expect(sched.body.subjects.find((x: { id: string }) => x.id === A)).toMatchObject({ plan: { midChecks: 0 }, autoStart: false });
    expect((await api('sen', 'PUT', `/sections/${A}/settings`, { midChecks: 1 })).status).toBe(403);
  });

  it('three absences in a row alert the student and the teacher', async () => {
    const T = Date.UTC(2026, 10, 2, 4, 0);
    for (let i = 0; i < 3; i++) {
      const s = await prisma.session.create({
        data: { key: `adhoc:streak-${i}`, shortId: i, kind: 'ADHOC', sectionIds: [M], teacherId: ids.sen, scheduledStart: new Date(T + i * 3600e3),
          scheduledEnd: new Date(T + i * 3600e3 + 3000e3), plannedEnd: new Date(T + i * 3600e3 + 3000e3), state: 'ENDED' },
      });
      await prisma.attendance.create({ data: { sessionId: s.id, studentId: ids.s4, computed: 'ABSENT', reasons: [] } });
    }
    await prisma.setting.deleteMany({ where: { key: { startsWith: 'daily:' } } });
    await tick(Date.now());
    expect(await prisma.notification.count({ where: { kind: 'attendance.streak', userId: ids.s4 } })).toBe(1);
    expect(await prisma.notification.count({ where: { kind: 'attendance.streak', userId: ids.sen } })).toBe(1);
  });

  it('withdrawing consent deletes the account', async () => {
    await api('s5', 'POST', '/me/consent/withdraw');
    expect((await api('s5', 'GET', '/me')).status).toBe(401);
    expect((await prisma.user.findUniqueOrThrow({ where: { id: ids.s5 } })).name).toBe('Deleted account');
  });

  it('there is no administrator API anymore', async () => {
    for (const url of ['/admin/users', '/admin/classes', '/admin/policy', '/setup']) expect((await api('rao', 'GET', url)).status).toBe(404);
  });

  it('serves the website', async () => {
    expect((await app.inject({ method: 'GET', url: '/' })).statusCode).toBe(200);
  });
});
