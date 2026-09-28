import { audit } from '../lib/audit.js';
import { verifyAttestation } from '../lib/attestation.js';
import { prisma } from '../lib/db.js';
import { bad } from '../lib/http.js';
import { notify } from '../lib/notify.js';

export async function attestationFor(platform: string, spki: string, attestation: string) {
  const r = await verifyAttestation(platform, spki, attestation);
  if (!r.ok) throw bad(`This phone cannot be used for attendance: ${r.reason}`);
  return { attestationType: r.type, attestationOk: r.verified, attestationDetail: r.detail };
}

export async function approveDeviceChange(requestId: string, decidedBy: string): Promise<string> {
  return prisma.$transaction(async (tx) => {
    const r = await tx.deviceChangeRequest.findUniqueOrThrow({ where: { id: requestId } });
    if (r.status !== 'PENDING') throw bad('request is not pending');
    await tx.device.updateMany({ where: { userId: r.userId, revokedAt: null }, data: { revokedAt: new Date() } });
    const d = await tx.device.create({
      data: {
        userId: r.userId, platform: r.platform, publicKeySpki: r.publicKeySpki, attestationType: r.attestation,
        attestationOk: r.attestationOk, attestationDetail: r.attestationDetail, model: r.model, osVersion: r.osVersion, installId: r.installId,
      },
    });
    await tx.deviceChangeRequest.update({ where: { id: r.id }, data: { status: 'APPROVED', decidedBy, deviceId: d.id } });
    await audit(decidedBy === 'auto' ? null : decidedBy, 'device.change_approved', r.id, { deviceId: d.id });
    await notify([r.userId], 'device.change', 'New phone active', 'Attendance now works on your new phone.');
    return d.id;
  });
}
