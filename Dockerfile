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
#   postgresql16 : bundled database (server + client + pg_ctl/pg_isready)
#   python3      : auth-proxy sidecar
#   openssl      : prisma engine runtime dep
#   su-exec      : drop privileges to the postgres user (alpine's gosu)
#   tini         : reap zombies for the long-lived supervisor
#   bash         : start.sh uses the `wait -n` bashism
RUN apk add --no-cache \
        postgresql16 \
        python3 \
        openssl \
        su-exec \
        tini \
        bash

WORKDIR /usr/app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Next standalone output: the server + a minimal node_modules is emitted to
# .next/standalone; static assets live in .next/static and public/.
COPY --from=build /usr/app/.next/standalone ./
COPY --from=build /usr/app/.next/static ./.next/static
COPY --from=build /usr/app/public ./public

# Prisma migrations at runtime.
#
# The Next.js standalone bundle ships a curated, minimal node_modules that is
# enough to *run* the server (it includes the generated @prisma/client), but
# NOT enough to run the Prisma *CLI* (`prisma migrate deploy`), whose deep
# dependency tree (@prisma/config -> effect, c12, ...) is not traced by
# Next's standalone tracer. Rather than cherry-pick that fragile tree, we
# copy the full build-stage node_modules into a dedicated location used
# ONLY by start.sh to apply migrations before the server starts.
COPY --from=build /usr/app/node_modules ./migrate/node_modules
COPY --from=build /usr/app/prisma ./migrate/prisma
COPY --from=build /usr/app/package.json ./migrate/package.json
COPY --from=build /usr/app/prisma ./prisma

# OpenHost integration layer.
COPY openhost/auth_proxy.py /usr/app/openhost/auth_proxy.py
COPY openhost/start.sh /usr/app/openhost/start.sh
RUN chmod 0755 /usr/app/openhost/start.sh /usr/app/openhost/auth_proxy.py

EXPOSE 8080/tcp

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/app/openhost/start.sh"]
