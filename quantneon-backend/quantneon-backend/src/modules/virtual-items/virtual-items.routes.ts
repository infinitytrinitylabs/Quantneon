import { FastifyInstance, FastifyRequest, FastifyReply } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../config/database';
import { logger } from '../../utils/logger';
import '../../types/index';

const CreateItemSchema = z.object({
  name: z.string().min(1).max(100),
  description: z.string().max(500).optional(),
  itemType: z.enum(['AVATAR_SKIN', 'OUTFIT', 'ACCESSORY', 'EMOTE', 'BACKGROUND', 'AR_EFFECT', 'VIRTUAL_GIFT']),
  rarity: z.enum(['COMMON', 'RARE', 'EPIC', 'LEGENDARY']).default('COMMON'),
  previewUrl: z.string().url().optional(),
  glbUrl: z.string().url().optional(),
  price: z.number().min(0).default(0),
  currency: z.string().default('NEON_COIN'),
  isLimited: z.boolean().default(false),
  totalSupply: z.number().int().positive().optional(),
});

export async function virtualItemsRoutes(fastify: FastifyInstance): Promise<void> {
  /** GET /v1/virtual-items — List all items (store catalog) */
  fastify.get('/', async (request, reply) => {
    const query = request.query as { itemType?: string; rarity?: string; limit?: string; offset?: string };
    const limit = parseInt(query.limit ?? '20', 10);
    const offset = parseInt(query.offset ?? '0', 10);

    const [items, total] = await Promise.all([
      prisma.virtualItem.findMany({
        where: {
          ...(query.itemType ? { itemType: query.itemType as never } : {}),
          ...(query.rarity ? { rarity: query.rarity as never } : {}),
        },
        take: limit,
        skip: offset,
        orderBy: { rarity: 'asc' },
      }),
      prisma.virtualItem.count(),
    ]);
    return reply.send({ items, total, limit, offset });
  });

  /** GET /v1/virtual-items/me/inventory — Get own inventory */
  fastify.get('/me/inventory', { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const inventory = await prisma.userVirtualItem.findMany({
      where: { userId: request.user!.id },
      include: { item: true },
      orderBy: { acquiredAt: 'desc' },
    });
    return reply.send({ inventory });
  });

  /** GET /v1/virtual-items/:id — Get a specific item */
  fastify.get('/:id', async (request: FastifyRequest<{ Params: { id: string } }>, reply: FastifyReply) => {
    const item = await prisma.virtualItem.findUnique({ where: { id: request.params.id } });
    if (!item) return reply.code(404).send({ error: 'Virtual item not found' });
    return reply.send({ item });
  });

  /** POST /v1/virtual-items — Create a virtual item (admin) */
  fastify.post('/', { preHandler: [fastify.authenticate] }, async (request, reply) => {
    const parsed = CreateItemSchema.safeParse(request.body);
    if (!parsed.success) return reply.code(400).send({ error: parsed.error.flatten() });

    const item = await prisma.virtualItem.create({ data: parsed.data });
    logger.info({ itemId: item.id }, 'VirtualItem created');
    return reply.code(201).send({ item });
  });

  /** POST /v1/virtual-items/:id/acquire — Add item to own inventory */
  fastify.post('/:id/acquire', { preHandler: [fastify.authenticate] }, async (request, reply: FastifyReply) => {
    const { id } = request.params as { id: string };
    const item = await prisma.virtualItem.findUnique({ where: { id } });
    if (!item) return reply.code(404).send({ error: 'Virtual item not found' });

    const entry = await prisma.userVirtualItem.upsert({
      where: { userId_itemId: { userId: request.user!.id, itemId: item.id } },
      create: { userId: request.user!.id, itemId: item.id },
      update: {},
      include: { item: true },
    });
    return reply.send({ entry });
  });
}
