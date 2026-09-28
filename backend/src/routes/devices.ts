import { createPublicKey } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { attestationFor } from '../services/devices.js';
import { requireRole } from '../lib/auth.js';
import { audit } from '../lib/audit.js';
import { prisma } from '../lib/db.js';
import { bad, forbidden } from '../lib/http.js';
import { CONSENT_VERSION } from '../services/consent.js';
import { notify } from '../lib/notify.js';
import { teachersOfStudent } from '../services/accounts.js';
import { loadPolicy } from '../lib/policy.js';

const HOUR = 3_600_000;

export async function deviceRoutes(app: FastifyInstance) {
  /**
   * Bind this phone's hardware key to the account. First device binds immediately.
   * A different device starts a change request that auto-approves after the cooldown
   * (a friend cannot silently move your account to their phone mid-semester).
   */
  app.post('/devices/bind', { preHandler: requireRole() }, async (req) => {
    const body = z
      .object({
        platform: z.enum(['android', 'ios']),
        publicKeySpki: z.string().max(400),
        attestation: z.string().max(20_000).default(''),
        // Shown to admins only. Never used for security: any of these can be faked on a rooted phone.
        model: z.string().max(100).optional(),
        osVersion: z.string().max(100).optional(),
        installId: z.string().max(100).optional(),
      })
      .parse(req.body);
    const info = { model: body.model ?? null, osVersion: body.osVersion ?? null, installId: body.installId ?? null };
    try {
      const k = createPublicKey({ key: Buffer.from(body.publicKeySpki, 'base64'), format: 'der', type: 'spki' });
      if (k.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error();
    } catch {
      throw bad('publicKeySpki must be a P-256 SPKI key');
    }
    const me = await prisma.user.findUniqueOrThrow({ where: { id: req.user.id } });
    if (me.consentVersion !== CONSENT_VERSION) throw forbidden('please accept the privacy notice first');
    const att = await attestationFor(body.platform, body.publicKeySpki, body.attestation);
    const userId = req.user.id;

    const current = await prisma.device.findFirst({ where: { userId, revokedAt: null } });
    if (current?.publicKeySpki === body.publicKeySpki) {
      await prisma.device.update({ where: { id: current.id }, data: info });
      return { status: 'BOUND', deviceId: current.id };
    }
    const taken = await prisma.device.findFirst({ where: { publicKeySpki: body.publicKeySpki, revokedAt: null } });
    if (taken) throw bad('this key is bound to another account');

    if (!current) {
      const d = await prisma.device.create({ data: { userId, platform: body.platform, publicKeySpki: body.publicKeySpki, ...att, ...info } });
      await audit(userId, 'device.bound', d.id);
      return { status: 'BOUND', deviceId: d.id };
    }

    // Teachers switch phones without a cooldown; students wait.
    const p = await loadPolicy();
    const cooldown = req.user.role === 'STUDENT' ? p.deviceChangeCooldownHours * HOUR : 0;
    await prisma.deviceChangeRequest.updateMany({ where: { userId, status: 'PENDING' }, data: { status: 'REJECTED', decidedBy: 'superseded' } });
    const r = await prisma.deviceChangeRequest.create({
      data: {
        userId, platform: body.platform, publicKeySpki: body.publicKeySpki, attestation: att.attestationType, attestationOk: att.attestationOk,
        attestationDetail: att.attestationDetail, eligibleAt: new Date(Date.now() + cooldown), ...info,
      },
    });
    await audit(userId, 'device.change_requested', r.id);
    await notify([userId], 'device.change', 'New phone requested',
      'Your account will move to the new phone after the waiting period. If this was not you, contact the admin.');
    if (cooldown === 0) {
      const { approveDeviceChange } = await import('../services/devices.js');
      const deviceId = await approveDeviceChange(r.id, 'auto');
      return { status: 'BOUND', deviceId };
    }
    const student = await prisma.user.findUniqueOrThrow({ where: { id: userId }, select: { name: true } });
    await notify(await teachersOfStudent(userId), 'device.change', 'New phone to approve', `${student.name} wants to switch phones. Approve in Exist (My classes → New phones), or it happens automatically in ${p.deviceChangeCooldownHours} h.`, { requestId: r.id });
    return { status: 'PENDING', requestId: r.id, eligibleAt: r.eligibleAt.getTime() };
  });

  /** Poll after a PENDING bind. */
  app.get('/devices/request/:id', { preHandler: requireRole() }, async (req) => {
    const { id } = req.params as { id: string };
    const r = await prisma.deviceChangeRequest.findFirstOrThrow({ where: { id, userId: req.user.id } });
    return { status: r.status, eligibleAt: r.eligibleAt.getTime(), deviceId: r.deviceId };
  });
}
