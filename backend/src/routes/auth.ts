import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireRole } from '../lib/auth.js';
import { prisma } from '../lib/db.js';
import { HttpError } from '../lib/http.js';
import { audit } from '../lib/audit.js';
import { bad } from '../lib/http.js';
import { checkPassword, hashPassword } from '../lib/passwords.js';
import { CONSENT_VERSION, PRIVACY_NOTICE } from '../services/consent.js';
import { eraseUser } from '../services/accounts.js';

// Lock an email for 15 min after 8 wrong passwords (in memory; resets on restart).
const attempts = new Map<string, { n: number; until: number }>();
function failed(email: string) {
  const a = attempts.get(email) ?? { n: 0, until: 0 };
  a.n++;
  if (a.n >= 8) a.until = Date.now() + 15 * 60_000;
  attempts.set(email, a);
}
function lockedFor(email: string): number {
  const a = attempts.get(email);
  if (!a || a.until < Date.now()) {
    if (a && a.until && a.until < Date.now()) attempts.delete(email);
    return 0;
  }
  return a.until - Date.now();
}

export async function authRoutes(app: FastifyInstance) {
  app.post('/auth/login', async (req) => {
    const { email, password } = z.object({ email: z.string().email(), password: z.string() }).parse(req.body);
    const key = email.toLowerCase();
    const wait = lockedFor(key);
    if (wait) throw new HttpError(429, `too many attempts; try again in ${Math.ceil(wait / 60_000)} min`);
    const user = await prisma.user.findUnique({ where: { email: key } });
    if (!user || user.disabledAt || !(await checkPassword(password, user.passwordHash))) {
      failed(key);
      throw new HttpError(401, 'wrong email or password');
    }
    attempts.delete(key);
    const token = app.jwt.sign({ id: user.id, role: user.role, sv: user.sessionVersion });
    return { token, user: { id: user.id, role: user.role, name: user.name, email: user.email, rollNo: user.rollNo, mustChangePassword: user.mustChangePassword } };
  });

  // Server clock, so phones with a wrong clock still compute the right slots.
  app.get('/time', async () => ({ now: Date.now() }));

  /** Public: the privacy notice (shown before login too). */
  app.get('/consent', async () => PRIVACY_NOTICE);

  app.post('/me/consent', { preHandler: requireRole() }, async (req) => {
    const { version } = z.object({ version: z.number().int() }).parse(req.body);
    if (version !== CONSENT_VERSION) throw bad('please read the latest privacy notice');
    await prisma.user.update({ where: { id: req.user.id }, data: { consentVersion: version, consentAt: new Date(), deletionRequestedAt: null } });
    await audit(req.user.id, 'consent.given', req.user.id, { version });
    return { ok: true };
  });

  /** Withdraw consent = delete the account (there is no administrator to hand it to). */
  app.post('/me/consent/withdraw', { preHandler: requireRole() }, async (req) => {
    await eraseUser(req.user.id, req.user.id);
    return { ok: true };
  });

  app.post('/me/password', { preHandler: requireRole() }, async (req) => {
    const { current, next } = z.object({ current: z.string(), next: z.string().min(8).max(200) }).parse(req.body);
    const u = await prisma.user.findUniqueOrThrow({ where: { id: req.user.id } });
    if (!(await checkPassword(current, u.passwordHash))) throw bad('current password is wrong');
    if (current === next) throw bad('choose a new password');
    const updated = await prisma.user.update({
      where: { id: u.id },
      data: { passwordHash: await hashPassword(next), mustChangePassword: false, sessionVersion: { increment: 1 } },
    });
    await audit(u.id, 'password.changed', u.id);
    // A fresh token, since the old one is now invalid.
    return { token: app.jwt.sign({ id: u.id, role: u.role, sv: updated.sessionVersion }) };
  });

  app.get('/me', { preHandler: requireRole() }, async (req) => {
    const user = await prisma.user.findUniqueOrThrow({
      where: { id: req.user.id },
      select: {
        id: true, role: true, name: true, email: true, rollNo: true, mustChangePassword: true, consentVersion: true,
        enrollments: { select: { sectionId: true } }, classes: { select: { klass: { select: { name: true } } } },
      },
    });
    const device = await prisma.device.findFirst({ where: { userId: user.id, revokedAt: null } });
    const pendingChange = await prisma.deviceChangeRequest.findFirst({ where: { userId: user.id, status: 'PENDING' } });
    return {
      ...user,
      classes: user.classes.map((c) => c.klass.name),
      consentRequired: user.consentVersion !== CONSENT_VERSION,
      currentConsentVersion: CONSENT_VERSION,
      sectionIds: user.enrollments.map((e) => e.sectionId),
      device: device && { id: device.id, platform: device.platform, boundAt: device.boundAt },
      pendingDeviceChange: pendingChange && { id: pendingChange.id, eligibleAt: pendingChange.eligibleAt },
    };
  });
}
