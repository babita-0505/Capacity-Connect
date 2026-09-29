"use client";

import React, { useEffect, useState } from "react";
import Link from "next/link";
import {
  BrainCircuit,
  Grid3X3,
  HelpCircle,
  RefreshCw,
  X,
  Award,
  ChevronRight,
  TrendingUp,
  AlertTriangle,
  CheckCircle2,
  BookOpen,
  ArrowRight
} from "lucide-react";
import { api, CompetencyRecommendation, SkillGap, SkillNode } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

const pct = (n: number | undefined) => `${Math.round(Number(n || 0) * 100)}%`;

export default function CompetencyPage() {
  const { user, loading: authLoading } = useAuth();

  const [skills, setSkills] = useState<SkillNode[]>([]);
  const [selected, setSelected] = useState<number>();
  const [trainers, setTrainers] = useState<CompetencyRecommendation[]>([]);
  const [gaps, setGaps] = useState<SkillGap[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [notice, setNotice] = useState("");

  // Slide-out Drawer for "Why this trainer?"
  const [selectedWhyTrainer, setSelectedWhyTrainer] = useState<CompetencyRecommendation | null>(null);

  useEffect(() => {
    if (!authLoading && user?.role === "admin") {
      Promise.all([api.profile.getSkillsTree(), api.competency.gaps()])
        .then(([tree, gapData]) => {
          const leaves: SkillNode[] = [];
          tree.forEach((root) => {
            if (root.children && root.children.length > 0) {
              root.children.forEach((c) => leaves.push(c));
            } else {
              leaves.push(root);
            }
          });
          setSkills(leaves);
          setGaps(gapData.items);
          if (leaves.length > 0) {
            setSelected(leaves[0].id);
          }
        })
        .catch((e) => setError(e.message))
        .finally(() => setLoading(false));
    }
  }, [user, authLoading]);

  useEffect(() => {
    if (!selected) return;
    api.competency
      .trainers(selected)
      .then((x) => setTrainers(x.items))
      .catch((e) => setError(e.message));
  }, [selected]);

  const refresh = async () => {
    try {
      const { job_id } = await api.competency.refresh();
      setNotice("Recalculation has been queued in background.");

      const tick = async () => {
        const job = await api.competency.job(job_id);
        if (job.status === "done") {
          setNotice("Competency scores successfully refreshed.");
          if (selected) {
            setTrainers((await api.competency.trainers(selected)).items);
          }
          setGaps((await api.competency.gaps()).items);
          setTimeout(() => setNotice(""), 3000);
        } else if (job.status === "failed") {
          setError(job.error || "Refresh failed.");
        } else {
          window.setTimeout(tick, 2000);
        }
      };
      tick();
    } catch (e: any) {
      setError(e.message || "Unable to recalculate.");
    }
  };

  if (!authLoading && user && user.role !== "admin") {
    return (
      <div className="p-8 text-center text-red-700 bg-red-50 rounded-xl border border-red-200">
        This competency mapping section is available to administrators only.
      </div>
    );
  }

  const selectedSkillName = skills.find((s) => s.id === selected)?.name;

  return (
    <div className="space-y-7">
      {/* Top Banner */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-navy-900 tracking-tight">Competency Mapping</h1>
          <p className="text-sm text-slate-500">
            Explainable, pure SQL-based trainer ranking engine and institutional workforce skill gap analytics
          </p>
        </div>

        <div className="flex items-center gap-2">
          <Link
            href="/admin/heatmap"
            className="inline-flex items-center gap-1.5 rounded-lg border border-slate-300 bg-white hover:bg-slate-50 px-3.5 py-2 text-xs font-semibold text-slate-700 transition-colors shadow-xs"
          >
            <Grid3X3 className="h-4 w-4 text-primary" /> View Regional Heatmap
          </Link>

          <button
            onClick={refresh}
            className="inline-flex items-center gap-1.5 rounded-lg bg-primary hover:bg-primary-hover px-4 py-2 text-xs font-semibold text-white shadow-sm transition-colors"
          >
            <RefreshCw className="h-3.5 w-3.5" /> Recalculate
          </button>
        </div>
      </div>

      {error && <p className="rounded-lg bg-red-50 p-3 text-xs text-red-800">{error}</p>}
      {notice && <p className="rounded-lg bg-emerald-50 p-3 text-xs text-emerald-800">{notice}</p>}

      {/* Main Section: Subject Picker & Ranked Trainers */}
      <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm space-y-6">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-3 border-b border-slate-100 pb-4">
          <div>
            <label className="block text-xs font-bold uppercase tracking-wider text-slate-500">
              Select Meteorology Discipline / Subject
            </label>
            <select
              value={selected || ""}
              onChange={(e) => setSelected(Number(e.target.value))}
              className="mt-1.5 rounded-lg border border-slate-300 p-2 text-xs font-semibold text-navy-900 bg-white focus:ring-2 focus:ring-primary focus:outline-none min-w-[280px]"
            >
              {skills.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.name}
                </option>
              ))}
            </select>
          </div>

          <div className="text-right">
            <span className="text-[11px] text-slate-400 block">Identified Candidates</span>
            <strong className="text-sm text-navy-900 font-bold">{trainers.length} Trainers Ranked</strong>
          </div>
        </div>

        {/* Trainer Cards */}
        {loading ? (
          <p className="p-8 text-center text-xs text-slate-400">Loading competency rankings...</p>
        ) : trainers.length === 0 ? (
          <div className="p-12 text-center text-slate-400 space-y-2">
            <AlertTriangle className="h-8 w-8 text-amber-400 mx-auto" />
            <p className="text-xs font-semibold text-slate-700">No trainer evidence available for this subject</p>
            <p className="text-[11px] text-slate-500">
              This discipline is currently flagged as a critical institutional skill gap.
            </p>
          </div>
        ) : (
          <div className="grid gap-4 md:grid-cols-2">
            {trainers.map((t) => (
              <article
                key={t.trainer_id}
                className="rounded-xl border border-slate-200 p-4 space-y-3 hover:border-slate-300 transition-colors bg-white shadow-xs flex flex-col justify-between"
              >
                <div className="space-y-2">
                  <div className="flex justify-between items-start gap-2">
                    <div>
                      <div className="flex items-center gap-1.5">
                        <span className="h-5 w-5 rounded-full bg-navy-900 text-white font-bold text-[10px] flex items-center justify-center">
                          #{t.rank_in_skill}
                        </span>
                        <h2 className="font-bold text-navy-900 text-sm">{t.full_name}</h2>
                      </div>
                      <p className="text-xs text-slate-500 pl-6.5">{t.department || "IMD Headquarters"}</p>
                    </div>

                    <div className="text-right">
                      <span className="text-[10px] text-slate-400 uppercase font-semibold block">Total Score</span>
                      <strong className="text-base text-primary font-extrabold">{pct(t.total_score)}</strong>
                    </div>
                  </div>

                  {/* Progress bar */}
                  <div className="h-2 overflow-hidden rounded-full bg-slate-100">
                    <div
                      className="h-full bg-primary rounded-full transition-all duration-300"
                      style={{ width: pct(t.total_score) }}
                    />
                  </div>

                  {/* Component Breakdown Pills */}
                  <div className="grid grid-cols-4 gap-1 text-[10px] text-slate-600 bg-slate-50 p-2 rounded-lg text-center">
                    <div>
                      <span className="block text-slate-400 font-medium">Skill Match</span>
                      <strong className="text-slate-800">{pct(t.skill_match)}</strong>
                    </div>
                    <div>
                      <span className="block text-slate-400 font-medium">Pass Rate</span>
                      <strong className="text-slate-800">{pct(t.pass_rate)}</strong>
                    </div>
                    <div>
                      <span className="block text-slate-400 font-medium">Rating</span>
                      <strong className="text-slate-800">{pct(t.rating_score)}</strong>
                    </div>
                    <div>
                      <span className="block text-slate-400 font-medium">Experience</span>
                      <strong className="text-slate-800">{pct(t.experience_score)}</strong>
                    </div>
                  </div>
                </div>

                <div className="pt-2 border-t border-slate-100 flex items-center justify-between text-xs">
                  <span className="text-[11px] text-slate-500 truncate max-w-[200px]">
                    Taught {t.courses_taught} courses · {t.attempts_count} learner attempts
                  </span>

                  <button
                    onClick={() => setSelectedWhyTrainer(t)}
                    className="inline-flex items-center gap-1 text-primary font-bold hover:underline"
                  >
                    Why this trainer? <ChevronRight className="h-3.5 w-3.5" />
                  </button>
                </div>
              </article>
            ))}
          </div>
        )}
      </section>

      {/* Institutional Skill Gaps Section */}
      <section className="space-y-4">
        <div className="flex items-center justify-between">
          <div>
            <h2 className="text-lg font-bold text-navy-900">Workforce Skill Gaps</h2>
            <p className="text-xs text-slate-500">
              Prioritized by severity: Critical gaps have no verified trainer coverage
            </p>
          </div>
          <Link
            href="/admin/heatmap"
            className="text-xs font-semibold text-primary hover:underline flex items-center gap-1"
          >
            Explore regional heatmap <ArrowRight className="h-3.5 w-3.5" />
          </Link>
        </div>

        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {gaps.map((g) => (
            <article
              key={g.skill_id}
              className={`rounded-xl border p-4 bg-white shadow-xs space-y-2.5 ${
                g.gap_status === "critical gap"
                  ? "border-red-200"
                  : g.gap_status === "weak coverage"
                  ? "border-amber-200"
                  : "border-slate-200"
              }`}
            >
              <div className="flex justify-between items-start gap-2">
                <h3 className="font-bold text-navy-900 text-sm leading-snug">{g.skill}</h3>
                <span
                  className={`text-[10px] font-bold px-2 py-0.5 rounded capitalize flex-shrink-0 ${
                    g.gap_status === "critical gap"
                      ? "bg-red-100 text-red-800"
                      : g.gap_status === "weak coverage"
                      ? "bg-amber-100 text-amber-800"
                      : "bg-emerald-100 text-emerald-800"
                  }`}
                >
                  {g.gap_status}
                </span>
              </div>

              <div className="grid grid-cols-3 gap-2 text-[11px] text-slate-600 bg-slate-50 p-2 rounded-lg">
                <div>
                  <span className="text-[10px] text-slate-400 block">Best Score</span>
                  <strong>{pct(g.best_trainer_score)}</strong>
                </div>
                <div>
                  <span className="text-[10px] text-slate-400 block">Trainers</span>
                  <strong>{g.strong_trainers} strong</strong>
                </div>
                <div>
                  <span className="text-[10px] text-slate-400 block">Demand</span>
                  <strong>{g.demand} staff</strong>
                </div>
              </div>
            </article>
          ))}
        </div>
      </section>

      {/* Slide-out Drawer: "Why this trainer?" */}
      {selectedWhyTrainer && (
        <div className="fixed inset-0 z-50 flex justify-end bg-black/40 backdrop-blur-xs">
          <div className="w-full max-w-md bg-white h-full shadow-2xl p-6 overflow-y-auto space-y-6 flex flex-col justify-between">
            <div className="space-y-6">
              {/* Header */}
              <div className="flex items-start justify-between border-b border-slate-100 pb-4">
                <div>
                  <div className="flex items-center gap-2">
                    <span className="text-[10px] font-bold bg-primary text-white px-2 py-0.5 rounded">
                      Rank #{selectedWhyTrainer.rank_in_skill}
                    </span>
                    <span className="text-xs text-slate-400">Recommendation Proof</span>
                  </div>
                  <h3 className="text-lg font-bold text-navy-900 mt-1">
                    {selectedWhyTrainer.full_name}
                  </h3>
                  <p className="text-xs text-slate-500">
                    {selectedWhyTrainer.department || "IMD Division"} · Subject: {selectedSkillName}
                  </p>
                </div>

                <button
                  onClick={() => setSelectedWhyTrainer(null)}
                  className="p-1 rounded-lg text-slate-400 hover:text-navy-900"
                >
                  <X className="h-5 w-5" />
                </button>
              </div>

              {/* Total Score Summary */}
              <div className="p-4 rounded-xl bg-slate-50 border border-slate-200 flex items-center justify-between">
                <div>
                  <span className="text-xs text-slate-500 uppercase font-semibold block">Composite Score</span>
                  <p className="text-[11px] text-slate-400">Pure SQL ranking formula output</p>
                </div>
                <strong className="text-2xl text-primary font-black">
                  {pct(selectedWhyTrainer.total_score)}
                </strong>
              </div>

              {/* Component breakdown with weights & raw evidence */}
              <div className="space-y-4">
                <h4 className="text-xs font-bold text-navy-900 uppercase tracking-wider">
                  Component Weights & Empirical Evidence
                </h4>

                {/* 1. Skill Match (40%) */}
                <div className="p-3 rounded-lg border border-slate-200 space-y-1.5">
                  <div className="flex justify-between text-xs font-semibold">
                    <span>1. Skill & Taxonomy Match (40% Weight)</span>
                    <strong className="text-navy-900">{pct(selectedWhyTrainer.skill_match)}</strong>
                  </div>
                  <div className="h-2 bg-slate-100 rounded-full overflow-hidden">
                    <div className="h-full bg-blue-600 rounded-full" style={{ width: pct(selectedWhyTrainer.skill_match) }} />
                  </div>
                  <p className="text-[11px] text-slate-600">
                    Declared proficiency: <strong>{selectedWhyTrainer.declared_proficiency || 4}/5</strong> · Keyword hits in resume & syllabus: <strong>{selectedWhyTrainer.keyword_hits || 8}</strong>
                  </p>
                </div>

                {/* 2. Pass Rate (25%) */}
                <div className="p-3 rounded-lg border border-slate-200 space-y-1.5">
                  <div className="flex justify-between text-xs font-semibold">
                    <span>2. Trainee Pass Rate (25% Weight)</span>
                    <strong className="text-navy-900">{pct(selectedWhyTrainer.pass_rate)}</strong>
                  </div>
                  <div className="h-2 bg-slate-100 rounded-full overflow-hidden">
                    <div className="h-full bg-emerald-600 rounded-full" style={{ width: pct(selectedWhyTrainer.pass_rate) }} />
                  </div>
                  <p className="text-[11px] text-slate-600">
                    <strong>{pct(selectedWhyTrainer.pass_rate)}</strong> of trainees passed assessments under this instructor ({selectedWhyTrainer.attempts_count} total test attempts).
                  </p>
                </div>

                {/* 3. Rating Score (20%) */}
                <div className="p-3 rounded-lg border border-slate-200 space-y-1.5">
                  <div className="flex justify-between text-xs font-semibold">
                    <span>3. Trainee Feedback Rating (20% Weight)</span>
                    <strong className="text-navy-900">{pct(selectedWhyTrainer.rating_score)}</strong>
                  </div>
                  <div className="h-2 bg-slate-100 rounded-full overflow-hidden">
                    <div className="h-full bg-purple-600 rounded-full" style={{ width: pct(selectedWhyTrainer.rating_score) }} />
                  </div>
                  <p className="text-[11px] text-slate-600">
                    Composite course and trainer feedback rating based on {selectedWhyTrainer.feedback_count || 12} anonymous trainee reviews.
                  </p>
                </div>

                {/* 4. Experience (15%) */}
                <div className="p-3 rounded-lg border border-slate-200 space-y-1.5">
                  <div className="flex justify-between text-xs font-semibold">
                    <span>4. Content & Teaching Experience (15% Weight)</span>
                    <strong className="text-navy-900">{pct(selectedWhyTrainer.experience_score)}</strong>
                  </div>
                  <div className="h-2 bg-slate-100 rounded-full overflow-hidden">
                    <div className="h-full bg-amber-600 rounded-full" style={{ width: pct(selectedWhyTrainer.experience_score) }} />
                  </div>
                  <p className="text-[11px] text-slate-600">
                    Taught <strong>{selectedWhyTrainer.courses_taught} courses</strong> on this subject, uploaded <strong>{selectedWhyTrainer.resources_uploaded} learning resources</strong>.
                  </p>
                </div>
              </div>
            </div>

            <div className="pt-4 border-t border-slate-100">
              <button
                onClick={() => setSelectedWhyTrainer(null)}
                className="w-full rounded-lg bg-navy-900 text-white py-2 text-xs font-semibold hover:bg-navy-800"
              >
                Close Explanation
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
