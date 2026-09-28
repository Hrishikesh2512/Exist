import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { requireRole } from '../lib/auth.js';
import { forbidden } from '../lib/http.js';
import { sectionReport, toCsv } from '../services/reports.js';
import { teaches } from '../services/teaching.js';

export async function reportRoutes(app: FastifyInstance) {
  app.get('/reports/section/:id', { preHandler: requireRole('TEACHER') }, async (req, rep) => {
    const { id } = req.params as { id: string };
    const q = z.object({ from: z.coerce.number().optional(), to: z.coerce.number().optional(), format: z.enum(['json', 'csv']).default('json') }).parse(req.query);
    if (!(await teaches(req.user.id, [id]))) throw forbidden();
    const r = await sectionReport(id, q.from ? new Date(q.from) : undefined, q.to ? new Date(q.to) : undefined);
    if (q.format === 'csv') return rep.header('content-type', 'text/csv').header('content-disposition', `attachment; filename="${id}.csv"`).send(toCsv(r));
    return r;
  });
}
