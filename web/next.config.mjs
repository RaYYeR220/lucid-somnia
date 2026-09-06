/** @type {import('next').NextConfig} */
const nextConfig = {
  // Lucid has no backend and the front end must be able to say so truthfully: a static export
  // has nowhere to hide a server. Every number on every page is fetched from the Somnia RPC or
  // the public DreamDEX indexer by the reader's own browser.
  output: 'export',
  trailingSlash: true,
  images: { unoptimized: true },
  reactStrictMode: true,
  typescript: { ignoreBuildErrors: false },
  eslint: { ignoreDuringBuilds: true },
}

export default nextConfig
