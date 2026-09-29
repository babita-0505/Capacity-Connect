"use client";

import React, { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import {
  BrainCircuit,
  TrendingUp,
  AlertTriangle,
  CheckCircle2,
  BookOpen,
  ArrowRight,
  Award,
  Sparkles
} from "lucide-react";
import { api } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

interface TraineeSkill {
  skill_id: number;
  skill: string;
  average_pct: number;
  level: "Beginner" | "Basic" | "Intermediate" | "Advanced" | "Expert";
  weak: boolean;
}

interface RecommendedCourse {
  course_id: string;
  title: string;
  weak_skill: string;
  avg_pct: number;
}

export default function TraineeSkillsPage() {
  const router = useRouter();
  const { user, loading: authLoading } = useAuth();

  const [skills, setSkills] = useState<TraineeSkill[]>([]);
  const [weakSkills, setWeakSkills] = useState<TraineeSkill[]>([]);
  const [recommended, setRecommended] = useState<RecommendedCourse[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!authLoading) {
      if (!user) {
        router.push("/login");
        return;
      }
      setLoading(true);
      api.competency
        .mine()
        .then((res: any) => {
          setSkills(res.skills || []);
          setWeakSkills(res.weak_skills || []);
          setRecommended(res.recommended_courses || []);
        })
        .catch(console.error)
        .finally(() => setLoading(false));
    }
  }, [user, authLoading, router]);

  const getLevelBadgeClass = (level: string) => {
    switch (level) {
      case "Expert":
        return "bg-purple-100 text-purple-800 border-purple-200";
      case "Advanced":
        return "bg-emerald-100 text-emerald-800 border-emerald-200";
      case "Intermediate":
        return "bg-blue-100 text-blue-800 border-blue-200";
      case "Basic":
        return "bg-amber-100 text-amber-800 border-amber-200";
      default:
        return "bg-rose-100 text-rose-800 border-rose-200";
    }
  };

  const getBarColor = (pct: number) => {
    if (pct >= 85) return "bg-purple-600";
    if (pct >= 75) return "bg-emerald-500";
    if (pct >= 60) return "bg-blue-500";
    if (pct >= 40) return "bg-amber-500";
    return "bg-rose-500";
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div>
        <h1 className="text-2xl font-bold text-navy-900 tracking-tight">My Meteorological Competencies</h1>
        <p className="text-sm text-slate-500">
          Objective evaluation of your technical skills computed directly from your timed test performance
        </p>
      </div>

      {loading ? (
        <div className="p-16 text-center text-slate-400 text-sm">Evaluating your skill profile...</div>
      ) : skills.length === 0 ? (
        <div className="bg-white rounded-xl p-12 text-center border border-slate-200 shadow-sm space-y-3">
          <BrainCircuit className="h-10 w-10 text-slate-300 mx-auto" />
          <h3 className="font-bold text-slate-700">No competency records evaluated yet</h3>
          <p className="text-xs text-slate-500 max-w-sm mx-auto">
            Take subject-wise assessments or complete course modules to measure your skills and benchmark proficiency.
          </p>
          <Link
            href="/assessments"
            className="inline-flex items-center gap-1.5 rounded-lg bg-primary py-2 px-4 text-xs font-semibold text-white shadow-sm"
          >
            Go to Assessments
          </Link>
        </div>
      ) : (
        <div className="space-y-6">
          {/* Summary Cards */}
          <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
            <div className="bg-white p-5 rounded-xl border border-slate-200 shadow-xs space-y-1">
              <span className="text-xs uppercase font-bold text-slate-400 block">Tested Subjects</span>
              <strong className="text-2xl text-navy-900 font-extrabold">{skills.length}</strong>
              <p className="text-[11px] text-slate-500">Evaluated across IMD curriculum</p>
            </div>

            <div className="bg-white p-5 rounded-xl border border-slate-200 shadow-xs space-y-1">
              <span className="text-xs uppercase font-bold text-slate-400 block">Competent (60%+)</span>
              <strong className="text-2xl text-emerald-700 font-extrabold">
                {skills.filter((s) => !s.weak).length}
              </strong>
              <p className="text-[11px] text-slate-500">Eligible for operational deployments</p>
            </div>

            <div className="bg-white p-5 rounded-xl border border-slate-200 shadow-xs space-y-1">
              <span className="text-xs uppercase font-bold text-slate-400 block">Needs Training (&lt;60%)</span>
              <strong className="text-2xl text-amber-700 font-extrabold">{weakSkills.length}</strong>
              <p className="text-[11px] text-slate-500">Recommended for refresher courses</p>
            </div>
          </div>

          {/* Skill Proficiency Bars */}
          <div className="bg-white rounded-xl border border-slate-200 p-6 shadow-sm space-y-6">
            <div className="flex items-center justify-between border-b border-slate-100 pb-3">
              <h2 className="text-base font-bold text-navy-900">Assessed Disciplines & Proficiency Levels</h2>
              <span className="text-xs text-slate-400">Target Standard: 60%</span>
            </div>

            <div className="space-y-5">
              {skills.map((s) => (
                <div key={s.skill_id} className="space-y-2">
                  <div className="flex items-center justify-between text-xs font-semibold">
                    <div className="flex items-center gap-2">
                      <span className="text-slate-900 text-sm font-bold">{s.skill}</span>
                      <span
                        className={`text-[10px] font-bold px-2 py-0.5 rounded border capitalize ${getLevelBadgeClass(
                          s.level
                        )}`}
                      >
                        {s.level}
                      </span>
                      {s.weak && (
                        <span className="text-[10px] font-bold text-amber-700 bg-amber-50 border border-amber-200 px-2 py-0.5 rounded flex items-center gap-0.5">
                          <AlertTriangle className="h-3 w-3" /> Gap Identified
                        </span>
                      )}
                    </div>
                    <strong className="text-navy-900 text-sm">{s.average_pct}%</strong>
                  </div>

                  <div className="h-2.5 bg-slate-100 rounded-full overflow-hidden">
                    <div
                      className={`h-full rounded-full transition-all duration-500 ${getBarColor(
                        s.average_pct
                      )}`}
                      style={{ width: `${s.average_pct}%` }}
                    />
                  </div>
                </div>
              ))}
            </div>
          </div>

          {/* Targeted Learning Path / Recommended Courses */}
          {recommended.length > 0 && (
            <div className="bg-white rounded-xl border border-slate-200 p-6 shadow-sm space-y-4">
              <div className="flex items-center gap-2">
                <Sparkles className="h-5 w-5 text-primary" />
                <div>
                  <h2 className="text-base font-bold text-navy-900">Personalized Learning Recommendations</h2>
                  <p className="text-xs text-slate-500">
                    Courses matched from IMD learning paths to help you strengthen identified competency gaps
                  </p>
                </div>
              </div>

              <div className="grid grid-cols-1 md:grid-cols-2 gap-4 pt-2">
                {recommended.map((rc) => (
                  <div
                    key={rc.course_id}
                    className="p-4 rounded-xl border border-slate-200 bg-slate-50/50 space-y-3 flex flex-col justify-between hover:border-slate-300 transition-colors"
                  >
                    <div className="space-y-1.5">
                      <span className="text-[10px] font-bold text-amber-800 bg-amber-100 px-2 py-0.5 rounded">
                        Targeting: {rc.weak_skill} (Your score: {rc.avg_pct}%, Target: 60%)
                      </span>
                      <h3 className="font-bold text-navy-900 text-sm leading-snug">{rc.title}</h3>
                    </div>

                    <div className="pt-2 border-t border-slate-200 flex justify-end">
                      <Link
                        href={`/courses/${rc.course_id}`}
                        className="inline-flex items-center gap-1 text-xs font-bold text-primary hover:text-primary-hover"
                      >
                        Enroll in Course <ArrowRight className="h-3.5 w-3.5" />
                      </Link>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
