"use client";

import React, { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import {
  Award,
  Clock,
  CheckCircle2,
  AlertCircle,
  Play,
  ArrowRight,
  BookOpen,
  Calendar,
  ShieldAlert
} from "lucide-react";
import { api, TraineeAssessmentItem } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function MyAssessmentsPage() {
  const router = useRouter();
  const { user, loading: authLoading } = useAuth();

  const [assessments, setAssessments] = useState<TraineeAssessmentItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState<"all" | "available" | "completed">("all");

  const loadAssessments = async () => {
    try {
      setLoading(true);
      const res = await api.assessments.myAssessments();
      setAssessments(res.items);
    } catch (err: any) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (!authLoading) {
      if (!user) {
        router.push("/login");
        return;
      }
      if (user.role !== "trainee" && user.role !== "admin") {
        router.push("/unauthorized");
        return;
      }
      loadAssessments();
    }
  }, [user, authLoading]);

  const filtered = assessments.filter((a) => {
    if (filter === "available") return a.can_start;
    if (filter === "completed") return a.last_attempt_status && a.last_attempt_status !== "in_progress";
    return true;
  });

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-navy-900 tracking-tight">My Assessments</h1>
          <p className="text-sm text-slate-500">
            Subject-wise evaluations, course completion quizzes, and competency tests
          </p>
        </div>

        {/* Filter Tabs */}
        <div className="flex items-center gap-1.5 bg-slate-100 p-1 rounded-lg">
          <button
            onClick={() => setFilter("all")}
            className={`px-3 py-1.5 text-xs font-semibold rounded-md transition-colors ${
              filter === "all" ? "bg-white text-navy-900 shadow-xs" : "text-slate-600 hover:text-navy-900"
            }`}
          >
            All ({assessments.length})
          </button>
          <button
            onClick={() => setFilter("available")}
            className={`px-3 py-1.5 text-xs font-semibold rounded-md transition-colors ${
              filter === "available" ? "bg-white text-navy-900 shadow-xs" : "text-slate-600 hover:text-navy-900"
            }`}
          >
            Available ({assessments.filter((a) => a.can_start).length})
          </button>
          <button
            onClick={() => setFilter("completed")}
            className={`px-3 py-1.5 text-xs font-semibold rounded-md transition-colors ${
              filter === "completed" ? "bg-white text-navy-900 shadow-xs" : "text-slate-600 hover:text-navy-900"
            }`}
          >
            Completed ({assessments.filter((a) => a.last_attempt_status && a.last_attempt_status !== "in_progress").length})
          </button>
        </div>
      </div>

      {loading ? (
        <div className="p-12 text-center text-slate-500 text-sm">Loading your assessments...</div>
      ) : filtered.length === 0 ? (
        <div className="bg-white rounded-xl p-12 text-center border border-slate-200 shadow-sm space-y-3">
          <Award className="h-10 w-10 text-slate-300 mx-auto" />
          <h3 className="font-bold text-slate-700">No assessments found</h3>
          <p className="text-xs text-slate-500 max-w-sm mx-auto">
            {filter === "available"
              ? "You have completed all open assessments or reached maximum attempt limits."
              : "Enroll in courses from the catalogue to unlock module quizzes and certification tests."}
          </p>
          <Link
            href="/courses"
            className="inline-flex items-center gap-1.5 rounded-lg bg-primary py-2 px-4 text-xs font-semibold text-white shadow-sm"
          >
            Explore Courses
          </Link>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
          {filtered.map((item) => {
            const hasAttempted = item.my_attempts_count > 0;
            const inProgress = item.last_attempt_status === "in_progress";
            const passed = item.last_passed;

            return (
              <div
                key={item.id}
                className="bg-white rounded-xl border border-slate-200 p-5 shadow-sm hover:shadow-md transition-shadow flex flex-col justify-between space-y-4"
              >
                <div className="space-y-3">
                  <div className="flex items-start justify-between gap-2">
                    <div className="flex flex-wrap items-center gap-2">
                      {item.skill_name && (
                        <span className="text-[10px] font-bold text-navy-900 bg-slate-100 px-2.5 py-0.5 rounded">
                          {item.skill_name}
                        </span>
                      )}
                      {item.course_title ? (
                        <span className="text-[10px] font-semibold text-primary bg-blue-50 px-2 py-0.5 rounded truncate max-w-[200px]">
                          {item.course_title}
                        </span>
                      ) : (
                        <span className="text-[10px] font-semibold text-purple-700 bg-purple-50 px-2 py-0.5 rounded">
                          Standalone Test
                        </span>
                      )}
                    </div>

                    {/* Status Badge */}
                    {inProgress ? (
                      <span className="text-[10px] font-bold px-2 py-0.5 rounded bg-amber-100 text-amber-800">
                        In Progress
                      </span>
                    ) : hasAttempted ? (
                      passed ? (
                        <span className="text-[10px] font-bold px-2 py-0.5 rounded bg-emerald-100 text-emerald-800 flex items-center gap-1">
                          <CheckCircle2 className="h-3 w-3" /> Passed ({item.last_percentage}%)
                        </span>
                      ) : (
                        <span className="text-[10px] font-bold px-2 py-0.5 rounded bg-red-100 text-red-800">
                          Score: {item.last_percentage}% (Required: {item.pass_pct}%)
                        </span>
                      )
                    ) : (
                      <span className="text-[10px] font-semibold px-2 py-0.5 rounded bg-slate-100 text-slate-600">
                        Not Attempted
                      </span>
                    )}
                  </div>

                  <h3 className="font-bold text-navy-900 text-base leading-snug">
                    {item.title}
                  </h3>

                  {item.instructions && (
                    <p className="text-xs text-slate-500 line-clamp-2 leading-relaxed">
                      {item.instructions}
                    </p>
                  )}

                  {/* Metadata Row */}
                  <div className="pt-2 border-t border-slate-100 grid grid-cols-2 gap-2 text-xs text-slate-500">
                    <div className="flex items-center gap-1.5">
                      <Clock className="h-3.5 w-3.5 text-slate-400" />
                      <span>{item.duration_minutes ? `${item.duration_minutes} Mins` : "Untimed"}</span>
                    </div>

                    <div className="flex items-center gap-1.5">
                      <BookOpen className="h-3.5 w-3.5 text-slate-400" />
                      <span>{item.question_count || 10} Questions</span>
                    </div>

                    <div className="flex items-center gap-1.5">
                      <Award className="h-3.5 w-3.5 text-slate-400" />
                      <span>Pass: {item.pass_pct}%</span>
                    </div>

                    <div className="flex items-center gap-1.5">
                      <span>Attempts: {item.my_attempts_count} / {item.max_attempts}</span>
                    </div>

                    {item.deadline_at && (
                      <div className="col-span-2 flex items-center gap-1.5 text-slate-500 text-[11px]">
                        <Calendar className="h-3.5 w-3.5 text-slate-400" />
                        <span>Deadline: {new Date(item.deadline_at).toLocaleDateString()}</span>
                      </div>
                    )}
                  </div>
                </div>

                {/* Card Actions */}
                <div className="pt-3 border-t border-slate-100 flex items-center justify-between">
                  {item.lockdown_enabled && (
                    <span className="inline-flex items-center gap-1 text-[10px] font-medium text-slate-400">
                      <ShieldAlert className="h-3 w-3" /> Monitored
                    </span>
                  )}

                  <div className="flex items-center gap-2 ml-auto">
                    {hasAttempted && item.last_attempt_id && item.last_attempt_status !== "in_progress" && (
                      <Link
                        href={`/assessments/${item.id}/result?attempt_id=${item.last_attempt_id}`}
                        className="inline-flex items-center gap-1 rounded-lg border border-slate-300 bg-white hover:bg-slate-50 px-3 py-1.5 text-xs font-semibold text-slate-700 transition-colors"
                      >
                        View Result
                      </Link>
                    )}

                    {item.can_start && (
                      <Link
                        href={`/assessments/${item.id}`}
                        className={`inline-flex items-center gap-1.5 rounded-lg px-4 py-1.5 text-xs font-semibold text-white shadow-sm transition-colors ${
                          inProgress
                            ? "bg-amber-600 hover:bg-amber-700"
                            : "bg-primary hover:bg-primary-hover"
                        }`}
                      >
                        <Play className="h-3.5 w-3.5 fill-current" />
                        {inProgress ? "Resume Test" : "Start Test"}
                      </Link>
                    )}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
