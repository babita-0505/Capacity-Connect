"use client";

import React, { useEffect, useState } from "react";
import Link from "next/link";
import {
  Users,
  Award,
  BookOpen,
  CheckCircle2,
  Clock,
  TrendingUp,
  UserCheck,
  BrainCircuit,
  Grid3X3,
  ArrowRight,
  ShieldCheck
} from "lucide-react";
import {
  LineChart,
  Line,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Legend,
  ResponsiveContainer
} from "recharts";
import { api } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function AdminDashboardPage() {
  const { user, loading: authLoading } = useAuth();
  const [data, setData] = useState<Awaited<ReturnType<typeof api.dashboard.admin>> | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [approvalNotice, setApprovalNotice] = useState("");

  const loadDashboard = async () => {
    try {
      setLoading(true);
      const res = await api.dashboard.admin();
      setData(res);
    } catch (e: any) {
      setError(e.message || "Failed to load admin metrics");
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (!authLoading && user?.role === "admin") {
      loadDashboard();
    }
  }, [user, authLoading]);

  const handleQuickApprove = async (userId: string) => {
    try {
      await api.admin.approveUser(userId);
      setApprovalNotice("User approved successfully.");
      setTimeout(() => setApprovalNotice(""), 3000);
      loadDashboard();
    } catch (e: any) {
      alert(e.message || "Failed to approve user");
    }
  };

  if (!authLoading && user && user.role !== "admin") {
    return (
      <div className="p-8 text-center text-red-700 bg-red-50 rounded-xl border border-red-200">
        Administrator credentials required to view this dashboard.
      </div>
    );
  }

  if (loading || authLoading) {
    return (
      <div className="flex flex-col items-center justify-center p-20 space-y-3">
        <div className="h-8 w-8 animate-spin rounded-full border-4 border-primary border-t-transparent"></div>
        <p className="text-xs text-slate-500">Loading live platform KPIs and analytics...</p>
      </div>
    );
  }

  if (error || !data) {
    return (
      <div className="p-6 bg-red-50 text-red-800 rounded-xl border border-red-200">
        {error || "Unable to display dashboard."}
      </div>
    );
  }

  // Format monthly activity for recharts
  const activityData = (data.activity || []).map((m: any) => ({
    name: m.month ? new Date(m.month).toLocaleDateString([], { month: "short", year: "2-digit" }) : "",
    Enrollments: Number(m.enrollments || 0),
    "Test Attempts": Number(m.attempts || 0),
    Certificates: Number(m.certificates || 0),
  }));

  // Format course stats for recharts (top 6 courses)
  const courseChartData = (data.courses || []).slice(0, 6).map((c: any) => ({
    name: c.title.length > 20 ? c.title.substring(0, 18) + "..." : c.title,
    Enrolled: Number(c.enrollments || 0),
    Completed: Number(c.completions || 0),
  }));

  // Format assessment pass rates for recharts (top 6 tests)
  const assessmentChartData = (data.assessments || []).slice(0, 6).map((a: any) => ({
    name: a.title.length > 20 ? a.title.substring(0, 18) + "..." : a.title,
    "Pass Rate %": Number(a.pass_rate_pct || 0),
    "Avg Score %": Number(a.avg_pct || 0),
  }));

  return (
    <div className="space-y-7 pb-12">
      {/* Top Banner */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <div className="inline-flex items-center gap-1.5 rounded-full bg-blue-50 border border-blue-200 px-3 py-0.5 text-[11px] font-semibold text-primary mb-1">
            <ShieldCheck className="h-3.5 w-3.5" /> IMD Capacity Building Cell
          </div>
          <h1 className="text-2xl font-bold text-navy-900 tracking-tight">Admin Executive Dashboard</h1>
          <p className="text-sm text-slate-500">
            Real-time training metrics, regional competency overview, and pending user verification
          </p>
        </div>

        <div className="flex items-center gap-2">
          <Link
            href="/admin/users"
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-300 bg-white hover:bg-slate-50 px-3.5 py-2 text-xs font-semibold text-slate-700 shadow-xs transition-colors"
          >
            <UserCheck className="h-4 w-4" /> Manage Users
          </Link>
          <Link
            href="/admin/competency"
            className="inline-flex items-center gap-1.5 rounded-lg bg-primary hover:bg-primary-hover px-3.5 py-2 text-xs font-semibold text-white shadow-sm transition-colors"
          >
            <BrainCircuit className="h-4 w-4" /> Competency Mapping
          </Link>
        </div>
      </div>

      {approvalNotice && (
        <div className="p-3 bg-emerald-50 border border-emerald-200 text-emerald-800 rounded-xl text-xs flex items-center gap-2">
          <CheckCircle2 className="h-4 w-4 text-emerald-600" />
          <span>{approvalNotice}</span>
        </div>
      )}

      {/* KPI Tiles from v_platform_kpis */}
      <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
        {Object.entries(data.kpis).map(([key, value]) => (
          <div key={key} className="bg-white p-4 rounded-xl border border-slate-200 shadow-xs space-y-1">
            <span className="text-[10px] uppercase font-bold text-slate-400 block truncate">
              {key.replaceAll("_", " ")}
            </span>
            <strong className="text-xl sm:text-2xl font-black text-navy-900">{value}</strong>
          </div>
        ))}
      </div>

      {/* Charts Section: Row 1 */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Monthly Activity Trend */}
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm space-y-4">
          <div className="flex items-center justify-between border-b border-slate-100 pb-2">
            <div>
              <h2 className="text-sm font-bold text-navy-900">12-Month Activity Trends</h2>
              <p className="text-[11px] text-slate-400">Enrollments, Test Attempts, and Certified Personnel</p>
            </div>
          </div>

          <div className="h-64 w-full">
            <ResponsiveContainer width="100%" height="100%">
              <LineChart data={activityData} margin={{ top: 10, right: 10, left: 0, bottom: 0 }}>
                <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#E2E8F0" />
                <XAxis dataKey="name" tick={{ fontSize: 10 }} stroke="#94A3B8" angle={-35} textAnchor="end" height={50} />
                <YAxis tick={{ fontSize: 10 }} stroke="#94A3B8" />
                <Tooltip contentStyle={{ fontSize: "11px", borderRadius: "8px" }} />
                <Legend wrapperStyle={{ fontSize: "11px", paddingTop: "8px" }} />
                <Line type="monotone" dataKey="Enrollments" stroke="#2563EB" strokeWidth={2} dot={{ r: 3 }} />
                <Line type="monotone" dataKey="Test Attempts" stroke="#10B981" strokeWidth={2} dot={{ r: 3 }} />
                <Line type="monotone" dataKey="Certificates" stroke="#8B5CF6" strokeWidth={2} dot={{ r: 3 }} />
              </LineChart>
            </ResponsiveContainer>
          </div>
        </div>

        {/* Course Enrolments vs Completions */}
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm space-y-4">
          <div className="flex items-center justify-between border-b border-slate-100 pb-2">
            <div>
              <h2 className="text-sm font-bold text-navy-900">Top Courses: Enrolled vs Completed</h2>
              <p className="text-[11px] text-slate-400">Completion ratios across published curriculum</p>
            </div>
          </div>

          <div className="h-64 w-full">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={courseChartData} margin={{ top: 10, right: 10, left: 0, bottom: 0 }}>
                <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#E2E8F0" />
                <XAxis dataKey="name" tick={{ fontSize: 10 }} stroke="#94A3B8" angle={-35} textAnchor="end" height={50} />
                <YAxis tick={{ fontSize: 10 }} stroke="#94A3B8" />
                <Tooltip contentStyle={{ fontSize: "11px", borderRadius: "8px" }} />
                <Legend wrapperStyle={{ fontSize: "11px", paddingTop: "8px" }} />
                <Bar dataKey="Enrolled" fill="#3B82F6" radius={[4, 4, 0, 0]} />
                <Bar dataKey="Completed" fill="#10B981" radius={[4, 4, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>
      </div>

      {/* Row 2: Assessment Pass Rates & Pending User Approvals */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Assessment Pass Rates */}
        <div className="lg:col-span-2 bg-white rounded-xl border border-slate-200 p-5 shadow-sm space-y-4">
          <div className="flex items-center justify-between border-b border-slate-100 pb-2">
            <div>
              <h2 className="text-sm font-bold text-navy-900">Assessment Evaluations & Pass Rates</h2>
              <p className="text-[11px] text-slate-400">Pass percentages and average scores for key tests</p>
            </div>
            <Link href="/admin/competency" className="text-xs text-primary font-semibold hover:underline">
              Inspect Gaps →
            </Link>
          </div>

          <div className="h-60 w-full">
            <ResponsiveContainer width="100%" height="100%">
              <BarChart data={assessmentChartData} margin={{ top: 10, right: 10, left: 0, bottom: 0 }}>
                <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="#E2E8F0" />
                <XAxis dataKey="name" tick={{ fontSize: 10 }} stroke="#94A3B8" angle={-35} textAnchor="end" height={50} />
                <YAxis domain={[0, 100]} tick={{ fontSize: 10 }} stroke="#94A3B8" />
                <Tooltip contentStyle={{ fontSize: "11px", borderRadius: "8px" }} />
                <Legend wrapperStyle={{ fontSize: "11px", paddingTop: "8px" }} />
                <Bar dataKey="Pass Rate %" fill="#059669" radius={[4, 4, 0, 0]} />
                <Bar dataKey="Avg Score %" fill="#6366F1" radius={[4, 4, 0, 0]} />
              </BarChart>
            </ResponsiveContainer>
          </div>
        </div>

        {/* Pending Approvals Quick Queue */}
        <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm space-y-4 flex flex-col justify-between">
          <div className="space-y-3">
            <div className="flex items-center justify-between border-b border-slate-100 pb-2">
              <h2 className="text-sm font-bold text-navy-900 flex items-center gap-1.5">
                <Users className="h-4 w-4 text-primary" />
                <span>Approval Queue</span>
              </h2>
              <Link href="/admin/users" className="text-xs text-primary font-semibold hover:underline">
                View All
              </Link>
            </div>

            <div className="space-y-2.5">
              {(data.pending_users || []).length === 0 ? (
                <div className="p-8 text-center text-slate-400 text-xs italic">
                  No pending account approvals in the queue.
                </div>
              ) : (
                (data.pending_users || []).slice(0, 5).map((u: any) => (
                  <div
                    key={u.id}
                    className="p-3 rounded-lg border border-slate-100 bg-slate-50/50 flex items-center justify-between gap-2 text-xs"
                  >
                    <div className="space-y-0.5 truncate">
                      <p className="font-semibold text-slate-800 truncate">{u.full_name}</p>
                      <p className="text-[10px] text-slate-400 truncate">{u.email} · {u.department || "IMD"}</p>
                    </div>

                    <button
                      onClick={() => handleQuickApprove(u.id)}
                      className="px-2.5 py-1 bg-emerald-600 hover:bg-emerald-700 text-white rounded text-[11px] font-bold shadow-xs transition-colors flex-shrink-0"
                    >
                      Approve
                    </button>
                  </div>
                ))
              )}
            </div>
          </div>

          <div className="pt-2 border-t border-slate-100">
            <Link
              href="/admin/users?status=pending"
              className="w-full inline-flex items-center justify-center gap-1 py-2 text-xs font-semibold text-slate-600 hover:text-navy-900 hover:bg-slate-50 rounded-lg transition-colors"
            >
              Full Verification Table <ArrowRight className="h-3.5 w-3.5" />
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}
