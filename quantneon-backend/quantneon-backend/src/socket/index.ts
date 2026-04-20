/**
 * Quantneon WebSocket Hub (Socket.io)
 *
 * High-speed multiplayer hub for:
 *  - Real-time NeonPost interactions (likes, comments)
 *  - Virtual avatar presence & movement sync
 *  - Live stream viewer/host events
 *  - Virtual lobby interactions
 */

import { Server as HttpServer } from 'http';
import { Server as SocketIOServer, Socket } from 'socket.io';
import { createAdapter } from '@socket.io/redis-adapter';
import { redis } from '../config/redis';
import { logger } from '../utils/logger';
import { env } from '../config/env';
import { verifyQuantmailToken } from '../middleware/auth';
import { prisma } from '../config/database';

export interface SocketUser {
  userId: string;
  username: string;
  socketId: string;
  room?: string;
}

// TODO(launch-blocker): Replace this fallback Map with a Redis-backed presence registry before multi-instance production rollout.
const onlineUsers = new Map<string, SocketUser>();

export function createSocketHub(httpServer: HttpServer): SocketIOServer {
  const io = new SocketIOServer(httpServer, {
    cors: {
      origin: env.CORS_ORIGIN,
      methods: ['GET', 'POST'],
    },
    transports: ['websocket', 'polling'],
    pingInterval: 10_000,
    pingTimeout: 5_000,
  });

  // ── Redis adapter for horizontal scaling ──────────────────────────────────
  const pubClient = redis.duplicate();
  const subClient = redis.duplicate();

  Promise.all([pubClient.connect(), subClient.connect()])
    .then(() => {
      io.adapter(createAdapter(pubClient, subClient));
      logger.info('[Socket] Redis adapter attached');
    })
    .catch((err) => {
      logger.warn({ err }, '[Socket] Redis adapter unavailable — falling back to in-memory');
    });

  // ── Authentication middleware ─────────────────────────────────────────────
  io.use(async (socket, next) => {
    const token = socket.handshake.auth.token as string | undefined;
    if (!token) return next(new Error('Missing auth token'));

    try {
      const payload = verifyQuantmailToken(token);
      const user = await prisma.user.findUnique({ where: { quantmailId: payload.sub } });
      if (!user) return next(new Error('User not registered on Quantneon'));
      if (user.isBanned) return next(new Error('Account suspended'));

      (socket as Socket & { quantneonUser?: SocketUser }).quantneonUser = {
        userId: user.id,
        username: user.username,
        socketId: socket.id,
      };
      next();
    } catch (err) {
      next(new Error('Invalid token'));
    }
  });

  // ── Connection handler ────────────────────────────────────────────────────
  io.on('connection', (socket) => {
    const socketUser = (socket as Socket & { quantneonUser?: SocketUser }).quantneonUser!;
    onlineUsers.set(socketUser.userId, { ...socketUser, socketId: socket.id });

    logger.info({ userId: socketUser.userId }, '[Socket] User connected');

    // Broadcast presence
    socket.broadcast.emit('user:online', {
      userId: socketUser.userId,
      username: socketUser.username,
    });

    // ── Room / Lobby events ──────────────────────────────────────────────
    socket.on('lobby:join', (data: { roomId: string }) => {
      socket.join(`lobby:${data.roomId}`);
      socketUser.room = data.roomId;
      logger.debug({ userId: socketUser.userId, roomId: data.roomId }, '[Socket] Joined lobby');
      socket.to(`lobby:${data.roomId}`).emit('lobby:user_joined', {
        userId: socketUser.userId,
        username: socketUser.username,
      });
    });

    socket.on('lobby:leave', (data: { roomId: string }) => {
      socket.leave(`lobby:${data.roomId}`);
      socket.to(`lobby:${data.roomId}`).emit('lobby:user_left', {
        userId: socketUser.userId,
      });
    });

    // ── Avatar movement sync ─────────────────────────────────────────────
    socket.on(
      'avatar:move',
      (data: { roomId: string; x: number; y: number; z: number; r: number }) => {
        socket.to(`lobby:${data.roomId}`).emit('avatar:moved', {
          userId: socketUser.userId,
          ...data,
        });
      },
    );

    socket.on('avatar:emote', (data: { roomId: string; emote: string }) => {
      io.to(`lobby:${data.roomId}`).emit('avatar:emoted', {
        userId: socketUser.userId,
        emote: data.emote,
      });
    });

    // ── Live stream events ───────────────────────────────────────────────
    socket.on('stream:join', async (data: { streamId: string }) => {
      socket.join(`stream:${data.streamId}`);
      await prisma.liveStream
        .update({
          where: { id: data.streamId },
          data: { viewerCount: { increment: 1 } },
        })
        .catch(() => {});

      io.to(`stream:${data.streamId}`).emit('stream:viewer_joined', {
        userId: socketUser.userId,
        username: socketUser.username,
      });
    });

    socket.on('stream:leave', async (data: { streamId: string }) => {
      socket.leave(`stream:${data.streamId}`);
      await prisma.liveStream
        .update({
          where: { id: data.streamId },
          data: { viewerCount: { decrement: 1 } },
        })
        .catch(() => {});
    });

    socket.on('stream:reaction', (data: { streamId: string; emoji: string }) => {
      io.to(`stream:${data.streamId}`).emit('stream:reaction', {
        userId: socketUser.userId,
        emoji: data.emoji,
      });
    });

    // ── NeonPost real-time interactions ──────────────────────────────────
    socket.on('post:like', (data: { postId: string }) => {
      socket.broadcast.emit('post:liked', {
        postId: data.postId,
        userId: socketUser.userId,
      });
    });

    // ── Disconnect ───────────────────────────────────────────────────────
    socket.on('disconnect', () => {
      onlineUsers.delete(socketUser.userId);

      // Notify room members if user was in a lobby
      if (socketUser.room) {
        socket.to(`lobby:${socketUser.room}`).emit('lobby:user_left', {
          userId: socketUser.userId,
        });
      }

      logger.info({ userId: socketUser.userId }, '[Socket] User disconnected');
      socket.broadcast.emit('user:offline', { userId: socketUser.userId });
    });
  });

  logger.info('[Socket] WebSocket hub initialised');
  return io;
}

export { onlineUsers };
