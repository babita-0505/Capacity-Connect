"use client";
import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function AdminDashboard() {
  const { user } = useAuth(); const [data, setData] = useState<Awaited<ReturnType<typeof api.dashboard.admin>>>(); const [error, setError] = useState("");
  useEffect(() => { if (user?.role === "admin") api.dashboard.admin().then(setData).catch(e => setError(e.message)); }, [user]);
  if (user && user.role !== "admin") return <p className="rounded-lg bg-red-50 p-4 text-red-800">Administrator access is required.</p>;
  if (error) return <p className="rounded-lg bg-red-50 p-4 text-red-800">{error}</p>;
  if (!data) return <p>Loading dashboard…</p>;
  return <div className="space-y-7"><div><h1 className="text-2xl font-bold text-navy-900">Admin dashboard</h1><p className="text-sm text-slate-600">Live platform metrics from the training database.</p></div><div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">{Object.entries(data.kpis).map(([key,value]) => <section key={key} className="rounded-xl border bg-white p-4"><p className="text-xs uppercase text-slate-500">{key.replaceAll("_", " ")}</p><strong className="mt-1 block text-2xl text-navy-900">{value}</strong></section>)}</div><section className="rounded-xl border bg-white p-5"><h2 className="font-bold">Course participation</h2><div className="mt-3 space-y-3">{data.courses.map(c => <div key={c.title}><div className="flex justify-between text-sm"><span>{c.title}</span><span>{c.enrollments} enrolled · {c.completions} completed</span></div><div className="mt-1 h-2 rounded bg-slate-100"><div className="h-full rounded bg-primary" style={{width: `${c.enrollments ? 100 * c.completions / c.enrollments : 0}%`}} /></div></div>)}</div></section></div>;
}
