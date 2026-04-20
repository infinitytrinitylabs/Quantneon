import { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { z } from 'zod';
import { env } from '../../config/env';
import { prisma } from '../../config/database';
import { redis } from '../../config/redis';
import { verifyQuantmailToken } from '../../middleware/auth';
import { logger } from '../../utils/logger';
import '../../types/index';

const SsoSchema = z.object({
  token: z.string().min(1, 'Quantmail JWT is required'),
});

const getSsoRateLimitMax = () => Math.min(env.RATE_LIMIT_MAX, env.SSO_RATE_LIMIT_MAX);

/**
 * POST /v1/auth/sso
 *
 * Biometric SSO entry point. The Godot client (or web front-end) passes the
 * Quantmail-issued JWT here. We verify it, then upsert the local Quantneon
 * user record so the caller can act on the rest of the API.
 *
 * No local passwords are stored or accepted.
 */
export async function authRoutes(fastify: FastifyInstance): Promise<void> {
  const ssoRateLimit = fastify.rateLimit({
    max: getSsoRateLimitMax(),
    timeWindow: env.RATE_LIMIT_WINDOW_MS,
  });

  const enforceSsoRateLimit = async (request: FastifyRequest, reply: FastifyReply) => {
    const clientIp = request.ip || 'unknown';
    const rateLimitKey = `ratelimit:sso:${clientIp}`;

    try {
      const attempts = await redis.incr(rateLimitKey);
      if (attempts === 1) {
        await redis.pexpire(rateLimitKey, env.RATE_LIMIT_WINDOW_MS);
      }

      if (attempts > getSsoRateLimitMax()) {
        return reply.code(429).send({ error: 'Too many authentication attempts. Please try again later.' });
      }
    } catch (err) {
      logger.warn({ err, clientIp }, 'SSO fallback rate limit check failed');
    }
  };

  fastify.post(
    '/sso',
    {
      preHandler: [ssoRateLimit, enforceSsoRateLimit],
      schema: {
        description: 'Authenticate with a Quantmail JWT (Biometric SSO). No local passwords.',
        body: {
          type: 'object',
          required: ['token'],
          properties: {
            token: { type: 'string', description: 'Quantmail-issued JWT' },
          },
        },
        response: {
          200: {
            type: 'object',
            properties: {
              user: { type: 'object' },
              isNewUser: { type: 'boolean' },
            },
          },
        },
      },
    },
    async (request: FastifyRequest, reply: FastifyReply) => {
      const parsed = SsoSchema.safeParse(request.body);
      if (!parsed.success) {
        return reply.code(400).send({ error: parsed.error.flatten() });
      }

      let payload;
      try {
        payload = verifyQuantmailToken(parsed.data.token);
      } catch (err) {
        logger.warn({ err }, 'SSO token verification failed');
        return reply.code(401).send({ error: 'Invalid Quantmail token' });
      }

      const { sub: quantmailId, username, email } = payload;
      const displayName = username ?? email?.split('@')[0] ?? `user_${quantmailId.slice(0, 8)}`;

      const existing = await prisma.user.findUnique({ where: { quantmailId } });
      const isNewUser = !existing;

      let generatedUsername = displayName.toLowerCase().replace(/\s+/g, '_');
      let user;

      try {
        user = await prisma.user.upsert({
          where: { quantmailId },
          create: {
            quantmailId,
            username: generatedUsername,
            displayName,
            avatar: { create: {} }, // Bootstrap empty avatar
          },
          update: { displayName },
          include: { avatar: true },
        });
      } catch (err: any) {
        // Handle username collision (unique constraint violation)
        if (err.code === 'P2002' && err.meta?.target?.includes('username')) {
          // Generate a unique username by appending random suffix
          const randomSuffix = Math.random().toString(36).substring(2, 8);
          generatedUsername = `${generatedUsername}_${randomSuffix}`;

          user = await prisma.user.upsert({
            where: { quantmailId },
            create: {
              quantmailId,
              username: generatedUsername,
              displayName,
              avatar: { create: {} },
            },
            update: { displayName },
            include: { avatar: true },
          });
        } else {
          throw err; // Re-throw other errors
        }
      }

      logger.info({ userId: user.id, isNewUser }, 'SSO login successful');

      return reply.send({ user, isNewUser });
    },
  );

  /**
   * GET /v1/auth/me
   * Returns the currently authenticated user's profile.
   */
  fastify.get(
    '/me',
    {
      preHandler: [fastify.authenticate],
    },
    async (request: FastifyRequest, reply: FastifyReply) => {
      const user = await prisma.user.findUnique({
        where: { id: request.user!.id },
        include: { avatar: true },
      });
      return reply.send({ user });
    },
  );
}
