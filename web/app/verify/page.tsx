"use client";
import { useState } from "react";
import { fetchApi } from "@/lib/api";

type Verification = { status: string; name?: string; course?: string; issue_date?: string };
export default function VerifyPage() {
  const [number,setNumber]=useState(""); const [result,setResult]=useState<Verification>(); const [error,setError]=useState("");
  const verify=async(e:React.FormEvent)=>{e.preventDefault();setError("");try{setResult(await fetchApi<Verification>(`/verify/${encodeURIComponent(number)}`));}catch(err){setError(err instanceof Error?err.message:"Unable to verify certificate.");}};
  return <div className="mx-auto max-w-xl space-y-6 py-10"><div><h1 className="text-2xl font-bold text-navy-900">Verify certificate</h1><p className="text-sm text-slate-600">Enter the certificate number shown on the credential.</p></div><form onSubmit={verify} className="flex gap-2"><label className="sr-only" htmlFor="certificate">Certificate number</label><input id="certificate" required value={number} onChange={e=>setNumber(e.target.value)} placeholder="IMD-CC-2026-000123" className="min-w-0 flex-1 rounded-lg border p-2"/><button className="rounded-lg bg-primary px-4 text-sm font-semibold text-white">Verify</button></form>{error&&<p className="rounded-lg bg-red-50 p-3 text-red-800">{error}</p>}{result&&<section className={`rounded-xl border p-5 ${result.status==="Valid"?"border-green-300 bg-green-50":"border-slate-200 bg-white"}`}><strong className="text-lg">{result.status}</strong>{result.status==="Valid"&&<p className="mt-2 text-sm text-slate-700">Issued to {result.name} for {result.course} on {result.issue_date ? new Date(result.issue_date).toLocaleDateString() : ""}.</p>}</section>}</div>;
}
