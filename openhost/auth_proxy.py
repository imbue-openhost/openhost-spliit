#!/usr/bin/env python3
"""OpenHost auth-proxy / front door for Spliit.

Spliit has no user accounts of its own: a group is reached purely by its
(unguessable, nanoid) URL, and "who am I" is a client-side localStorage
value. That means there is no login form to auto-fill and no session table
to seed -- the OpenHost SSO story here is simply:

  * The OpenHost router gates the app domain behind zone_auth for everything
    that is NOT listed in `routing.public_paths`. The owner, once through
    zone_auth, reaches the app directly.
  * Group share-links (`/groups/<id>...`) and the API/asset paths they need
    are declared public so the owner can share a group with friends who do
    not have an OpenHost account -- exactly matching upstream Spliit's
    link-sharing model.

This proxy therefore does NOT mint cookies or gate requests itself. Its jobs
are purely transport-level and required for Next.js to work correctly behind
the OpenHost router:

  1. Serve `/_healthz` with a static 200 so OpenHost's health check passes
     during (and after) cold start.
  2. Rewrite the upstream `Host` header from `X-Forwarded-Host` so Next.js
     generates correct absolute URLs and its Server Action CSRF check sees a
     consistent host.
  3. Keep the `Origin` header and `X-Forwarded-Host` consistent so Next.js
     Server Action mutations are accepted (see next.config.mjs for the
     matching allow-list rationale).
  4. Force `X-Forwarded-Proto: https` so Next.js treats the connection as
     secure (required for its forwarded-host handling).

It is a thin, streaming HTTP/1.1 proxy -- no buffering of large bodies, no
persistence, nothing written to disk.
"""

from __future__ import annotations

