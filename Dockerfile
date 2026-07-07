# syntax=docker/dockerfile:1
#
# OpenHost packaging of Spliit (https://github.com/spliit-app/spliit).
#
# Everything runs in a single container:
#   - PostgreSQL (bundled, data on the OpenHost persistent volume)
#   - The Spliit Next.js app (standalone output)
#   - A tiny Python auth-proxy that terminates OpenHost SSO / owner-gating
#     and forwards to Next.js on loopback.
#
# ---------------------------------------------------------------------------
# Stage 1: build the Next.js standalone bundle
# ---------------------------------------------------------------------------
FROM node:22-alpine AS build

WORKDIR /usr/app

# Install only what's needed to resolve the dependency graph first so Docker
# can cache the (slow) npm install layer independently of source changes.
COPY package.json package-lock.json ./
COPY prisma ./prisma
RUN apk add --no-cache openssl \
    && npm ci --ignore-scripts \
    && npx prisma generate

# Copy the rest of the source and build.
COPY . .

ENV NEXT_TELEMETRY_DISABLED=1
# Build-time env. These values are only used to satisfy `env.ts` validation
# during `next build`; the real connection string is injected at runtime.
COPY scripts/build.env .env
RUN npm run build \
    && rm -rf .next/cache

# ---------------------------------------------------------------------------
# Stage 2: runtime image
# ---------------------------------------------------------------------------
FROM node:22-alpine AS runtime

# System deps:
#   postgresql* : bundled database
#   python3     : auth-proxy sidecar
#   openssl     : prisma engine runtime dep
#   su-exec     : drop privileges (alpine's gosu equivalent)
#   tini        : reap zombies for the long-lived supervisor
RUN apk add --no-cache \
        postgresql16 \
        postgresql16-contrib \
        python3 \
        openssl \
        su-exec \
        tini \
        bash \
        curl

WORKDIR /usr/app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Next standalone output: the server + a minimal node_modules is emitted to
# .next/standalone; static assets live in .next/static and public/.
COPY --from=build /usr/app/.next/standalone ./
COPY --from=build /usr/app/.next/static ./.next/static
COPY --from=build /usr/app/public ./public

# Prisma: the generated client + the migration files + the CLI are needed at
# runtime so start.sh can run `prisma migrate deploy` against the bundled DB.
COPY --from=build /usr/app/node_modules/.prisma ./node_modules/.prisma
COPY --from=build /usr/app/node_modules/@prisma ./node_modules/@prisma
COPY --from=build /usr/app/node_modules/prisma ./node_modules/prisma
COPY --from=build /usr/app/prisma ./prisma
COPY --from=build /usr/app/package.json ./package.json

# OpenHost integration layer.
COPY openhost/auth_proxy.py /usr/app/openhost/auth_proxy.py
COPY openhost/start.sh /usr/app/openhost/start.sh
RUN chmod 0755 /usr/app/openhost/start.sh /usr/app/openhost/auth_proxy.py

EXPOSE 8080/tcp

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/app/openhost/start.sh"]
