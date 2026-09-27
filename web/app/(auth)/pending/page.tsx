import React from "react";
import Link from "next/link";
import { Clock, ArrowRight, ShieldCheck } from "lucide-react";

export default function PendingPage() {
  return (
    <div className="flex flex-col items-center justify-center min-h-[calc(100vh-12rem)] py-8">
      <div className="w-full max-w-md bg-white p-8 rounded-xl border border-slate-200 shadow-sm text-center space-y-6">
        <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-amber-50 text-amber-600">
          <Clock className="h-8 w-8" />
        </div>

        <div className="space-y-2">
          <h1 className="text-2xl font-bold text-navy-900">Registration Pending</h1>
          <p className="text-sm text-slate-600 leading-relaxed">
            Your account request has been successfully registered. In accordance with IMD policy, all new accounts require verification and approval by the Training Cell Administrator before access is granted.
          </p>
        </div>

        <div className="rounded-lg bg-slate-50 p-4 text-xs text-slate-500 border border-slate-200 text-left space-y-1.5">
          <div className="font-semibold text-slate-700 flex items-center gap-1.5">
            <ShieldCheck className="h-4 w-4 text-emerald-600" />
            Verification Process
          </div>
          <p>
            Once approved, you will be able to log in with your email and password immediately.
          </p>
        </div>

        <Link
          href="/login"
          className="inline-flex items-center gap-2 rounded-lg bg-primary py-2.5 px-5 text-sm font-semibold text-white shadow-sm hover:bg-primary-hover transition-colors"
        >
          Return to Sign In
          <ArrowRight className="h-4 w-4" />
        </Link>
      </div>
    </div>
  );
}
