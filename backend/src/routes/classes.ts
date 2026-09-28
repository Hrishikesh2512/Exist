// Classes are created and run by teachers (like Google Classroom): a class is one subject for one
// group of students. Students join with the class code; other teachers co-teach with the co-teacher code.
import { randomInt } from 'node:crypto';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { requireRole, type Role } from '../lib/auth.js';
import { audit } from '../lib/audit.js';
import { prisma } from '../lib/db.js';
import { bad, forbidden, notFound } from '../lib/http.js';
import { notify } from '../lib/notify.js';
import { recomputeSession } from '../services/attendance.js';
import { approveDeviceChange } from '../services/devices.js';
import { sectionReport, toCsv } from '../services/reports.js';
import { sectionInfo, teaches } from '../services/teaching.js';

// No 0/O/1/I so codes are easy to read out in class.
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const randomCode = () => Array.from({ length: 8 }, () => ALPHABET[randomInt(ALPHABET.length)]).join('');
const date = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);
const WEEKDAYS: Record<string, number> = { mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6, sun: 7 };
const hhmm = (s: string) => {
  const m = /^(\d{1,2}):(\d{2})$/.exec(s);
  if (!m) throw bad(`bad time ${s}`);
  return Number(m[1]) * 60 + Number(m[2]);
};

async function newCode(kind: 'STUDENT' | 'TEACHER', sectionId: string, by: string) {
  await prisma.joinCode.updateMany({ where: { kind, sectionId, active: true }, data: { active: false } });
  let code = randomCode();
  while (await prisma.joinCode.findUnique({ where: { code } })) code = randomCode();
  return prisma.joinCode.create({ data: { code, kind, sectionId, createdBy: by } });
}

async function codesOf(sectionId: string) {
  const rows = await prisma.joinCode.findMany({ where: { sectionId, active: true } });
  return { student: rows.find((r) => r.kind === 'STUDENT')?.code ?? null, teacher: rows.find((r) => r.kind === 'TEACHER')?.code ?? null };
}

/** Join a class with its code: students join it, teachers co-teach it. */
export async function joinWithCode(userId: string, role: Role, raw: string) {
  const code = raw.trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
  const c = await prisma.joinCode.findUnique({ where: { code } });
  if (!c || !c.active || !c.sectionId) throw notFound('This code is not valid. Check it with your teacher.');
  const section = await prisma.section.findUnique({ where: { id: c.sectionId } });
  if (!section || section.archivedAt) throw bad('This class has ended.');
  if (c.kind === 'STUDENT') {
    if (role !== 'STUDENT') throw bad('This is a student code. Teachers need the co-teacher code.');
    await prisma.enrollment.upsert({ where: { sectionId_studentId: { sectionId: section.id, studentId: userId } }, create: { sectionId: section.id, studentId: userId }, update: {} });
  } else {
    if (role !== 'TEACHER') throw bad('This is a co-teacher code. Students need the class code.');
    await prisma.sectionTeacher.upsert({ where: { sectionId_teacherId: { sectionId: section.id, teacherId: userId } }, create: { sectionId: section.id, teacherId: userId }, update: {} });
  }
  await prisma.joinCode.update({ where: { code }, data: { uses: { increment: 1 } } });
  await audit(userId, c.kind === 'STUDENT' ? 'class.joined' : 'class.coteach', section.id);
  const label = (await sectionInfo([section.id])).get(section.id)!.label;
  return { sectionId: section.id, label };
}

async function assertTeacher(req: FastifyRequest, sectionId: string) {
  if (!(await prisma.section.findUnique({ where: { id: sectionId } }))) throw notFound('class not found');
  if (!(await teaches(req.user.id, [sectionId]))) throw forbidden('this is not your class');
}

async function assertMember(req: FastifyRequest, sectionId: string) {
  if (req.user.role === 'TEACHER') return assertTeacher(req, sectionId);
  if (!(await prisma.enrollment.count({ where: { sectionId, studentId: req.user.id } }))) throw forbidden('you are not in this class');
}

async function classView(sectionId: string, forTeacher: boolean) {
  const s = await prisma.section.findUniqueOrThrow({
    where: { id: sectionId },
    include: { course: true, teachers: { include: { teacher: { select: { id: true, name: true } } } }, _count: { select: { enrollments: true } } },
  });
  const info = (await sectionInfo([sectionId])).get(sectionId)!;
  return {
    id: s.id,
    label: info.label,
    subject: s.course ? { code: s.course.code, name: s.course.name } : null,
    groupName: s.groupName,
    startDate: s.startDate,
    endDate: s.endDate,
    archived: !!s.archivedAt,
    teachers: s.teachers.map((t) => t.teacher),
    students: s._count.enrollments,
    ...(forTeacher ? { codes: await codesOf(s.id) } : {}),
  };
}

