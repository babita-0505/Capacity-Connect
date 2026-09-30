/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  output: "standalone",
  async rewrites() {
    // In local dev without Nginx or in Railway, proxy /api requests to FastAPI backend
   // const backendUrl = process.env.BACKEND_URL || "http://127.0.0.1:8000";
    const backendUrl = "https://carefree-forgiveness-production-1016.up.railway.app";
    return [
      {
        source: "/api/:path*",
        destination: `${backendUrl}/api/:path*`,
      },
      {
        source: "/uploads/:path*",
        destination: `${backendUrl}/uploads/:path*`,
      },
    ];
  },
};

module.exports = nextConfig;
