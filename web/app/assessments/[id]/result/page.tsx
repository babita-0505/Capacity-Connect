"use client";

import React, { useEffect, useState } from "react";
import Link from "next/link";
import { useSearchParams, useParams } from "next/navigation";
import {
  CheckCircle2,
  XCircle,
  Award,
  ArrowLeft,
  ShieldAlert,
  BarChart3,
  BookOpen
} from "lucide-react";
import { api, AttemptResultResponse } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function AssessmentResultPage() {
  const params = useParams();
  const searchParams = useSearchParams();
  const assessmentId = params.id as string;
  const attemptId = searchParams.get("attempt_id");
  const { user, loading: authLoading } = useAuth();

  const [resultData, setResultData] = useState<AttemptResultResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!authLoading) {
      if (!attemptId) {
        setError("Attempt ID is missing in request");
        setLoading(false);
        return;
      }
      setLoading(true);
      api.assessments.getResult(attemptId)
        .then(setResultData)
        .catch((err) => setError(err.message || "Failed to load result"))
        .finally(() => setLoading(false));
    }
  }, [attemptId, authLoading]);

  if (loading || authLoading) {
    return (
      <div className="flex flex-col items-center justify-center p-20 space-y-3">
        <div className="h-8 w-8 animate-spin rounded-full border-4 border-primary border-t-transparent"></div>
        <p className="text-xs text-slate-500">Calculating assessment evaluation...</p>
      </div>
    );
  }

  if (error || !resultData) {
    return (
      <div className="max-w-md mx-auto my-12 p-6 bg-white rounded-xl border border-slate-200 text-center space-y-4">
        <h2 className="text-base font-bold text-navy-900">Result Not Available</h2>
        <p className="text-xs text-slate-500">{error || "The assessment results could not be retrieved."}</p>
        <Link
          href="/assessments"
          className="inline-flex items-center gap-1.5 rounded-lg bg-navy-900 text-white px-4 py-2 text-xs font-semibold"
        >
          <ArrowLeft className="h-4 w-4" /> Return to My Assessments
        </Link>
      </div>
    );
  }

  const { attempt, answers } = resultData;
  const passed = attempt.passed;

  return (
    <div className="max-w-3xl mx-auto space-y-6 pb-12">
      {/* Top Banner Navigation */}
      <div>
        <Link
          href="/assessments"
          className="inline-flex items-center gap-1 text-xs font-semibold text-slate-500 hover:text-navy-900"
        >
          <ArrowLeft className="h-4 w-4" /> Back to My Assessments
        </Link>
      </div>

      {/* Primary Score Card */}
      <div
        className={`rounded-2xl p-6 sm:p-8 border shadow-sm space-y-6 ${
          passed
            ? "bg-gradient-to-br from-emerald-900 to-teal-950 text-white border-emerald-800"
            : "bg-white text-navy-900 border-slate-200"
        }`}
      >
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
          <div className="space-y-1">
            <span
              className={`text-[10px] font-bold uppercase tracking-wider px-2.5 py-0.5 rounded ${
                passed ? "bg-emerald-800 text-emerald-200" : "bg-red-100 text-red-700"
              }`}
            >
              {passed ? "Assessment Passed" : "Needs Improvement"}
            </span>
            <h1 className="text-2xl font-extrabold tracking-tight">
              {attempt.title}
            </h1>
            {attempt.course_title && (
              <p className={passed ? "text-emerald-200 text-xs" : "text-slate-500 text-xs"}>
                Associated with: {attempt.course_title}
              </p>
            )}
          </div>

          <div className="flex items-center gap-3">
            <div
              className={`h-20 w-20 rounded-2xl flex flex-col items-center justify-center font-bold ${
                passed
                  ? "bg-white text-emerald-800 shadow-md"
                  : "bg-red-50 text-red-600 border border-red-200"
              }`}
            >
              <span className="text-2xl leading-none">{attempt.percentage}%</span>
              <span className="text-[10px] uppercase font-semibold mt-1">Score</span>
            </div>
          </div>
        </div>

        {/* Detailed Stats Row */}
        <div
          className={`grid grid-cols-2 sm:grid-cols-4 gap-3 p-4 rounded-xl text-xs ${
            passed ? "bg-white/10 text-slate-200" : "bg-slate-50 text-slate-600 border border-slate-200"
          }`}
        >
          <div>
            <span className="block text-[10px] uppercase opacity-75">Points Earned</span>
            <strong className="text-sm font-bold">{attempt.score} / {attempt.max_score}</strong>
          </div>
          <div>
            <span className="block text-[10px] uppercase opacity-75">Passing Mark</span>
            <strong className="text-sm font-bold">{attempt.required_pass_pct}%</strong>
          </div>
          <div>
            <span className="block text-[10px] uppercase opacity-75">Attempt #</span>
            <strong className="text-sm font-bold">{attempt.attempt_no}</strong>
          </div>
          <div>
            <span className="block text-[10px] uppercase opacity-75">Submitted At</span>
            <strong className="text-sm font-bold">
              {new Date(attempt.submitted_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}
            </strong>
          </div>
        </div>

        {/* Proctoring notice if tab switches were detected */}
        {(attempt.tab_switch_count > 0 || attempt.fullscreen_exits > 0) && (
          <div
            className={`p-3 rounded-lg text-xs flex items-center gap-2 ${
              passed
                ? "bg-amber-950/60 text-amber-200 border border-amber-800"
                : "bg-amber-50 text-amber-800 border border-amber-200"
            }`}
          >
            <ShieldAlert className="h-4 w-4 flex-shrink-0" />
            <span>
              Proctor monitoring recorded {attempt.tab_switch_count} tab switches and {attempt.fullscreen_exits} full-screen exits during this session.
            </span>
          </div>
        )}

        {/* CTA Actions */}
        <div className="flex flex-wrap items-center gap-3 pt-2">
          {attempt.course_id && (
            <Link
              href={`/courses/${attempt.course_id}/learn`}
              className={`inline-flex items-center gap-1.5 rounded-lg px-4 py-2 text-xs font-semibold transition-colors ${
                passed
                  ? "bg-white text-emerald-900 hover:bg-emerald-50"
                  : "bg-navy-900 text-white hover:bg-navy-800"
              }`}
            >
              <BookOpen className="h-3.5 w-3.5" /> Return to Course Player
            </Link>
          )}

          <Link
            href="/assessments"
            className={`inline-flex items-center gap-1.5 rounded-lg px-4 py-2 text-xs font-semibold transition-colors ${
              passed
                ? "bg-white/20 text-white hover:bg-white/30"
                : "border border-slate-300 text-slate-700 hover:bg-slate-50"
            }`}
          >
            <BarChart3 className="h-3.5 w-3.5" /> All Assessments
          </Link>
        </div>
      </div>

      {/* Answer Review Section */}
      <div className="space-y-4">
        <h2 className="text-base font-bold text-navy-900 flex items-center gap-2">
          <span>Question-by-Question Review</span>
          <span className="text-xs font-normal text-slate-500">
            ({answers.filter(a => a.is_correct).length} of {answers.length} correct)
          </span>
        </h2>

        <div className="space-y-3">
          {answers.map((item, idx) => {
            const isCorrect = item.is_correct;
            return (
              <div
                key={item.question_id || idx}
                className={`p-4 rounded-xl border bg-white space-y-3 ${
                  isCorrect ? "border-slate-200" : "border-red-200 bg-red-50/20"
                }`}
              >
                <div className="flex items-start justify-between gap-3">
                  <div className="flex items-start gap-2.5">
                    {isCorrect ? (
                      <CheckCircle2 className="h-4 w-4 text-emerald-600 mt-0.5 flex-shrink-0" />
                    ) : (
                      <XCircle className="h-4 w-4 text-red-500 mt-0.5 flex-shrink-0" />
                    )}
                    <h3 className="text-xs sm:text-sm font-semibold text-slate-900 leading-snug">
                      <span className="text-slate-400 mr-1.5">Q{idx + 1}.</span>
                      {item.text}
                    </h3>
                  </div>
                  <span
                    className={`text-[10px] font-bold px-2 py-0.5 rounded flex-shrink-0 ${
                      isCorrect ? "bg-emerald-100 text-emerald-800" : "bg-red-100 text-red-800"
                    }`}
                  >
                    {item.marks_awarded > 0 ? `+${item.marks_awarded} pts` : "0 pts"}
                  </span>
                </div>

                <div className="pl-6 space-y-1.5 text-xs">
                  {item.user_answer && (
                    <div className="flex items-start gap-2">
                      <span className="text-slate-400 font-medium">Your answer:</span>
                      <span className={isCorrect ? "text-emerald-700 font-semibold" : "text-red-700 line-through font-semibold"}>
                        {item.user_answer}
                      </span>
                    </div>
                  )}

                  {!isCorrect && item.correct_answer && (
                    <div className="flex items-start gap-2">
                      <span className="text-slate-400 font-medium">Correct answer:</span>
                      <span className="text-emerald-800 font-semibold">
                        {item.correct_answer}
                      </span>
                    </div>
                  )}

                  {item.explanation && (
                    <div className="mt-2 pt-2 border-t border-slate-100 text-slate-600 bg-slate-50 p-2.5 rounded-lg text-[11px] leading-relaxed">
                      <strong className="text-slate-700">Explanation: </strong>
                      {item.explanation}
                    </div>
                  )}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
