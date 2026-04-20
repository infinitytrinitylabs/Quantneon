import { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../config/database';
import { logger } from '../../utils/logger';
import '../../types/index';

const CreateStreamSchema = z.object({
  title: z.string().min(1).max(120),
  description: z.string().max(500).optional(),
  thumbnailUrl: z.string().url().optional(),
  isInteractive: z.boolean().default(true),
  virtualRoomId: z.string().optional(),
});

const UpdateStreamSchema = z.object({
  title: z.string().min(1).max(120).optional(),
  description: z.string().max(500).optional(),
  status: z.enum(['SCHEDULED', 'LIVE', 'ENDED']).optional(),
});

export async function streamsRoutes(fastify: FastifyInstance): Promise<void> {
  /** POST /v1/streams — Create a new live stream */
  fastify.post('/', { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const parsed = CreateStreamSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });

    const stream = await prisma.liveStream.create({
      data: { hostId: request.user!.id, ...parsed.data },
      include: { host: { select: { username: true, displayName: true } } },
    });

    logger.info({ streamId: stream.id, hostId: request.user!.id }, 'Stream created');
    return reply.code(201).send({ stream });
  });

  /** GET /v1/streams — List live streams */
  fastify.get('/', async (request, reply) => {
    const query = request.query as { status?: string; limit?: string; offset?: string };
    const status = query.status as 'SCHEDULED' | 'LIVE' | 'ENDED' | undefined;
    const limit = parseInt(query.limit ?? '20', 10);
    const offset = parseInt(query.offset ?? '0', 10);

    const [streams, total] = await Promise.all([
      prisma.liveStream.findMany({
        where: status ? { status } : undefined,
        take: limit,
        skip: offset,
        include: { host: { select: { username: true, displayName: true, avatarUrl: true } } },
        orderBy: [{ status: 'asc' }, { viewerCount: 'desc' }],
      }),
      prisma.liveStream.count({ where: status ? { status } : undefined }),
    ]);
    return reply.send({ streams, total, limit, offset });
  });

  /** GET /v1/streams/:id — Get a specific stream */
  fastify.get('/:id', async (request: FastifyRequest<{ Params: { id: string } }>, reply: FastifyReply) => {
    const stream = await prisma.liveStream.findUnique({
      where: { id: request.params.id },
      include: { host: { select: { username: true, displayName: true, avatarUrl: true } } },
    });
    if (!stream) return reply.code(404).send({ error: 'Stream not found' });
    return reply.send({ stream });
  });

  /** PATCH /v1/streams/:id — Update stream (host only) */
  fastify.patch('/:id', { preHandler: [fastify.authenticate] }, async (request, reply: FastifyReply) => {
    const { id } = request.params as { id: string };
    const stream = await prisma.liveStream.findUnique({ where: { id } });
    if (!stream) return reply.code(404).send({ error: 'Stream not found' });
    if (stream.hostId !== request.user!.id) return reply.code(403).send({ error: 'Not the stream host' });

    const parsed = UpdateStreamSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });

    // Validate state transitions
    if (parsed.data.status) {
      const validTransitions: Record<string, string[]> = {
        SCHEDULED: ['LIVE', 'ENDED'],
        LIVE: ['ENDED'],
        ENDED: [], // No transitions allowed from ENDED
      };

      const allowedStates = validTransitions[stream.status];
      if (!allowedStates.includes(parsed.data.status)) {
        return reply.code(400).send({
          error: `Invalid state transition from ${stream.status} to ${parsed.data.status}`,
        });
      }
    }

    const updates: Record<string, unknown> = { ...parsed.data };
    if (parsed.data.status === 'LIVE' && !stream.startedAt) updates.startedAt = new Date();
    if (parsed.data.status === 'ENDED' && !stream.endedAt) updates.endedAt = new Date();

    const updated = await prisma.liveStream.update({ where: { id }, data: updates });
    return reply.send({ stream: updated });
  });

  /** DELETE /v1/streams/:id — Delete a stream (host only) */
  fastify.delete('/:id', { preHandler: [fastify.authenticate] }, async (request, reply: FastifyReply) => {
    const { id } = request.params as { id: string };
    const stream = await prisma.liveStream.findUnique({ where: { id } });
    if (!stream) return reply.code(404).send({ error: 'Stream not found' });
    if (stream.hostId !== request.user!.id) return reply.code(403).send({ error: 'Not the stream host' });

    await prisma.liveStream.delete({ where: { id } });
    return reply.code(204).send();
  });
}
