import { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../config/database';
import { logger } from '../../utils/logger';
import '../../types/index';

const UpdateAvatarSchema = z.object({
  skinTone: z.string().optional(),
  hairStyle: z.string().optional(),
  outfit: z.string().optional(),
  accessories: z.array(z.string()).optional(),
  glbUrl: z.string().url().optional(),
  previewUrl: z.string().url().optional(),
});

export async function avatarsRoutes(fastify: FastifyInstance): Promise<void> {
  /** GET /v1/avatars/me — Get own avatar */
  fastify.get('/me', { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const avatar = await prisma.userAvatar.findUnique({ where: { userId: request.user!.id } });
    if (!avatar) return reply.code(404).send({ error: 'Avatar not found' });
    return reply.send({ avatar });
  });

  /** PATCH /v1/avatars/me — Update own avatar customization */
  fastify.patch('/me', { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const parsed = UpdateAvatarSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });

    const avatar = await prisma.userAvatar.upsert({
      where: { userId: request.user!.id },
      create: { userId: request.user!.id, ...parsed.data },
      update: parsed.data,
    });

    logger.info({ userId: request.user!.id }, 'Avatar updated');
    return reply.send({ avatar });
  });

  /** GET /v1/avatars — List avatars (paginated) */
  fastify.get('/', { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const query = request.query as { limit?: string; offset?: string };
    const limit = Math.min(parseInt(query.limit ?? '20', 10), 100);
    const offset = parseInt(query.offset ?? '0', 10);

    const [avatars, total] = await Promise.all([
      prisma.userAvatar.findMany({
        take: limit,
        skip: offset,
        include: { user: { select: { username: true, displayName: true, avatarUrl: true } } },
        orderBy: { xpLevel: 'desc' },
      }),
      prisma.userAvatar.count(),
    ]);
    return reply.send({ avatars, total, limit, offset });
  });

  /** GET /v1/avatars/:userId — Get a user's avatar */
  fastify.get('/:userId', async (request, reply) => {
    const { userId } = request.params as { userId: string };
    const avatar = await prisma.userAvatar.findUnique({
      where: { userId },
      include: { user: { select: { username: true, displayName: true } } },
    });
    if (!avatar) return reply.code(404).send({ error: 'Avatar not found' });
    return reply.send({ avatar });
  });
}