export async function classRoutes(app: FastifyInstance) {
  const teacher = { preHandler: requireRole('TEACHER') };
  const member = { preHandler: requireRole('TEACHER', 'STUDENT') };

  /** Teacher creates a class for a subject and a group of students. */
  app.post('/classes', teacher, async (req) => {
    const b = z
      .object({
        subjectName: z.string().trim().min(2).max(120),
        subjectCode: z.string().trim().max(30).optional(),
        groupName: z.string().trim().max(60).optional(),
        startDate: date.optional(),
        endDate: date.optional(),
      })
      .refine((x) => !x.startDate || !x.endDate || x.endDate >= x.startDate, 'end date before start date')
      .parse(req.body);
    const code = b.subjectCode?.toUpperCase() || `SUBJ-${randomCode().slice(0, 5)}`;
    const course = await prisma.course.upsert({ where: { code }, create: { code, name: b.subjectName }, update: {} });
    const slug = `${code}-${b.groupName ?? ''}`.toUpperCase().replace(/[^A-Z0-9]+/g, '-').replace(/-+$/, '');
    let id = slug;
    while (await prisma.section.findUnique({ where: { id } })) id = `${slug}-${randomCode().slice(0, 4)}`;
    await prisma.section.create({
      data: { id, courseId: course.id, groupName: b.groupName || null, startDate: b.startDate ?? null, endDate: b.endDate ?? null, createdBy: req.user.id },
    });
    await prisma.sectionTeacher.create({ data: { sectionId: id, teacherId: req.user.id } });
    await newCode('STUDENT', id, req.user.id);
    await newCode('TEACHER', id, req.user.id);
    await audit(req.user.id, 'class.created', id, b);
    return classView(id, true);
  });

  /** My classes: the ones I teach, or the ones I have joined. */
  app.get('/classes', member, async (req) => {
    const ids =
      req.user.role === 'TEACHER'
        ? (await prisma.sectionTeacher.findMany({ where: { teacherId: req.user.id } })).map((x) => x.sectionId)
        : (await prisma.enrollment.findMany({ where: { studentId: req.user.id } })).map((x) => x.sectionId);
    const views = await Promise.all([...new Set(ids)].map((id) => classView(id, req.user.role === 'TEACHER')));
    return views.sort((a, b) => Number(a.archived) - Number(b.archived) || a.label.localeCompare(b.label));
  });

  app.post('/classes/join', member, async (req) => {
    const { code } = z.object({ code: z.string().min(4) }).parse(req.body);
    const r = await joinWithCode(req.user.id, req.user.role, code);
    return classView(r.sectionId, req.user.role === 'TEACHER');
  });

  app.get('/classes/:id', member, async (req) => {
    const { id } = req.params as { id: string };
    await assertMember(req, id);
    const view = await classView(id, req.user.role === 'TEACHER');
    const slots = await prisma.timetableSlot.findMany({ where: { sectionId: id }, orderBy: [{ weekday: 'asc' }, { startMin: 'asc' }] });
    const students =
      req.user.role === 'TEACHER'
        ? (await prisma.enrollment.findMany({ where: { sectionId: id }, include: { student: { select: { id: true, name: true, rollNo: true, email: true, devices: { where: { revokedAt: null }, select: { model: true, attestationOk: true, attestationDetail: true } } } } } }))
            .map((e) => ({ id: e.student.id, name: e.student.name, rollNo: e.student.rollNo, email: e.student.email, phone: e.student.devices[0] ?? null }))
            .sort((a, b) => (a.rollNo ?? a.name).localeCompare(b.rollNo ?? b.name))
        : undefined;
    return { ...view, timetable: slots, students };
  });

  app.patch('/classes/:id', teacher, async (req) => {
    const { id } = req.params as { id: string };
    await assertTeacher(req, id);
    const b = z
      .object({
        subjectName: z.string().trim().min(2).max(120).optional(),
        groupName: z.string().trim().max(60).nullable().optional(),
        startDate: date.nullable().optional(),
        endDate: date.nullable().optional(),
        archived: z.boolean().optional(),
      })
      .parse(req.body);
    const s = await prisma.section.findUniqueOrThrow({ where: { id } });
    if (b.subjectName && s.courseId) await prisma.course.update({ where: { id: s.courseId }, data: { name: b.subjectName } });
    await prisma.section.update({
      where: { id },
      data: {
        groupName: b.groupName === undefined ? undefined : b.groupName || null,
        startDate: b.startDate === undefined ? undefined : b.startDate,
        endDate: b.endDate === undefined ? undefined : b.endDate,
        archivedAt: b.archived === undefined ? undefined : b.archived ? new Date() : null,
      },
    });
    // Keep weekly slots inside the class dates.
    if (b.startDate !== undefined || b.endDate !== undefined) {
      const fresh = await prisma.section.findUniqueOrThrow({ where: { id } });
      await prisma.timetableSlot.updateMany({ where: { sectionId: id }, data: { validFrom: fresh.startDate ?? '2000-01-01', validTo: fresh.endDate ?? '2100-12-31' } });
    }
    await audit(req.user.id, 'class.updated', id, b);
    return classView(id, true);
  });

  /** Delete a class. A class with attendance records is archived instead (records are kept). */
  app.delete('/classes/:id', teacher, async (req) => {
    const { id } = req.params as { id: string };
    await assertTeacher(req, id);
    if (await prisma.session.count({ where: { sectionIds: { has: id } } })) {
      await prisma.section.update({ where: { id }, data: { archivedAt: new Date() } });
      await prisma.timetableSlot.deleteMany({ where: { sectionId: id } });
      await audit(req.user.id, 'class.archived', id);
      return { archived: true };
    }
    await prisma.$transaction([
      prisma.timetableSlot.deleteMany({ where: { sectionId: id } }),
      prisma.joinCode.updateMany({ where: { sectionId: id }, data: { active: false } }),
      prisma.sectionTeacher.deleteMany({ where: { sectionId: id } }),
      prisma.sectionSettings.deleteMany({ where: { sectionId: id } }),
      prisma.enrollment.deleteMany({ where: { sectionId: id } }),
      prisma.section.delete({ where: { id } }),
    ]);
    await audit(req.user.id, 'class.deleted', id);
    return { deleted: true };
  });

  /** New class code or co-teacher code; the old one stops working. */
  app.post('/classes/:id/codes', teacher, async (req) => {
    const { id } = req.params as { id: string };
    await assertTeacher(req, id);
    const { kind } = z.object({ kind: z.enum(['STUDENT', 'TEACHER']) }).parse(req.body);
    await newCode(kind, id, req.user.id);
    return codesOf(id);
  });

  app.delete('/classes/:id/students/:studentId', teacher, async (req) => {
    const { id, studentId } = req.params as { id: string; studentId: string };
    await assertTeacher(req, id);
    await prisma.enrollment.deleteMany({ where: { sectionId: id, studentId } });
    await audit(req.user.id, 'class.student_removed', id, { studentId });
    return { ok: true };
  });

  /** A co-teacher stops teaching the class (the last teacher cannot leave; delete it instead). */
  app.post('/classes/:id/leave', teacher, async (req) => {
    const { id } = req.params as { id: string };
    await assertTeacher(req, id);
    if ((await prisma.sectionTeacher.count({ where: { sectionId: id } })) < 2) throw bad('You are the only teacher. Delete or archive the class instead.');
    await prisma.sectionTeacher.delete({ where: { sectionId_teacherId: { sectionId: id, teacherId: req.user.id } } });
    return { ok: true };
  });

  // ---- weekly timetable of a class
  app.post('/classes/:id/timetable', teacher, async (req) => {
    const { id } = req.params as { id: string };
    await assertTeacher(req, id);
    const b = z.object({ day: z.string(), start: z.string(), end: z.string(), room: z.string().trim().max(60).optional() }).parse(req.body);
    const weekday = WEEKDAYS[b.day.slice(0, 3).toLowerCase()];
    if (!weekday) throw bad('bad day');
    const startMin = hhmm(b.start), endMin = hhmm(b.end);
    if (endMin <= startMin) throw bad('end must be after start');
    // A teacher can't be in two places at once. The exact same time for another group is fine:
    // that's a combined class (both groups taught together).
    const mine = await prisma.timetableSlot.findMany({ where: { teacherId: req.user.id, weekday } });
    const clash = mine.find((s) => s.startMin < endMin && startMin < s.endMin && !(s.sectionId !== id && s.startMin === startMin && s.endMin === endMin));
    if (clash) throw bad('You already have a class at that time. (Same start and end for another group makes a combined class.)');
    const s = await prisma.section.findUniqueOrThrow({ where: { id } });
    if (b.room) await prisma.room.upsert({ where: { id: b.room }, create: { id: b.room, name: b.room }, update: {} });
    const slot = await prisma.timetableSlot.create({
      data: { sectionId: id, teacherId: req.user.id, roomId: b.room || null, weekday, startMin, endMin, validFrom: s.startDate ?? '2000-01-01', validTo: s.endDate ?? '2100-12-31' },
    });
    await audit(req.user.id, 'timetable.added', id, b);
    return slot;
  });

  app.delete('/classes/:id/timetable/:slotId', teacher, async (req) => {
    const { id, slotId } = req.params as { id: string; slotId: string };
    await assertTeacher(req, id);
    await prisma.timetableSlot.deleteMany({ where: { id: slotId, sectionId: id } });
    return { ok: true };
  });

  // ---- attendance sheet (register)
  /** Teacher: whole class. ?format=csv to download. */
  app.get('/classes/:id/register', teacher, async (req, rep) => {
    const { id } = req.params as { id: string };
    await assertTeacher(req, id);
    const { format } = z.object({ format: z.enum(['json', 'csv']).default('json') }).parse(req.query);
    const r = await sectionReport(id);
    if (format === 'csv') return rep.header('content-type', 'text/csv').header('content-disposition', `attachment; filename="${id}.csv"`).send(toCsv(r));
    return { class: await classView(id, true), ...r };
  });

  /** Leave (medical, on duty…) for a student in this class: those classes count as excused. */
  app.post('/classes/:id/excuse', teacher, async (req) => {
    const { id } = req.params as { id: string };
    await assertTeacher(req, id);
    const b = z.object({ studentId: z.string(), fromDate: date, toDate: date, reason: z.string().trim().min(2).max(300) }).parse(req.body);
    if (!(await prisma.enrollment.count({ where: { sectionId: id, studentId: b.studentId } }))) throw notFound('student is not in this class');
    await prisma.excuse.create({ data: { studentId: b.studentId, fromDate: b.fromDate, toDate: b.toDate, reason: b.reason, sectionIds: [id], createdBy: req.user.id } });
    const sessions = await prisma.session.findMany({ where: { sectionIds: { has: id }, state: 'ENDED' }, select: { id: true } });
    for (const s of sessions) await recomputeSession(s.id);
    await notify([b.studentId], 'excuse', 'Leave recorded', `${b.fromDate} to ${b.toDate}: ${b.reason}`);
    await audit(req.user.id, 'excuse.created', id, b);
    return { ok: true };
  });

  // ---- new phones of my students (they would otherwise wait 48 h)
  app.get('/teacher/device-requests', teacher, async (req) => {
    const mine = (await prisma.sectionTeacher.findMany({ where: { teacherId: req.user.id } })).map((x) => x.sectionId);
    const students = (await prisma.enrollment.findMany({ where: { sectionId: { in: mine } } })).map((e) => e.studentId);
    const reqs = await prisma.deviceChangeRequest.findMany({ where: { status: 'PENDING', userId: { in: students } }, orderBy: { requestedAt: 'asc' } });
    return Promise.all(
      reqs.map(async (r) => {
        const [user, current] = await Promise.all([
          prisma.user.findUnique({ where: { id: r.userId }, select: { name: true, rollNo: true } }),
          prisma.device.findFirst({ where: { userId: r.userId, revokedAt: null } }),
        ]);
        return {
          id: r.id, user, requestedAt: r.requestedAt, eligibleAt: r.eligibleAt, model: r.model, attestationOk: r.attestationOk,
          current: current && { model: current.model, platform: current.platform },
          likelySamePhone: !!r.installId && r.installId === current?.installId,
        };
      }),
    );
  });

  app.post('/teacher/device-requests/:id', teacher, async (req) => {
    const { id } = req.params as { id: string };
    const { approve } = z.object({ approve: z.boolean() }).parse(req.body);
    const r = await prisma.deviceChangeRequest.findUniqueOrThrow({ where: { id } });
    const mine = (await prisma.sectionTeacher.findMany({ where: { teacherId: req.user.id } })).map((x) => x.sectionId);
    if (!(await prisma.enrollment.count({ where: { studentId: r.userId, sectionId: { in: mine } } }))) throw forbidden('not your student');
    if (approve) return { deviceId: await approveDeviceChange(id, req.user.id) };
    await prisma.deviceChangeRequest.update({ where: { id }, data: { status: 'REJECTED', decidedBy: req.user.id } });
    await notify([r.userId], 'device.change', 'New phone not approved', 'Your teacher did not approve the new phone. Talk to them.');
    await audit(req.user.id, 'device.change_rejected', id);
    return { ok: true };
  });
}

/** Class ids to members helper for other modules. */
export async function isMember(userId: string, role: Role, sectionId: string) {
  if (role === 'TEACHER') return teaches(userId, [sectionId]);
  return (await prisma.enrollment.count({ where: { sectionId, studentId: userId } })) > 0;
}
