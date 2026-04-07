import { authenticate, AuthenticatedUser } from '../middleware/auth';

declare module 'fastify' {
  interface FastifyInstance {
    authenticate: typeof authenticate;
  }
  interface FastifyRequest {
    user?: AuthenticatedUser;
  }
}
