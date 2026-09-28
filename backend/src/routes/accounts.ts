// Accounts, entirely between teachers and students (no administrator):
// sign-up as teacher or student, join codes, forgot password, delete your own account.
import { createHash, randomInt, timingSafeEqual } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireRole } from '../lib/auth.js';
import { audit } from '../lib/audit.js';
import { prisma } from '../lib/db.js';
import { bad, forbidden, HttpError, notFound } from '../lib/http.js';
import { emailEnabled, sendMail } from '../lib/mail.js';
import { checkPassword, hashPassword } from '../lib/passwords.js';
import { eraseUser } from '../services/accounts.js';
import { joinWithCode } from './classes.js';

const password = z.string().min(8, 'Password must be at least 8 characters').max(200);
const email = z.string().trim().toLowerCase().email();
const sha = (s: string) => createHash('sha256').update(s).digest('hex');

// Simple in-memory throttle for public endpoints: `limit` per 10 min per key.
const hits = new Map<string, { n: number; since: number }>();
export function throttle(key: string, limit = 20) {
  const now = Date.now();
  const h = hits.get(key);
  if (!h || now - h.since > 10 * 60_000) return void hits.set(key, { n: 1, since: now });
  if (++h.n > limit) throw new HttpError(429, 'too many attempts; try again later');
}

/** Set when the server is launched (deploy/setup.sh). */
export const institution = () => process.env.INSTITUTION_NAME || null;
const teacherCode = () => (process.env.TEACHER_SIGNUP_CODE ?? '').trim().toUpperCase();

export async function accountRoutes(app: FastifyInstance) {
  app.get('/setup/status', async () => ({
    institution: institution(),
    emailEnabled: emailEnabled(),
    /** Teachers need the institution's teacher code to sign up (if one was set at launch). */
    teacherCodeRequired: !!teacherCode(),
  }));

  /** Create your own account. Students can join a class right away with its code. Signs you in. */
  app.post('/auth/register', async (req) => {
    throttle(`register:${req.ip}`);
    const b = z
      .object({
        role: z.enum(['STUDENT', 'TEACHER']),
        name: z.string().trim().min(2).max(100),
        email,
        password,
        rollNo: z.string().trim().max(50).optional(),
        teacherCode: z.string().optional(),
        classCode: z.string().optional(),
      })
      .parse(req.body);
    if (b.role === 'TEACHER' && teacherCode() && (b.teacherCode ?? '').trim().toUpperCase() !== teacherCode()) {
      throw forbidden('Wrong teacher code. Ask your institution for it.');
    }
    if (b.role === 'STUDENT' && !b.rollNo) throw bad('Enter your roll number');
    if (await prisma.user.findUnique({ where: { email: b.email } })) throw bad('An account with this email already exists. Sign in instead.');
    if (b.rollNo && b.role === 'STUDENT' && (await prisma.user.findUnique({ where: { rollNo: b.rollNo } }))) {
      throw bad('This roll number is already registered. Tell your teacher if this is wrong.');
    }
    const user = await prisma.user.create({
      data: { role: b.role, name: b.name, email: b.email, rollNo: b.role === 'STUDENT' ? b.rollNo : null, passwordHash: await hashPassword(b.password) },
    });
    await audit(user.id, 'account.registered', user.id, { role: b.role });
    let joined: string | null = null;
    if (b.classCode) joined = (await joinWithCode(user.id, user.role, b.classCode)).label;
    return {
      token: app.jwt.sign({ id: user.id, role: user.role, sv: user.sessionVersion }),
      user: { id: user.id, role: user.role, name: user.name, email: user.email, rollNo: user.rollNo, mustChangePassword: false },
      joined,
    };
  });

  // ---------------------------------------------------------------- forgot password
  app.post('/auth/forgot', async (req) => {
    throttle(`forgot:${req.ip}`, 10);
    const b = z.object({ email }).parse(req.body);
    if (!emailEnabled()) return { emailSent: false, message: 'Students: ask your teacher to reset your password in the app.' };
    const u = await prisma.user.findUnique({ where: { email: b.email } });
    if (u && !u.disabledAt) {
      const code = String(randomInt(100000, 1000000));
      await prisma.user.update({ where: { id: u.id }, data: { resetCodeHash: sha(`${u.id}:${code}`), resetExpires: new Date(Date.now() + 15 * 60_000), resetAttempts: 0 } });
      await sendMail(u.email, 'Your Exist password reset code', `Your code is ${code}. It is valid for 15 minutes.\n\nIf you did not ask for this, ignore this email.`)
        .catch((e) => req.log.error(e, 'reset mail failed'));
    }
    // Same answer whether or not the email exists, so it can't be used to find accounts.
    return { emailSent: true, message: 'If this email has an account, a 6-digit code was sent to it.' };
  });

  app.post('/auth/reset', async (req) => {
    throttle(`reset:${req.ip}`, 20);
    const b = z.object({ email, code: z.string().trim().regex(/^\d{6}$/), password }).parse(req.body);
    const u = await prisma.user.findUnique({ where: { email: b.email } });
    const invalid = new HttpError(400, 'Wrong or expired code');
    if (!u || !u.resetCodeHash || !u.resetExpires || u.resetExpires < new Date() || u.resetAttempts >= 5) throw invalid;
    const ok = timingSafeEqual(Buffer.from(u.resetCodeHash, 'hex'), Buffer.from(sha(`${u.id}:${b.code}`), 'hex'));
    if (!ok) {
      await prisma.user.update({ where: { id: u.id }, data: { resetAttempts: { increment: 1 } } });
      throw invalid;
    }
    await prisma.user.update({
      where: { id: u.id },
      data: { passwordHash: await hashPassword(b.password), mustChangePassword: false, resetCodeHash: null, resetExpires: null, resetAttempts: 0, sessionVersion: { increment: 1 } },
    });
    await audit(u.id, 'password.reset_by_email', u.id);
    return { ok: true };
  });

  // ---------------------------------------------------------------- your own account
  app.patch('/me', { preHandler: requireRole() }, async (req) => {
    const b = z.object({ name: z.string().trim().min(2).max(100).optional(), rollNo: z.string().trim().max(50).optional() }).parse(req.body);
    try {
      await prisma.user.update({ where: { id: req.user.id }, data: { name: b.name, rollNo: req.user.role === 'STUDENT' ? b.rollNo : undefined } });
    } catch {
      throw bad('This roll number is already registered');
    }
    return { ok: true };
  });

  /** Delete your account: personal data is erased; attendance stays in registers, anonymised. */
  app.post('/me/delete', { preHandler: requireRole() }, async (req) => {
    const { password: pw } = z.object({ password: z.string() }).parse(req.body);
    const u = await prisma.user.findUniqueOrThrow({ where: { id: req.user.id } });
    if (!(await checkPassword(pw, u.passwordHash))) throw bad('Wrong password');
    await eraseUser(u.id, u.id);
    return { ok: true };
  });

  /** Public: what a class code is for, shown before joining. */
  app.get('/auth/join/:code', async (req) => {
    throttle(`join:${req.ip}`, 60);
    const code = (req.params as { code: string }).code.trim().toUpperCase().replace(/[^A-Z0-9]/g, '');
    const c = await prisma.joinCode.findUnique({ where: { code } });
    if (!c || !c.active || !c.sectionId) throw notFound('This code is not valid. Check it with your teacher.');
    const s = await prisma.section.findUnique({ where: { id: c.sectionId }, include: { course: true } });
    return { kind: c.kind, className: s ? `${s.course?.name ?? s.id}${s.groupName ? ` · ${s.groupName}` : ''}` : null, institution: institution() };
  });
}
