import cors from '@fastify/cors';
import jwt from '@fastify/jwt';
import Fastify from 'fastify';
import { ZodError } from 'zod';
import { config } from './lib/config.js';
import { HttpError } from './lib/http.js';
import { accountRoutes } from './routes/accounts.js';
import { authRoutes } from './routes/auth.js';
import { calendarRoutes, personalEventRoutes } from './routes/calendar.js';
import { classRoutes } from './routes/classes.js';
import { dashboardRoutes } from './routes/dashboard.js';
import { deviceRoutes } from './routes/devices.js';
import { meRoutes } from './routes/me.js';
import { reportRoutes } from './routes/reports.js';
import { sessionRoutes } from './routes/sessions.js';
import { teacherRoutes } from './routes/teacher.js';

export async function buildApp() {
  const app = Fastify({ logger: process.env.NODE_ENV !== 'test' && { level: 'info' } });
  await app.register(cors, { origin: true });
  await app.register(jwt, { secret: config.jwtSecret, sign: { expiresIn: '30d' } });

  app.setErrorHandler((err, _req, rep) => {
    if (err instanceof HttpError) return rep.status(err.status).send({ error: err.message });
    if (err instanceof ZodError) return rep.status(400).send({ error: 'invalid request', issues: err.issues });
    const e = err as { statusCode?: number; code?: string; message?: string };
    if (e.code === 'P2025') return rep.status(404).send({ error: 'not found' }); // Prisma *OrThrow
    if (e.statusCode && e.statusCode < 500) return rep.status(e.statusCode).send({ error: e.message });
    app.log.error(err);
    if (process.env.NODE_ENV === 'test') console.error(err);
    return rep.status(500).send({ error: 'internal error' });
  });

  app.get('/health', async () => ({ ok: true, time: Date.now() }));
  await app.register(authRoutes);
  await app.register(accountRoutes);
  await app.register(deviceRoutes);
  await app.register(meRoutes);
  await app.register(sessionRoutes);
  await app.register(reportRoutes);
  await app.register(calendarRoutes);
  await app.register(personalEventRoutes);
  await app.register(classRoutes);
  await app.register(teacherRoutes);
  await app.register(dashboardRoutes);
  return app;
}
