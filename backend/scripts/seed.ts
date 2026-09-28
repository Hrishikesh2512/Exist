// Creates the first admin: ADMIN_EMAIL=... ADMIN_PASSWORD=... npm run seed
import { prisma } from '../src/lib/db.js';
import { hashPassword } from '../src/lib/passwords.js';

const email = (process.env.ADMIN_EMAIL ?? '').toLowerCase();
const password = process.env.ADMIN_PASSWORD ?? '';
if (!email || password.length < 8) {
  console.error('Set ADMIN_EMAIL and ADMIN_PASSWORD (8+ chars)');
  process.exit(1);
}
await prisma.user.upsert({
  where: { email },
  create: { role: 'ADMIN', name: 'Admin', email, passwordHash: await hashPassword(password) },
  update: { role: 'ADMIN', passwordHash: await hashPassword(password) },
});
console.log(`admin ready: ${email}`);
await prisma.$disconnect();
