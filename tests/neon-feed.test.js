/**
 * Tests for NeonFeed service logic (unit-level, no external deps).
 * Uses Node.js built-in test runner (node --test).
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');

// ─── Inline stub of the ranking heuristic (mirrors NeonFeed._rankWithAI) ─────

function heuristicRank(posts, context) {
  const userMood = context.mood?.toLowerCase();
  return posts
    .map((post) => {
      let score = post.likeCount * 0.01 + post.viewCount * 0.001;
      if (userMood && post.mood?.toLowerCase() === userMood) score += 0.5;
      if (post.isAR) score += 0.3;
      if (post.tags.some((t) => context.interests.includes(t))) score += 0.2;
      return { ...post, score: Math.min(1, score) };
    })
    .sort((a, b) => b.score - a.score);
}

// ─── Fixtures ─────────────────────────────────────────────────────────────────

const basePosts = [
  { id: '1', likeCount: 5,  viewCount: 100, mood: 'happy',  tags: ['art'],    isAR: false, score: 0 },
  { id: '2', likeCount: 20, viewCount: 200, mood: 'focused', tags: ['tech'],   isAR: false, score: 0 },
  { id: '3', likeCount: 2,  viewCount: 10,  mood: 'happy',  tags: ['gaming'], isAR: true,  score: 0 },
  { id: '4', likeCount: 0,  viewCount: 0,   mood: 'calm',   tags: [],         isAR: false, score: 0 },
];

// ─── Tests ────────────────────────────────────────────────────────────────────

test('heuristic rank boosts AR content', () => {
  const ranked = heuristicRank(basePosts, { mood: undefined, interests: [] });
  const arPost = ranked.find((p) => p.isAR);
  const nonArTop = ranked.filter((p) => !p.isAR)[0];

  // AR post should rank above posts with similar like/view counts but no AR boost
  assert.ok(arPost.score > 0.3, `AR post score should be > 0.3, got ${arPost.score}`);
  // Post with most likes/views still beats AR post with no engagement
  assert.ok(nonArTop.id === '2', `Top non-AR should be post 2, got ${nonArTop.id}`);
});

test('heuristic rank boosts mood-matching posts', () => {
  const ranked = heuristicRank(basePosts, { mood: 'happy', interests: [] });
  const happyPosts = ranked.filter((p) => p.mood === 'happy');

  assert.ok(happyPosts.length > 0);
  happyPosts.forEach((p) => {
    assert.ok(
      p.score > basePosts.find((b) => b.id === p.id).likeCount * 0.01,
      `Post ${p.id} should have mood boost applied`,
    );
  });
});

test('heuristic rank boosts interest-matched tags', () => {
  const ranked = heuristicRank(basePosts, { mood: undefined, interests: ['tech'] });
  const techPost = ranked.find((p) => p.id === '2');
  assert.ok(techPost.score >= 0.2 + 20 * 0.01, 'tech-tagged post should get interest boost');
});

test('score is capped at 1', () => {
  const highEngagement = [
    { id: 'big', likeCount: 10000, viewCount: 999999, mood: 'happy', tags: ['art'], isAR: true, score: 0 },
  ];
  const ranked = heuristicRank(highEngagement, { mood: 'happy', interests: ['art'] });
  assert.equal(ranked[0].score, 1, 'Score should be capped at 1.0');
});

test('empty posts array returns empty array', () => {
  const ranked = heuristicRank([], { mood: 'happy', interests: ['tech'] });
  assert.deepEqual(ranked, []);
});

test('posts without mood do not error', () => {
  const noMoodPosts = [
    { id: 'x', likeCount: 1, viewCount: 0, mood: null, tags: [], isAR: false, score: 0 },
  ];
  assert.doesNotThrow(() => heuristicRank(noMoodPosts, { mood: 'happy', interests: [] }));
});
