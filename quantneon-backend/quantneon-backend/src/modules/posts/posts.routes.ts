import { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../config/database';
import { logger } from '../../utils/logger';
import '../../types/index';

const CreatePostSchema = z.object({
  caption: z.string().max(2200).optional(),
  mediaUrl: z.string().url().optional(),
  mediaType: z.enum(['IMAGE', 'VIDEO', 'AR_SCENE', 'HOLOGRAM']).default('IMAGE'),
  mood: z.string().max(50).optional(),
  tags: z.array(z.string()).default([]),
  isAR: z.boolean().default(false),
  arAnchorUrl: z.string().url().optional(),
});

export async function postsRoutes(fastify: FastifyInstance): Promise<void> {
  /** POST /v1/posts — Create a new NeonPost */
  fastify.post('/', { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const parsed = CreatePostSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });

    const post = await prisma.neonPost.create({
      data: { authorId: request.user!.id, ...parsed.data },
      include: { author: { select: { username: true, displayName: true, avatarUrl: true } } },
    });

    logger.info({ postId: post.id, authorId: request.user!.id }, 'NeonPost created');
    return reply.code(201).send({ post });
  });

  /** GET /v1/posts/feed — Personalized feed (proxies NeonFeed service) */
  fastify.get('/feed', { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const query = request.query as { limit?: string; offset?: string };
    const limit = parseInt(query.limit ?? '20', 10);
    const offset = parseInt(query.offset ?? '0', 10);

    const { NeonFeedService } = await import('../../services/NeonFeed');
    const feed = await NeonFeedService.getPersonalizedFeed(request.user!.id, limit, offset);
    return reply.send(feed);
  });

  /** GET /v1/posts/user/:userId — Get posts by a user */
  fastify.get('/user/:userId', async (request: FastifyRequest<{ Params: { userId: string } }>, reply: FastifyReply) => {
    const query = request.query as { limit?: string; offset?: string };
    const limit = parseInt(query.limit ?? '20', 10);
    const offset = parseInt(query.offset ?? '0', 10);

    const [posts, total] = await Promise.all([
      prisma.neonPost.findMany({
        where: { authorId: request.params.userId },
        take: limit,
        skip: offset,
        include: { author: { select: { username: true, displayName: true } } },
        orderBy: { createdAt: 'desc' },
      }),
      prisma.neonPost.count({ where: { authorId: request.params.userId } }),
    ]);
    return reply.send({ posts, total, limit, offset });
  });

  /** GET /v1/posts/:id — Get a specific post */
  fastify.get('/:id', async (request: FastifyRequest<{ Params: { id: string } }>, reply: FastifyReply) => {
    const post = await prisma.neonPost.findUnique({
      where: { id: request.params.id },
      include: { author: { select: { username: true, displayName: true, avatarUrl: true } } },
    });
    if (!post) return reply.code(404).send({ error: 'Post not found' });

    prisma.neonPost
      .update({ where: { id: post.id }, data: { viewCount: { increment: 1 } } })
      .catch(() => {});

    return reply.send({ post });
  });

  /** POST /v1/posts/:id/like — Like a post */
  fastify.post('/:id/like', { preHandler: [fastify.authenticate] }, async (request, reply: FastifyReply) => {
    const { id } = request.params as { id: string };
    const post = await prisma.neonPost.update({
      where: { id },
      data: { likeCount: { increment: 1 } },
    });
    return reply.send({ likeCount: post.likeCount });
  });

  /** DELETE /v1/posts/:id — Delete own post */
  fastify.delete('/:id', { preHandler: [fastify.authenticate] }, async (request, reply: FastifyReply) => {
    const { id } = request.params as { id: string };
    const post = await prisma.neonPost.findUnique({ where: { id } });
    if (!post) return reply.code(404).send({ error: 'Post not found' });
    if (post.authorId !== request.user!.id) return reply.code(403).send({ error: 'Not the post author' });

    await prisma.neonPost.delete({ where: { id } });
    return reply.code(204).send();
  });
}
