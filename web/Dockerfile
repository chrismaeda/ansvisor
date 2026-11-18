FROM node:20-alpine AS base

ARG VERSION=0.1.0
LABEL org.opencontainers.image.title="Ansvisor Web"
LABEL org.opencontainers.image.version=$VERSION
LABEL org.opencontainers.image.source="https://github.com/ansvisor/ansvisor"
LABEL org.opencontainers.image.licenses="MIT"

# Install dependencies
FROM base AS deps
WORKDIR /app
COPY package.json yarn.lock* package-lock.json* ./
RUN if [ -f yarn.lock ]; then yarn install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then npm ci; \
    else npm install; fi

# Build
FROM base AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
# NEXT_PUBLIC_* values are inlined into the bundle at build time. They come
# from .env.build (public values only; every other .env* file is kept out by
# .dockerignore), which Next reads as .env.production.
RUN if [ -f .env.build ]; then cp .env.build .env.production; fi
# `next build` evaluates route modules, and src/lib/supabase/admin.ts and
# src/lib/stripe.ts create their clients at import time, which throws on an
# empty key. Placeholders scoped to this one command satisfy them; server-only
# vars aren't inlined, so the real keys are read from the runtime env (web.env)
# and none is baked in.
RUN SUPABASE_SERVICE_ROLE_KEY=build-time-placeholder \
    STRIPE_SECRET_KEY=build-time-placeholder \
    npm run build

# Production
FROM base AS runner
WORKDIR /app
ENV NODE_ENV=production

RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000
ENV PORT=3000

CMD ["node", "server.js"]
