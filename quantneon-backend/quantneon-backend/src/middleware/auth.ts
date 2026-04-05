import { FastifyRequest, FastifyReply } from 'fastify';
import jwt from 'jsonwebtoken';
import { env } from '../config/env';
import { prisma } from '../config/database';
import { logger } from '../utils/logger';

export interface QuantmailJwtPayload {
  sub: string;   // Quantmail user ID
  email?: string;
  username?: string;
  iss?: string;
  iat?: number;
  exp?: number;
}

export interface AuthenticatedUser {
  id: string;
  quantmailId: string;
  username: string;
  displayName: string;
  isBanned: boolean;
}

declare module 'fastify' {
  interface FastifyRequest {
    user?: AuthenticatedUser;
  }
}

/**
 * Verifies a Quantmail JWT and returns the payload.
 * Supports both HS256 (shared secret) and future RS256 (public key) modes.
 */
export function verifyQuantmailToken(token: string): QuantmailJwtPayload {
  return jwt.verify(token, env.QUANTMAIL_JWT_SECRET, {
    issuer: env.QUANTMAIL_ISSUER,
    algorithms: ['HS256', 'RS256'],
  }) as QuantmailJwtPayload;
}

/**
 * Fastify preHandler hook that authenticates requests via Quantmail JWT.
 * Sets `request.user` on success.
 */
export async function authenticate(
  request: FastifyRequest,
  reply: FastifyReply,
): Promise<void> {
  const authHeader = request.headers.authorization;
  if (!authHeader?.startsWith('Bearer ')) {
    return reply.code(401).send({ error: 'Missing or invalid Authorization header' });
  }

  const token = authHeader.slice(7);
  let payload: QuantmailJwtPayload;

  try {
    payload = verifyQuantmailToken(token);
  } catch (err) {
    logger.warn({ err }, 'JWT verification failed');
    return reply.code(401).send({ error: 'Invalid or expired token' });
  }

  const user = await prisma.user.findUnique({ where: { quantmailId: payload.sub } });
  if (!user) {
    return reply.code(401).send({ error: 'User not found. Please authenticate via /v1/auth/sso' });
  }
  if (user.isBanned) {
    return reply.code(403).send({ error: 'Account suspended' });
  }

  request.user = user;
}
