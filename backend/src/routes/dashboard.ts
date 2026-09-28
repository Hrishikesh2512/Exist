import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs';
import type { FastifyInstance } from 'fastify';

// Works from src/routes (tsx) and dist/src/routes (compiled).
const candidates = ['../../public/index.html', '../../../public/index.html'].map((p) => new URL(p, import.meta.url));
const html = readFileSync(candidates.find((u) => existsSync(u)) ?? candidates[0], 'utf8');

/** Where the Android app file is, if this server should hand it out (APK_PATH). */
const apkPath = process.env.APK_PATH ?? '/downloads/exist.apk';

export async function dashboardRoutes(app: FastifyInstance) {
  app.get('/', async (_req, rep) => rep.type('text/html').send(html));

  /** Android app download (phones open http://<server>/app.apk). */
  app.get('/app.apk', async (_req, rep) => {
    if (!existsSync(apkPath)) return rep.status(404).send({ error: 'app not published on this server' });
    return rep
      .header('content-type', 'application/vnd.android.package-archive')
      .header('content-disposition', 'attachment; filename="exist.apk"')
      .header('content-length', statSync(apkPath).size)
      .send(createReadStream(apkPath));
  });
}
