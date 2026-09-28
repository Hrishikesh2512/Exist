import { buildApp } from './app.js';
import { startJobs } from './jobs/tick.js';
import { config } from './lib/config.js';

const app = await buildApp();
await app.listen({ port: config.port, host: '0.0.0.0' });
startJobs(app.log);
