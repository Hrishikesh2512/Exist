import type { FastifyReply, FastifyRequest } from 'fastify';
import { prisma } from './db.js';
import { forbidden, HttpError } from './http.js';

export type Role = 'STUDENT' | 'TEACHER' | 'ADMIN';
export interface AuthUser {
  id: string;
  role: Role;
  /** Session version at login; tokens from before a password change are rejected. */
  sv?: number;
}

declare module '@fastify/jwt' {
  interface FastifyJWT {
    payload: AuthUser;
    user: AuthUser;
  }
}

export function requireRole(...roles: Role[]) {
  return async (req: FastifyRequest, _rep: FastifyReply) => {
    try {
      await req.jwtVerify();
    } catch {
      throw new HttpError(401, 'not signed in');
    }
    const u = await prisma.user.findUnique({ where: { id: req.user.id }, select: { role: true, sessionVersion: true, disabledAt: true } });
    if (!u || u.disabledAt || (u.sessionVersion ?? 0) !== (req.user.sv ?? 0)) throw new HttpError(401, 'signed out: please sign in again');
    req.user = { ...req.user, role: u.role };
    if (roles.length && !roles.includes(req.user.role)) throw forbidden();
  };
}