import http.client
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM_HOST = os.environ.get("UPSTREAM_HOST", "127.0.0.1")
UPSTREAM_PORT = int(os.environ.get("UPSTREAM_PORT", "3000"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
HEALTH_PATH = "/_healthz"
ZONE_DOMAIN = os.environ.get("OPENHOST_ZONE_DOMAIN", "")

# The OpenHost router stamps this header on every request from the
# zone_auth'd owner (even on public paths). Absence of it => anonymous
# visitor who reached us via a public_paths entry.
OWNER_HEADER = "X-OpenHost-Is-Owner"

# Owner-only paths that must be gated even though they sit *under* a public
# prefix in openhost.toml. The router's public-path matching is
# prefix-based, so "/groups/" (needed for shared group links like
# /groups/<id>) unavoidably also matches the fixed "/groups/create" page.
# We re-gate those fixed sub-paths here: an anonymous visitor gets bounced
# to the OpenHost login instead of the create UI. Shared group links
# (/groups/<nanoid>...) stay public.
#
# Matching is exact or exact-prefix ("/groups/create" and
# "/groups/create/..."), so a group whose id happened to start with
# "create" is not affected (nanoid ids never equal these fixed segments).
OWNER_ONLY_EXACT = {"/groups", "/groups/create"}
OWNER_ONLY_PREFIXES = ("/groups/create/",)

# Hop-by-hop headers must not be forwarded (RFC 7230 6.1).
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def _log(msg: str) -> None:
    sys.stderr.write(f"[auth_proxy] {msg}\n")
    sys.stderr.flush()


class ProxyHandler(BaseHTTPRequestHandler):
    # Use HTTP/1.0 semantics (connection closed after each response) so we
    # never have to reconcile the upstream framing (chunked vs
    # content-length) with keep-alive. The OpenHost router in front of us
    # pools its own upstream connections, so per-request connections here
    # are not a throughput concern.
    protocol_version = "HTTP/1.1"

    # Keep logging quiet; the container captures stderr from _log only.
    def log_message(self, *_args) -> None:  # noqa: D401
        return

    # -- request entry points -------------------------------------------
    def do_GET(self) -> None:
        self._handle()

    def do_POST(self) -> None:
        self._handle()

    def do_PUT(self) -> None:
        self._handle()

    def do_PATCH(self) -> None:
        self._handle()

    def do_DELETE(self) -> None:
        self._handle()

    def do_HEAD(self) -> None:
        self._handle()

    def do_OPTIONS(self) -> None:
        self._handle()

    # -- core -----------------------------------------------------------
    def _handle(self) -> None:
        if self.path == HEALTH_PATH:
            self._serve_health()
            return
        if self._is_owner_only_path() and not self._is_owner():
            self._bounce_to_login()
            return
        try:
            self._proxy()
        except (BrokenPipeError, ConnectionResetError):
            # Client hung up mid-stream; nothing to do.
            pass
        except Exception as exc:  # pragma: no cover - defensive
            _log(f"proxy error: {exc!r}")
            try:
                self.send_error(502, "Bad Gateway")
            except Exception:
                pass

    def _serve_health(self) -> None:
        body = b"ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _path_only(self) -> str:
        # Strip query string for path matching.
        return self.path.split("?", 1)[0]

    def _is_owner(self) -> bool:
        return (self.headers.get(OWNER_HEADER, "").lower() == "true")

    def _is_owner_only_path(self) -> bool:
        p = self._path_only()
        if p in OWNER_ONLY_EXACT:
            return True
        return any(p.startswith(prefix) for prefix in OWNER_ONLY_PREFIXES)

    def _bounce_to_login(self) -> None:
        """Redirect an anonymous visitor on an owner-only path to OpenHost
        login. Uses the zone login the router itself would use."""
        forwarded_host = self.headers.get("X-Forwarded-Host") or self.headers.get(
            "Host", ""
        )
        if ZONE_DOMAIN:
            target = f"https://{ZONE_DOMAIN}/login"
        elif forwarded_host:
            target = f"https://{forwarded_host}/login"
        else:
            target = "/login"
        body = b""
        self.send_response(302)
        self.send_header("Location", target)
        self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _rewritten_headers(self) -> tuple[list[tuple[str, str]], str | None]:
        """Return (headers_to_forward, forwarded_host)."""
        forwarded_host = self.headers.get("X-Forwarded-Host") or self.headers.get(
            "Host"
        )

        out: list[tuple[str, str]] = []
        seen_lower = set()
        for key, value in self.headers.items():
            lk = key.lower()
            if lk in HOP_BY_HOP:
                continue
            if lk == "host":
                # Rewrite below.
                continue
            if lk == "origin":
                # Rewrite below to stay consistent with the forwarded host.
                continue
            if lk == "x-forwarded-proto":
                continue
            out.append((key, value))
            seen_lower.add(lk)

        if forwarded_host:
            # Next.js compares Origin host to X-Forwarded-Host/Host for its
            # Server Action CSRF check. Force all three to agree.
            out.append(("Host", forwarded_host))
            if "x-forwarded-host" not in seen_lower:
                out.append(("X-Forwarded-Host", forwarded_host))
            # Only send an Origin on requests that originally had one
            # (i.e. actual browser cross-fetches / actions). Preserving the
            # scheme+host keeps it same-origin from Next's perspective.
            if self.headers.get("Origin") is not None:
                out.append(("Origin", f"https://{forwarded_host}"))

        out.append(("X-Forwarded-Proto", "https"))
        return out, forwarded_host

    def _proxy(self) -> None:
        length = self.headers.get("Content-Length")
        body = None
        if length is not None:
            try:
                body = self.rfile.read(int(length))
            except ValueError:
                body = None

        headers, _ = self._rewritten_headers()

        conn = http.client.HTTPConnection(
            UPSTREAM_HOST, UPSTREAM_PORT, timeout=120
        )
        try:
            conn.putrequest(
                self.command, self.path, skip_host=True, skip_accept_encoding=True
            )
            for key, value in headers:
                conn.putheader(key, value)
            conn.endheaders(message_body=body)

            resp = conn.getresponse()

            # http.client has already de-chunked/decoded transfer-encoding, so
            # read the full body and re-frame it ourselves with an explicit
            # Content-Length. Preserving upstream's Transfer-Encoding/
            # Content-Length would mismatch the actual bytes we forward.
            payload = b"" if self.command == "HEAD" else resp.read()

            self.send_response(resp.status, resp.reason)
            for key, value in resp.getheaders():
                lk = key.lower()
                if lk in HOP_BY_HOP:
                    continue
                if lk == "content-length":
                    # Recomputed below.
                    continue
                self.send_header(key, value)
            if self.command != "HEAD":
                self.send_header("Content-Length", str(len(payload)))
            # Close after each response: avoids keep-alive framing edge cases
            # behind the OpenHost router.
            self.send_header("Connection", "close")
            self.close_connection = True
            self.end_headers()

            if self.command != "HEAD" and payload:
                self.wfile.write(payload)
        finally:
            conn.close()


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), ProxyHandler)
    server.daemon_threads = True
    _log(
        f"listening on 0.0.0.0:{LISTEN_PORT} -> "
        f"{UPSTREAM_HOST}:{UPSTREAM_PORT}"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.shutdown()


if __name__ == "__main__":
    main()
