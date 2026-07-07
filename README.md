# openhost-spliit

[Spliit](https://github.com/spliit-app/spliit) — a minimalist, account-free
app for sharing expenses with friends and family — packaged as a single,
self-contained [OpenHost](https://openhost.ai) application.

This repo vendors the upstream Spliit source (MIT-licensed) and adds an
OpenHost integration layer: a bundled PostgreSQL database, a supervisor
script, and a small auth-proxy that terminates OpenHost SSO / owner-gating.

## What you get

- The full Spliit UI: create groups, add participants, log expenses
  (even split, by shares, by percentage, by amount), reimbursements,
  recurring expenses, balances, "who owes whom" suggested reimbursements,
  activity log, stats, per-group settings, and CSV / JSON export.
- A bundled PostgreSQL 16 database. Nothing external to provision — all
  data lives on the OpenHost persistent volume.
- OpenHost single-sign-on for the instance owner and public, no-login
  sharing of individual groups by link.

## Auth model

Spliit intentionally has **no user accounts**. A group is reached purely by
its unguessable URL (`/groups/<nanoid>...`), and "which participant am I"
is a browser-local setting. There is no login form to auto-fill and no
session table to seed. The OpenHost integration therefore combines two
gating layers:

- **The instance owner** reaches the app through OpenHost `zone_auth`. The
  OpenHost router gates everything that is not listed in
  `openhost.toml`'s `public_paths`, so the app shell and the
  recently-visited-groups list are owner-only.
- **Sharing** works exactly like upstream Spliit: the owner shares a group
  URL, and anyone with that link can open, view, and edit the group without
  an OpenHost account. The group pages and the API / static assets they need
  are declared as `public_paths` so the OpenHost router lets those requests
  through without `zone_auth`.
- **Owner-only actions under public prefixes** are re-gated by the
  auth-proxy (see below). The router's `public_paths` matching is
  prefix-based, so `/groups/` (needed for shared links) also matches the
  `/groups/create` page and `/api/` (needed by the group pages' tRPC data
  calls) also matches the privileged `groups.create` mutation and the S3
  upload handler. The proxy blocks those for anonymous visitors while
  leaving everything else public.

Because group IDs are unguessable nanoids, "knowing the URL" is the sharing
credential — this matches the public hosted Spliit at spliit.app. If you want
a fully private instance (no anonymous access at all), remove the
`/groups/` and `/api/` entries from `openhost.toml`'s `public_paths`; the
owner will still have full access, but group links will only work for
`zone_auth`'d visitors.

### The auth-proxy

`openhost/auth_proxy.py` is a small HTTP proxy in front of the Next.js
server with two jobs:

**Transport-level fixes** required for Next.js behind a reverse proxy:

1. Serve `/_healthz` with a static 200 for the OpenHost health check.
2. Rewrite the upstream `Host` header from `X-Forwarded-Host` and rewrite
   `Origin` to match, so Next.js Server Action mutations are accepted (Next
   rejects forwarded actions whose `Origin` host does not match the
   forwarded host). This is why `next.config.mjs` needs no wildcard origin
   allow-list.
3. Force `X-Forwarded-Proto: https`.

**Owner-only gating** for the privileged operations that sit under a public
prefix and so cannot be gated by the router alone. The OpenHost router
stamps `X-OpenHost-Is-Owner: true` on requests from the zone_auth'd owner;
when that header is absent the proxy refuses these paths (a 302 to the
OpenHost login for page navigations, a 403 for API/tRPC calls):

- `GET /groups/create` (the create-group page)
- the `groups.create` tRPC mutation (`POST /api/trpc/groups.create...`)
- `/api/s3-upload` (the presigned-upload handler)

Everything else under `/groups/` and `/api/` stays public so link-shared
groups keep working — including anonymous friends adding and editing
expenses on a shared group.

No credentials are ever written to a file readable by other apps. The
bundled database is loopback-only, and its password is a random value
generated on first boot and stored (mode 0600) inside the Postgres data
directory it protects — it is never derived from an OpenHost platform token
and never leaves the container.

## Layout

```
Dockerfile            multi-stage build: Next standalone + bundled Postgres
openhost.toml         OpenHost manifest (routing, resources, public paths)
openhost/start.sh     supervisor: Postgres -> migrations -> Next -> proxy
openhost/auth_proxy.py  SSO/front-door proxy (see above)
src/, prisma/, ...    vendored upstream Spliit source (MIT)
```

## Local development

The upstream project's own tooling still works (`npm run dev`, `npm test`).
To exercise the exact production stack the OpenHost container runs, build the
image and run it with an `OPENHOST_APP_DATA_DIR` bind mount; the container
brings up Postgres, applies migrations, and serves the app on port 8080.

## Credits

Spliit is created by [Sebastien Castiel](https://github.com/scastiel) and
contributors, and is MIT-licensed (see `LICENSE`). This repo only adds the
OpenHost packaging layer.
