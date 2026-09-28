import { audit } from '../lib/audit.js';
import { prisma } from '../lib/db.js';

/**
 * Erase a person's personal data (they deleted their account). Attendance records stay for the
 * class register but are no longer linked to a name, email or phone.
 */
export async function eraseUser(id: string, by: string) {
  await prisma.$transaction([
    prisma.device.updateMany({ where: { userId: id }, data: { revokedAt: new Date(), publicKeySpki: 'erased', model: null, osVersion: null, installId: null } }),
    prisma.deviceChangeRequest.deleteMany({ where: { userId: id } }),
    prisma.notification.deleteMany({ where: { userId: id } }),
    prisma.personalEvent.deleteMany({ where: { userId: id } }),
    prisma.dispute.updateMany({ where: { studentId: id }, data: { message: '(erased)' } }),
    prisma.user.update({
      where: { id },
      data: {
        name: 'Deleted account', email: `erased-${id}@invalid`, rollNo: null, calendarToken: null, passwordHash: 'erased',
        consentVersion: null, deletionRequestedAt: new Date(), disabledAt: new Date(), sessionVersion: { increment: 1 },
      },
    }),
  ]);
  await audit(by, 'user.erased', id);
}

/** Teachers of any class a student is in. */
export async function teachersOfStudent(studentId: string): Promise<string[]> {
  const secs = (await prisma.enrollment.findMany({ where: { studentId } })).map((e) => e.sectionId);
  const t = await prisma.sectionTeacher.findMany({ where: { sectionId: { in: secs } } });
  return [...new Set(t.map((x) => x.teacherId))];
}
