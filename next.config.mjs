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

/** @type {import('next').NextConfig} */
const nextConfig = {
  // Emit a self-contained server bundle so the runtime image is small and
  // starts fast (no full node_modules copy needed at runtime).
  output: 'standalone',
  images: {
    remotePatterns,
  },
  // Server Actions origin handling:
  //
  // Next rejects a forwarded Server Action whose `Origin` host does not match
  // the `x-forwarded-host`/`host` header, unless the origin is in an
  // `allowedOrigins` list. `allowedOrigins` is baked at BUILD time, but the
  // zone domain is only known at runtime and varies per deployment, so we do
  // NOT try to bake it in. Instead the auth-proxy forwards the browser's real
  // `Origin` unchanged and rewrites `Host`/`X-Forwarded-Host` to that same
  // external host, so legitimate same-origin mutations pass Next's check
  // naturally and cross-site requests are still rejected. Only localhost is
  // listed, for local `next dev`/`next start` outside the container.
  experimental: {
    serverActions: {
      allowedOrigins: ['localhost:3000'],
    },
  },
}

export default withNextIntl(nextConfig)
