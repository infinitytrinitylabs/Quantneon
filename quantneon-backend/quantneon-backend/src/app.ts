import 'dotenv/config';
import './types/index';
import Fastify, { FastifyError } from 'fastify';
import cors from '@fastify/cors';
import helmet from '@fastify/helmet';
import rateLimit from '@fastify/rate-limit';
import { createServer } from 'http';
import { env } from './config/env';
import { redis } from './config/redis';
import { logger } from './utils/logger';
import { authenticate } from './middleware/auth';
import { authRoutes } from './modules/auth/auth.routes';
import { avatarsRoutes } from './modules/avatars/avatars.routes';
import { streamsRoutes } from './modules/streams/streams.routes';
import { postsRoutes } from './modules/posts/posts.routes';
import { virtualItemsRoutes } from './modules/virtual-items/virtual-items.routes';
import { createSocketHub } from './socket/index';

async function buildApp() {
  const fastify = Fastify({
    logger: false, // We use pino directly
    trustProxy: true,
  });

  // ── Decorate with authenticate hook ───────────────────────────────────────
  fastify.decorate('authenticate', authenticate);

  // ── Plugins ───────────────────────────────────────────────────────────────
  await fastify.register(cors, {
    origin: env.CORS_ORIGIN,
    credentials: true,
  });

  await fastify.register(helmet, {
    contentSecurityPolicy: false, // Allow Godot WebGL exports
  });

  await fastify.register(rateLimit, {
    max: env.RATE_LIMIT_MAX,
    timeWindow: env.RATE_LIMIT_WINDOW_MS,
    redis,
  });

  // ── Routes ────────────────────────────────────────────────────────────────
  await fastify.register(authRoutes, { prefix: '/v1/auth' });
  await fastify.register(avatarsRoutes, { prefix: '/v1/avatars' });
  await fastify.register(streamsRoutes, { prefix: '/v1/streams' });
  await fastify.register(postsRoutes, { prefix: '/v1/posts' });
  await fastify.register(virtualItemsRoutes, { prefix: '/v1/virtual-items' });

  // ── Health check ──────────────────────────────────────────────────────────
  fastify.get('/health', async () => ({
    status: 'ok',
    service: 'quantneon-backend',
    timestamp: new Date().toISOString(),
  }));

  // ── Global error handler ──────────────────────────────────────────────────
  fastify.setErrorHandler((error: FastifyError, _request, reply) => {
    logger.error({ err: error }, 'Unhandled error');
    reply.code(error.statusCode ?? 500).send({
      error: error.message ?? 'Internal Server Error',
    });
  });

  return fastify;
}

async function start() {
  try {
    const fastify = await buildApp();

    // ── HTTP + Socket.io ───────────────────────────────────────────────────
    const httpServer = createServer(fastify.server);
    createSocketHub(httpServer);

    // ── Redis ──────────────────────────────────────────────────────────────
    try {
      await redis.connect();
    } catch (err) {
      logger.warn({ err }, 'Redis unavailable — starting without cache/pub-sub');
    }

    // ── Start listening ────────────────────────────────────────────────────
    await fastify.ready();
    httpServer.listen({ port: env.PORT, host: '0.0.0.0' }, () => {
      logger.info(`Quantneon backend listening on port ${env.PORT}`);
    });
  } catch (err) {
    logger.fatal({ err }, 'Failed to start server');
    process.exit(1);
  }
}

start();
