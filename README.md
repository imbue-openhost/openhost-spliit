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
session table to seed, so the OpenHost integration is deliberately simple:

- **The instance owner** reaches the app through OpenHost `zone_auth`. The
  OpenHost router gates everything that is not explicitly listed as public,
  so only the owner can see the app shell, the recently-visited-groups list,
  and the "create group" page.
- **Sharing** works exactly like upstream Spliit: the owner shares a group
  URL, and anyone with that link can open, view, and edit the group without
  an OpenHost account. The group pages and the API / static assets they need
  are declared as `public_paths` in `openhost.toml` so the OpenHost router
  lets those requests through without `zone_auth`.

Because group IDs are unguessable nanoids, "knowing the URL" is the sharing
credential — this matches the public hosted Spliit at spliit.app. If you want
a fully private instance (no anonymous access at all), remove the
`/groups/` and `/api/` entries from `openhost.toml`'s `public_paths`; the
owner will still have full access, but group links will only work for
`zone_auth`'d visitors.

### The auth-proxy

`openhost/auth_proxy.py` is a thin streaming HTTP proxy in front of the
Next.js server. It does **not** mint cookies or gate requests (the OpenHost
router does the gating). Its only jobs are transport-level fixes required
for Next.js behind a reverse proxy:

1. Serve `/_healthz` with a static 200 for the OpenHost health check.
2. Rewrite the upstream `Host` header from `X-Forwarded-Host` and keep the
   `Origin` header consistent so Next.js Server Action mutations are
   accepted (Next rejects forwarded actions whose `Origin` host does not
   match the forwarded host).
3. Force `X-Forwarded-Proto: https`.

No credentials are ever written to disk. The bundled database is loopback-only
and its password never leaves the container.

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
