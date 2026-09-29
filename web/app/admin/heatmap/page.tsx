"use client";

import React, { useEffect, useState } from "react";
import Link from "next/link";
import {
  Grid3X3,
  List,
  Filter,
  RefreshCw,
  Info,
  TrendingDown,
  TrendingUp,
  ArrowLeft,
  BrainCircuit
} from "lucide-react";
import { api } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

interface HeatmapItem {
  department: string;
  skill: string;
  category?: string;
  avg_pct: number;
  trainees: number;
}

export default function CompetencyHeatmapPage() {
  const { user, loading: authLoading } = useAuth();

  const [heatmapData, setHeatmapData] = useState<HeatmapItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedDept, setSelectedDept] = useState<string>("");
  const [selectedCategory, setSelectedCategory] = useState<string>("");
  const [viewMode, setViewMode] = useState<"grid" | "list">("grid");
  const [recalculating, setRecalculating] = useState(false);
  const [notice, setNotice] = useState("");

  const loadData = async () => {
    try {
      setLoading(true);
      const res = await api.competency.heatmap();
      setHeatmapData(res.items);
    } catch (err: any) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (!authLoading && user?.role === "admin") {
      loadData();
    }
  }, [user, authLoading]);

  const handleRecalculate = async () => {
    try {
      setRecalculating(true);
      setNotice("Queuing competency score recalculation...");
      const { job_id } = await api.competency.refresh();

      const poll = async () => {
        const state = await api.competency.job(job_id);
        if (state.status === "done") {
          setNotice("Competency matrix refreshed with latest test submissions.");
          setRecalculating(false);
          loadData();
          setTimeout(() => setNotice(""), 3000);
        } else if (state.status === "failed") {
          setNotice("Recalculation failed: " + (state.error || "Unknown"));
          setRecalculating(false);
        } else {
          window.setTimeout(poll, 2000);
        }
      };
      poll();
    } catch (err: any) {
      setNotice("Failed to start recalculation.");
      setRecalculating(false);
    }
  };

  // Distinct departments and skills
  const departments = Array.from(new Set(heatmapData.map((d) => d.department))).sort();
  const skills = Array.from(new Set(heatmapData.map((d) => d.skill))).sort();
  const categories = Array.from(new Set(heatmapData.map((d) => d.category).filter(Boolean))) as string[];

  // Filtered dataset
  const filteredData = heatmapData.filter((item) => {
    if (selectedDept && item.department !== selectedDept) return false;
    if (selectedCategory && item.category !== selectedCategory) return false;
    return true;
  });

  // Department x Skill lookup map
  const matrixMap: Record<string, HeatmapItem> = {};
  filteredData.forEach((item) => {
    matrixMap[`${item.department}::${item.skill}`] = item;
  });

  // Color helper based on percentage
  const getColorClass = (pct: number | undefined) => {
    if (pct === undefined) return "bg-slate-100 text-slate-400";
    if (pct >= 75) return "bg-emerald-500 text-white font-bold";
    if (pct >= 60) return "bg-emerald-200 text-emerald-950 font-semibold";
    if (pct >= 45) return "bg-amber-200 text-amber-950 font-semibold";
    return "bg-rose-400 text-white font-bold";
  };

  if (!authLoading && user?.role !== "admin") {
    return (
      <div className="p-8 text-center text-red-600 bg-red-50 rounded-xl border border-red-200">
        Access restricted to Ministry / IMD Training Administrators.
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Top Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <div className="flex items-center gap-2">
            <Link
              href="/admin/competency"
              className="text-xs text-slate-500 hover:text-navy-900 font-semibold flex items-center gap-1"
            >
              <ArrowLeft className="h-3.5 w-3.5" /> Back to Competency Mapping
            </Link>
          </div>
          <h1 className="text-2xl font-bold text-navy-900 tracking-tight mt-1">
            Workforce Competency Heatmap
          </h1>
          <p className="text-sm text-slate-500">
            Regional Meteorological Centre evaluation matrix across operational IMD meteorological disciplines
          </p>
        </div>

        <div className="flex items-center gap-2">
          {/* View toggle */}
          <div className="flex items-center bg-slate-100 p-1 rounded-lg">
            <button
              onClick={() => setViewMode("grid")}
              className={`p-1.5 rounded-md text-xs font-semibold ${
                viewMode === "grid" ? "bg-white text-navy-900 shadow-xs" : "text-slate-500 hover:text-navy-900"
              }`}
              title="Matrix Grid View"
            >
              <Grid3X3 className="h-4 w-4" />
            </button>
            <button
              onClick={() => setViewMode("list")}
              className={`p-1.5 rounded-md text-xs font-semibold ${
                viewMode === "list" ? "bg-white text-navy-900 shadow-xs" : "text-slate-500 hover:text-navy-900"
              }`}
              title="Grouped List View"
            >
              <List className="h-4 w-4" />
            </button>
          </div>

          <button
            onClick={handleRecalculate}
            disabled={recalculating}
            className="inline-flex items-center gap-1.5 rounded-lg bg-primary hover:bg-primary-hover px-4 py-2 text-xs font-semibold text-white shadow-sm disabled:opacity-50 transition-colors"
          >
            <RefreshCw className={`h-3.5 w-3.5 ${recalculating ? "animate-spin" : ""}`} />
            {recalculating ? "Recalculating..." : "Recalculate Matrix"}
          </button>
        </div>
      </div>

      {notice && (
        <div className="p-3 bg-blue-50 border border-blue-200 text-blue-800 rounded-xl text-xs flex items-center gap-2">
          <Info className="h-4 w-4 text-blue-600 flex-shrink-0" />
          <span>{notice}</span>
        </div>
      )}

      {/* Filter and Legend Bar */}
      <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-sm flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div className="flex flex-wrap items-center gap-3">
          <select
            value={selectedDept}
            onChange={(e) => setSelectedDept(e.target.value)}
            className="rounded-lg border border-slate-300 py-1.5 px-3 text-xs bg-white focus:ring-2 focus:ring-primary focus:outline-none"
          >
            <option value="">All RMCs / Divisions ({departments.length})</option>
            {departments.map((d) => (
              <option key={d} value={d}>
                {d}
              </option>
            ))}
          </select>

          {categories.length > 0 && (
            <select
              value={selectedCategory}
              onChange={(e) => setSelectedCategory(e.target.value)}
              className="rounded-lg border border-slate-300 py-1.5 px-3 text-xs bg-white focus:ring-2 focus:ring-primary focus:outline-none"
            >
              <option value="">All Categories ({categories.length})</option>
              {categories.map((c) => (
                <option key={c} value={c}>
                  {c}
                </option>
              ))}
            </select>
          )}

          {(selectedDept || selectedCategory) && (
            <button
              onClick={() => {
                setSelectedDept("");
                setSelectedCategory("");
              }}
              className="text-xs text-primary font-semibold hover:underline"
            >
              Reset Filters
            </button>
          )}
        </div>

        {/* Color Legend */}
        <div className="flex items-center gap-3 text-[11px] text-slate-600 flex-wrap">
          <span className="font-semibold text-slate-700">Competency:</span>
          <div className="flex items-center gap-1.5">
            <span className="h-3 w-5 rounded bg-emerald-500 inline-block" />
            <span>&ge; 75% Strong</span>
          </div>
          <div className="flex items-center gap-1.5">
            <span className="h-3 w-5 rounded bg-emerald-200 inline-block" />
            <span>60-74% Competent</span>
          </div>
          <div className="flex items-center gap-1.5">
            <span className="h-3 w-5 rounded bg-amber-200 inline-block" />
            <span>45-59% Vulnerable</span>
          </div>
          <div className="flex items-center gap-1.5">
            <span className="h-3 w-5 rounded bg-rose-400 inline-block" />
            <span>&lt; 45% Critical Gap</span>
          </div>
        </div>
      </div>

      {/* Main Heatmap Content */}
      {loading ? (
        <div className="p-16 text-center text-slate-400 text-sm">
          Generating workforce heatmap from analytical views...
        </div>
      ) : viewMode === "grid" ? (
        /* Matrix Grid View */
        <div className="bg-white rounded-xl border border-slate-200 shadow-sm overflow-x-auto">
          <table className="w-full text-left text-xs border-collapse">
            <thead>
              <tr className="bg-slate-50 border-b border-slate-200">
                <th className="p-3 font-bold text-navy-900 sticky left-0 bg-slate-50 min-w-[180px] z-10">
                  Regional Centre / Unit
                </th>
                {skills.map((skill) => (
                  <th
                    key={skill}
                    className="p-3 font-semibold text-slate-700 min-w-[140px] text-center border-l border-slate-100"
                  >
                    <div className="line-clamp-2" title={skill}>
                      {skill}
                    </div>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {(selectedDept ? [selectedDept] : departments).map((dept) => (
                <tr key={dept} className="hover:bg-slate-50/50">
                  <td className="p-3 font-semibold text-slate-900 sticky left-0 bg-white z-10 border-r border-slate-200 whitespace-nowrap">
                    {dept}
                  </td>
                  {skills.map((skill) => {
                    const item = matrixMap[`${dept}::${skill}`];
                    const pct = item ? Math.round(item.avg_pct) : undefined;
                    return (
                      <td
                        key={skill}
                        className="p-1 text-center border-l border-slate-100"
                        title={
                          item
                            ? `${dept} - ${skill}\nAverage: ${pct}%\nTrainees Evaluated: ${item.trainees}`
                            : "No evaluation data"
                        }
                      >
                        <div
                          className={`py-2 px-1 rounded-lg transition-transform hover:scale-105 cursor-default ${getColorClass(
                            pct
                          )}`}
                        >
                          {pct !== undefined ? `${pct}%` : "—"}
                          {item && (
                            <span className="block text-[9px] opacity-75 font-normal">
                              ({item.trainees} staff)
                            </span>
                          )}
                        </div>
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        /* Grouped List View (Mobile friendly) */
        <div className="space-y-4">
          {(selectedDept ? [selectedDept] : departments).map((dept) => {
            const deptItems = filteredData.filter((i) => i.department === dept);
            if (deptItems.length === 0) return null;

            return (
              <div key={dept} className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm space-y-3">
                <h3 className="font-bold text-navy-900 text-base border-b border-slate-100 pb-2">
                  {dept}
                </h3>
                <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-3">
                  {deptItems.map((item) => {
                    const pct = Math.round(item.avg_pct);
                    return (
                      <div
                        key={item.skill}
                        className="p-3 rounded-lg border border-slate-200 flex items-center justify-between gap-3"
                      >
                        <div className="space-y-0.5">
                          <strong className="text-xs text-slate-800 line-clamp-1">{item.skill}</strong>
                          <span className="text-[10px] text-slate-400 block">
                            Evaluated: {item.trainees} personnel
                          </span>
                        </div>
                        <div className={`px-2.5 py-1 rounded text-xs ${getColorClass(pct)}`}>
                          {pct}%
                        </div>
                      </div>
                    );
                  })}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
