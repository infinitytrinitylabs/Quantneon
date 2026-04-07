import 'dotenv/config';

function requireEnv(key: string, fallback?: string): string {
  const value = process.env[key] ?? fallback;
  if (!value) {
    throw new Error(`Missing required environment variable: ${key}`);
  }
  return value;
}

export const env = {
  NODE_ENV: process.env.NODE_ENV ?? 'development',
  PORT: parseInt(process.env.PORT ?? '3000', 10),

  DATABASE_URL: requireEnv('DATABASE_URL', 'postgresql://quantneon:password@localhost:5432/quantneon'),

  REDIS_HOST: process.env.REDIS_HOST ?? 'localhost',
  REDIS_PORT: parseInt(process.env.REDIS_PORT ?? '6379', 10),
  REDIS_PASSWORD: process.env.REDIS_PASSWORD,

  // JWT secrets for Quantneon's own tokens
  JWT_SECRET: requireEnv('JWT_SECRET', 'dev-jwt-secret-min-32-characters-long'),
  JWT_EXPIRY: process.env.JWT_EXPIRY ?? '7d',

  // Quantmail SSO — public key or shared secret to verify inbound JWTs
  QUANTMAIL_JWT_SECRET: process.env.QUANTMAIL_JWT_SECRET ?? process.env.JWT_SECRET ?? 'dev-jwt-secret-min-32-characters-long',
  QUANTMAIL_ISSUER: process.env.QUANTMAIL_ISSUER ?? 'quantmail',

  CORS_ORIGIN: process.env.CORS_ORIGIN ?? '*',

  // AWS S3
  S3_BUCKET: process.env.S3_BUCKET ?? 'quantneon-uploads',
  S3_REGION: process.env.S3_REGION ?? 'us-east-1',
  S3_ENDPOINT: process.env.S3_ENDPOINT,
  S3_ACCESS_KEY_ID: process.env.S3_ACCESS_KEY_ID,
  S3_SECRET_ACCESS_KEY: process.env.S3_SECRET_ACCESS_KEY,

  // AI providers for NeonFeed
  AI_PROVIDER: process.env.AI_PROVIDER ?? 'gemini',
  GEMINI_API_KEY: process.env.GEMINI_API_KEY,
  OPENAI_API_KEY: process.env.OPENAI_API_KEY,

  // Rate limiting
  RATE_LIMIT_WINDOW_MS: parseInt(process.env.RATE_LIMIT_WINDOW_MS ?? '60000', 10),
  RATE_LIMIT_MAX: parseInt(process.env.RATE_LIMIT_MAX ?? '100', 10),
};
