/**
 * NeonFeed Service
 *
 * Hyper-personalized AI feed for Quantneon.
 *
 * This service produces a ranked, gamified social content feed tailored to
 * the current user's mood, activity signals from across the Quant ecosystem
 * (Quantmail, Quantchat, Quanttube, etc.), and their social graph.
 *
 * The AI ranking pipeline is a stub that can be wired to any provider:
 *   • Gemini Flash (default) via GEMINI_API_KEY
 *   • OpenAI GPT-4o via OPENAI_API_KEY
 *   • A local model endpoint
 *
 * Current implementation: returns chronologically-ordered posts with bonus
 * score boosts applied for mood / tag relevance.  Replace `_rankWithAI` with
 * a real inference call to enable full personalisation.
 */

import { prisma } from '../config/database';
import { redis } from '../config/redis';
import { logger } from '../utils/logger';
import { env } from '../config/env';

export interface FeedPost {
  id: string;
  authorId: string;
  author: { username: string; displayName: string; avatarUrl: string | null };
  caption: string | null;
  mediaUrl: string | null;
  mediaType: string;
  mood: string | null;
  tags: string[];
  likeCount: number;
  viewCount: number;
  isAR: boolean;
  arAnchorUrl: string | null;
  createdAt: Date;
  /** AI-computed relevance score (0–1) */
  score: number;
}

export interface FeedResult {
  posts: FeedPost[];
  total: number;
  limit: number;
  offset: number;
  personalized: boolean;
}

type NeonFeedSourcePost = Omit<FeedPost, 'score'>;

/** Multiplier applied to `limit` when fetching posts for AI reranking headroom. */
const RANKING_HEADROOM_MULTIPLIER = 3;

async function _getUserContext(userId: string): Promise<{ mood?: string; interests: string[] }> {
  // Fetch stored mood and inferred interests from the user record
  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: { mood: true },
  });
  return { mood: user?.mood ?? undefined, interests: [] };
}

/**
 * AI ranking stub.
 *
 * Wire this to a real LLM call (Gemini / OpenAI) to score posts against the
 * user context and return ranked results.  The stub applies a lightweight
 * heuristic so the feed already feels somewhat personalised without an API key.
 */
async function _rankWithAI(
  posts: FeedPost[],
  context: { mood?: string; interests: string[] },
): Promise<FeedPost[]> {
  if (env.GEMINI_API_KEY || env.OPENAI_API_KEY) {
    logger.info({ provider: env.AI_PROVIDER }, '[NeonFeed] AI ranking enabled (stub — implement inference call)');
    // TODO: build prompt → call inference API → re-order posts by returned scores
  }

  // Heuristic fallback: boost posts whose mood/tags match the user context
  const userMood = context.mood?.toLowerCase();
  return posts
    .map((post) => {
      let score = post.likeCount * 0.01 + post.viewCount * 0.001;
      if (userMood && post.mood?.toLowerCase() === userMood) score += 0.5;
      if (post.isAR) score += 0.3; // Boost AR/hologram content
      if (post.tags.some((t) => context.interests.includes(t))) score += 0.2;
      return { ...post, score: Math.min(1, score) };
    })
    .sort((a, b) => b.score - a.score);
}

// ─── Public API ───────────────────────────────────────────────────────────────

export const NeonFeedService = {
  /**
   * Returns a personalized NeonPost feed for the given user.
   *
   * Results are cached in Redis for 60 s per user to reduce DB load.
   */
  async getPersonalizedFeed(userId: string, limit = 20, offset = 0): Promise<FeedResult> {
    const cacheKey = `neon:feed:${userId}:${limit}:${offset}`;

    try {
      const cached = await redis.get(cacheKey);
      if (cached) {
        logger.debug({ userId, cacheKey }, '[NeonFeed] Cache hit');
        return JSON.parse(cached) as FeedResult;
      }
    } catch {
      // Redis unavailable — proceed without cache
    }

    const [rawPosts, total]: [NeonFeedSourcePost[], number] = await Promise.all([
      prisma.neonPost.findMany({
        take: limit * RANKING_HEADROOM_MULTIPLIER, // Fetch 3× for AI reranking headroom
        skip: offset,
        include: {
          author: { select: { username: true, displayName: true, avatarUrl: true } },
        },
        orderBy: { createdAt: 'desc' },
      }),
      prisma.neonPost.count(),
    ]);

    const posts = rawPosts.map((post): FeedPost => ({ ...post, score: 0 }));
    const context = await _getUserContext(userId);
    const ranked = await _rankWithAI(posts, context);
    const page = ranked.slice(0, limit);

    const result: FeedResult = { posts: page, total, limit, offset, personalized: true };

    try {
      await redis.set(cacheKey, JSON.stringify(result), 'EX', 60);
    } catch {
      // Redis unavailable — non-fatal
    }

    logger.info({ userId, count: page.length }, '[NeonFeed] Feed generated');
    return result;
  },

  /**
   * Invalidates the cached feed for a user.  Call after a new post is created
   * or after the user's mood changes.
   */
  async invalidateCache(userId: string): Promise<void> {
    try {
      // Use SCAN instead of KEYS to avoid blocking Redis
      const pattern = `neon:feed:${userId}:*`;
      const keysToDelete: string[] = [];
      let cursor = '0';

      do {
        const [newCursor, keys] = await redis.scan(cursor, 'MATCH', pattern, 'COUNT', 100);
        cursor = newCursor;
        keysToDelete.push(...keys);
      } while (cursor !== '0');

      if (keysToDelete.length > 0) {
        await redis.del(...keysToDelete);
        logger.debug({ userId, count: keysToDelete.length }, '[NeonFeed] Cache invalidated');
      }
    } catch (err) {
      logger.warn({ err, userId }, '[NeonFeed] Cache invalidation failed');
    }
  },
};
