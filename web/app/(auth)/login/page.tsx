"use client";

import React, { useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { Lock, Mail, AlertCircle, ArrowRight } from "lucide-react";
import { api } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function LoginPage() {
  const router = useRouter();
  const { refreshUser } = useAuth();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setLoading(true);

    try {
      const res = await api.auth.login({ email, password });
      await refreshUser();

      // Route based on role
      if (res.user.role === "admin") {
        router.push("/admin/users");
      } else if (res.user.role === "trainer") {
        router.push("/trainer/courses");
      } else {
        router.push("/courses");
      }
    } catch (err: any) {
      setError(err.message || "Failed to log in");
    } finally {
      setLoading(false);
    }
  };

  const setDemoLogin = (demoEmail: string) => {
    setEmail(demoEmail);
    setPassword("Demo@1234");
    setError(null);
  };

  return (
    <div className="flex flex-col items-center justify-center min-h-[calc(100vh-12rem)] py-8">
      <div className="w-full max-w-md bg-white p-8 rounded-xl border border-slate-200 shadow-sm space-y-6">
        <div className="text-center space-y-1">
          <h1 className="text-2xl font-bold text-navy-900">Sign In</h1>
          <p className="text-sm text-slate-500">Access your Capacity Connect account</p>
        </div>

        {error && (
          <div className="flex items-start gap-2.5 p-3 rounded-lg bg-red-50 border border-red-200 text-red-700 text-sm">
            <AlertCircle className="h-5 w-5 flex-shrink-0 mt-0.5" />
            <div className="flex-1">{error}</div>
          </div>
        )}

        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-1">
            <label className="text-xs font-semibold text-slate-700">Official Email</label>
            <div className="relative">
              <Mail className="absolute left-3 top-3 h-4 w-4 text-slate-400" />
              <input
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="name@imd.gov.in or .demo"
                className="w-full rounded-lg border border-slate-300 pl-10 pr-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent"
              />
            </div>
          </div>

          <div className="space-y-1">
            <div className="flex justify-between items-center">
              <label className="text-xs font-semibold text-slate-700">Password</label>
            </div>
            <div className="relative">
              <Lock className="absolute left-3 top-3 h-4 w-4 text-slate-400" />
              <input
                type="password"
                required
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="••••••••"
                className="w-full rounded-lg border border-slate-300 pl-10 pr-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-primary focus:border-transparent"
              />
            </div>
          </div>

          <button
            type="submit"
            disabled={loading}
            className="w-full rounded-lg bg-primary py-2.5 px-4 text-sm font-semibold text-white shadow-sm hover:bg-primary-hover disabled:opacity-50 transition-colors"
          >
            {loading ? "Authenticating..." : "Sign In"}
          </button>
        </form>

        {/* Demo Accounts Quick-Select */}
        <div className="pt-4 border-t border-slate-200 space-y-3">
          <p className="text-xs font-semibold text-slate-500 uppercase tracking-wider text-center">
            Demo Accounts (Pass: Demo@1234)
          </p>
          <div className="grid grid-cols-3 gap-2">
            <button
              type="button"
              onClick={() => setDemoLogin("admin@imd.demo")}
              className="py-1.5 px-2 text-xs font-medium rounded border border-slate-200 bg-slate-50 hover:bg-slate-100 text-slate-800 text-center truncate"
            >
              Admin
            </button>
            <button
              type="button"
              onClick={() => setDemoLogin("trainer01@imd.demo")}
              className="py-1.5 px-2 text-xs font-medium rounded border border-slate-200 bg-slate-50 hover:bg-slate-100 text-slate-800 text-center truncate"
            >
              Trainer 01
            </button>
            <button
              type="button"
              onClick={() => setDemoLogin("trainee001@imd.demo")}
              className="py-1.5 px-2 text-xs font-medium rounded border border-slate-200 bg-slate-50 hover:bg-slate-100 text-slate-800 text-center truncate"
            >
              Trainee 001
            </button>
          </div>
        </div>

        <p className="text-center text-xs text-slate-500">
          Don&apos;t have an account yet?{" "}
          <Link href="/signup" className="font-semibold text-primary hover:underline">
            Register here
          </Link>
        </p>
      </div>
    </div>
  );
}
