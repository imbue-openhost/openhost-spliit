import createNextIntlPlugin from 'next-intl/plugin'

const withNextIntl = createNextIntlPlugin()

/**
 * Undefined entries are not supported. Push optional patterns to this array only if defined.
 * @type {import('next/dist/shared/lib/image-config').RemotePattern}
 */
const remotePatterns = []

// S3 Storage
if (process.env.S3_UPLOAD_ENDPOINT) {
  // custom endpoint for providers other than AWS
  const url = new URL(process.env.S3_UPLOAD_ENDPOINT);
  remotePatterns.push({
    hostname: url.hostname,
  })
} else if (process.env.S3_UPLOAD_BUCKET && process.env.S3_UPLOAD_REGION) {
  // default provider
  remotePatterns.push({
    hostname: `${process.env.S3_UPLOAD_BUCKET}.s3.${process.env.S3_UPLOAD_REGION}.amazonaws.com`,
  })
}

/**
 * Server Actions origin allow-list.
 *
 * Next.js rejects a forwarded Server Action request unless the `Origin`
 * header host matches the `x-forwarded-host`/`host` header, OR the origin
 * is present in this allow-list. Behind the OpenHost router the auth-proxy
 * (openhost/auth_proxy.py) passes the browser's `Origin` header through
 * UNCHANGED and rewrites `Host`/`X-Forwarded-Host` to the public host, so a
 * real browser navigation — whose Origin already equals that public host —
 * is same-origin from Next's perspective and passes WITHOUT needing an entry
 * here, while a genuine cross-site request keeps its foreign Origin and is
 * rejected. We therefore keep this list minimal — only `localhost:3000` for
 * `npm run dev` — and deliberately do NOT add a `*.selfhost.imbue.com`
 * wildcard, which would make every other OpenHost tenant's zone a valid
 * Server Action origin against this app and defeat Next's cross-origin CSRF
 * protection.
 */
const serverActionAllowedOrigins = ['localhost:3000']

/** @type {import('next').NextConfig} */
const nextConfig = {
  // Emit a self-contained server bundle so the runtime image is small and
  // starts fast (no full node_modules copy needed at runtime).
  output: 'standalone',
  images: {
    remotePatterns,
    // The auth-proxy serves images over the same origin; allow the app to
    // optimize local uploads without an external loader.
    unoptimized: false,
  },
  experimental: {
    serverActions: {
      allowedOrigins: serverActionAllowedOrigins,
    },
  },
}

export default withNextIntl(nextConfig)
