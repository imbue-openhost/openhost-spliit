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
 * keeps `Origin` and `X-Forwarded-Host` consistent, so same-origin
 * mutations pass without this list. We still allow the zone domain (and a
 * wildcard for OpenHost zones) at build time as a belt-and-suspenders
 * measure for infra that rewrites one header but not the other.
 */
const serverActionAllowedOrigins = ['localhost:3000']
if (process.env.OPENHOST_ZONE_DOMAIN) {
  serverActionAllowedOrigins.push(process.env.OPENHOST_ZONE_DOMAIN)
}
serverActionAllowedOrigins.push('*.selfhost.imbue.com')

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
