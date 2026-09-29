"use client";

import React, { useEffect, useState, useRef, useCallback } from "react";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import {
  Clock,
  AlertTriangle,
  CheckCircle2,
  HelpCircle,
  Maximize2,
  ChevronLeft,
  ChevronRight,
  ShieldAlert,
  Send,
  ArrowLeft
} from "lucide-react";
import { api, Assessment, AttemptStartResponse } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function TestTakingPage() {
  const params = useParams();
  const router = useRouter();
  const assessmentId = params.id as string;
  const { user, loading: authLoading } = useAuth();

  const [assessment, setAssessment] = useState<Assessment | null>(null);
  const [attemptData, setAttemptData] = useState<AttemptStartResponse | null>(null);
  const [loading, setLoading] = useState(true);
  const [starting, setStarting] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [savingAnswer, setSavingAnswer] = useState(false);
  const [saveStatus, setSaveStatus] = useState<"idle" | "saving" | "saved">("idle");
  const [error, setError] = useState<string | null>(null);

  // Active question index (0-based)
  const [currentIndex, setCurrentIndex] = useState(0);
  // Map of question_id -> selected_option_id
  const [answers, setAnswers] = useState<Record<string, string>>({});
  // Proctor warnings
  const [tabSwitches, setTabSwitches] = useState(0);
  const [showWarning, setShowWarning] = useState(false);
  const [warningText, setWarningText] = useState("");
  // Confirm submission modal
  const [showConfirmModal, setShowConfirmModal] = useState(false);
  // Time remaining in seconds
  const [timeLeft, setTimeLeft] = useState<number | null>(null);

  const timerRef = useRef<NodeJS.Timeout | null>(null);

  // Load Assessment metadata
  useEffect(() => {
    if (!authLoading) {
      if (!user) {
        router.push("/login");
        return;
      }
      setLoading(true);
      api.assessments.get(assessmentId)
        .then(setAssessment)
        .catch((err) => setError(err.message || "Failed to load assessment"))
        .finally(() => setLoading(false));
    }
  }, [assessmentId, user, authLoading, router]);

  // Start attempt
  const handleStartTest = async () => {
    try {
      setStarting(true);
      setError(null);

      // Attempt fullscreen
      try {
        if (document.documentElement.requestFullscreen) {
          await document.documentElement.requestFullscreen();
        }
      } catch (e) {
        console.warn("Fullscreen request declined", e);
      }

      const res = await api.assessments.start(assessmentId);
      setAttemptData(res);

      // Pre-fill any previously saved answers
      const initial: Record<string, string> = {};
      if (res.saved_answers) {
        Object.entries(res.saved_answers).forEach(([qid, optList]) => {
          if (optList && optList.length > 0) {
            initial[qid] = optList[0];
          }
        });
      }
      setAnswers(initial);

      // Calculate time remaining
      const expiryTime = new Date(res.expires_at).getTime();
      const now = Date.now();
      const diffSecs = Math.max(0, Math.floor((expiryTime - now) / 1000));
      setTimeLeft(diffSecs);
    } catch (err: any) {
      setError(err.message || "Could not start assessment");
    } finally {
      setStarting(false);
    }
  };

  // Submit attempt callback
  const submitTest = useCallback(async () => {
    if (!attemptData || submitting) return;
    try {
      setSubmitting(true);
      if (timerRef.current) clearInterval(timerRef.current);

      await api.assessments.submit(attemptData.attempt_id);

      // Exit fullscreen if active
      if (document.fullscreenElement && document.exitFullscreen) {
        document.exitFullscreen().catch(() => {});
      }

      router.push(`/assessments/${assessmentId}/result?attempt_id=${attemptData.attempt_id}`);
    } catch (err: any) {
      alert(err.message || "Failed to submit assessment");
      setSubmitting(false);
    }
  }, [attemptData, submitting, assessmentId, router]);

  // Timer countdown loop
  useEffect(() => {
    if (timeLeft === null || !attemptData) return;

    if (timeLeft <= 0) {
      // Auto-submit on time expired
      submitTest();
      return;
    }

    timerRef.current = setInterval(() => {
      setTimeLeft((prev) => {
        if (prev === null || prev <= 1) {
          if (timerRef.current) clearInterval(timerRef.current);
          submitTest();
          return 0;
        }
        return prev - 1;
      });
    }, 1000);

    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [attemptData, submitTest]);

  // Proctoring events listeners
  useEffect(() => {
    if (!attemptData || !attemptData.lockdown_enabled) return;

    const handleVisibilityChange = () => {
      if (document.visibilityState === "hidden") {
        triggerProctorEvent("blur", "Tab switch or window blur detected!");
      }
    };

    const handleFullscreenChange = () => {
      if (!document.fullscreenElement) {
        triggerProctorEvent("fullscreen_exit", "Exited full-screen mode!");
      }
    };

    const handleCopy = (e: ClipboardEvent) => {
      e.preventDefault();
      triggerProctorEvent("copy", "Copy/paste action blocked during assessment!");
    };

    const triggerProctorEvent = async (type: "blur" | "fullscreen_exit" | "copy", msg: string) => {
      setWarningText(msg);
      setShowWarning(true);
      try {
        const res = await api.assessments.sendEvent(attemptData.attempt_id, type);
        setTabSwitches(res.tab_switch_count);
      } catch (err) {
        console.error("Failed to log proctor event", err);
      }
      setTimeout(() => setShowWarning(false), 5000);
    };

    document.addEventListener("visibilitychange", handleVisibilityChange);
    document.addEventListener("fullscreenchange", handleFullscreenChange);
    document.addEventListener("copy", handleCopy);

    return () => {
      document.removeEventListener("visibilitychange", handleVisibilityChange);
      document.removeEventListener("fullscreenchange", handleFullscreenChange);
      document.removeEventListener("copy", handleCopy);
    };
  }, [attemptData]);

  // Save answer on option pick
  const handleSelectOption = async (questionId: string, optionId: string) => {
    if (!attemptData) return;

    const updated = { ...answers, [questionId]: optionId };
    setAnswers(updated);
    setSaveStatus("saving");
    setSavingAnswer(true);

    try {
      await api.assessments.saveAnswer(attemptData.attempt_id, questionId, [optionId]);
      setSaveStatus("saved");
    } catch (err) {
      console.error("Autosave answer error", err);
    } finally {
      setSavingAnswer(false);
      setTimeout(() => setSaveStatus("idle"), 1500);
    }
  };

  // Format seconds into MM:SS or HH:MM:SS
  const formatTime = (secs: number) => {
    const h = Math.floor(secs / 3600);
    const m = Math.floor((secs % 3600) / 60);
    const s = secs % 60;
    if (h > 0) {
      return `${h}:${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
    }
    return `${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
  };

  if (loading || authLoading) {
    return (
      <div className="flex flex-col items-center justify-center p-20 space-y-3">
        <div className="h-8 w-8 animate-spin rounded-full border-4 border-primary border-t-transparent"></div>
        <p className="text-xs text-slate-500">Preparing assessment session...</p>
      </div>
    );
  }

  if (error || !assessment) {
    return (
      <div className="max-w-md mx-auto my-12 p-6 bg-white rounded-xl border border-slate-200 text-center space-y-4">
        <AlertTriangle className="h-10 w-10 text-amber-500 mx-auto" />
        <h2 className="text-base font-bold text-navy-900">Assessment Error</h2>
        <p className="text-xs text-slate-600 leading-relaxed">{error || "Assessment could not be loaded."}</p>
        <Link
          href="/assessments"
          className="inline-flex items-center gap-1.5 rounded-lg bg-navy-900 text-white px-4 py-2 text-xs font-semibold"
        >
          <ArrowLeft className="h-4 w-4" /> Return to Assessments
        </Link>
      </div>
    );
  }

  // Pre-test welcome / instruction screen
  if (!attemptData) {
    return (
      <div className="max-w-2xl mx-auto space-y-6 py-6">
        <div className="bg-white rounded-2xl border border-slate-200 shadow-sm p-6 sm:p-8 space-y-6">
          <div className="space-y-2">
            <div className="flex flex-wrap items-center gap-2">
              <span className="text-[10px] font-bold text-primary bg-blue-50 px-2.5 py-0.5 rounded uppercase">
                {assessment.skill_name || "Meteorology"}
              </span>
              {assessment.course_title && (
                <span className="text-[10px] font-semibold text-slate-600 bg-slate-100 px-2 py-0.5 rounded">
                  {assessment.course_title}
                </span>
              )}
            </div>
            <h1 className="text-2xl font-extrabold text-navy-900 tracking-tight">
              {assessment.title}
            </h1>
            {assessment.instructions && (
              <p className="text-xs sm:text-sm text-slate-600 leading-relaxed pt-1">
                {assessment.instructions}
              </p>
            )}
          </div>

          {/* Test rules & specifications */}
          <div className="rounded-xl bg-slate-50 border border-slate-200 p-4 space-y-3">
            <h3 className="text-xs font-bold text-slate-700 uppercase tracking-wide">
              Test Guidelines & Security Policy
            </h3>
            <div className="grid grid-cols-2 gap-3 text-xs text-slate-600">
              <div className="flex items-center gap-2">
                <Clock className="h-4 w-4 text-slate-400" />
                <span>Duration: <strong>{assessment.duration_minutes ? `${assessment.duration_minutes} minutes` : "Untimed"}</strong></span>
              </div>
              <div className="flex items-center gap-2">
                <CheckCircle2 className="h-4 w-4 text-emerald-600" />
                <span>Pass Threshold: <strong>{assessment.pass_pct}%</strong></span>
              </div>
              <div className="flex items-center gap-2">
                <HelpCircle className="h-4 w-4 text-slate-400" />
                <span>Total Questions: <strong>{assessment.question_count || 10}</strong></span>
              </div>
              <div className="flex items-center gap-2">
                <ShieldAlert className="h-4 w-4 text-amber-600" />
                <span>Monitoring: <strong>{assessment.lockdown_enabled ? "Lockdown Active" : "Standard"}</strong></span>
              </div>
            </div>

            {assessment.lockdown_enabled && (
              <p className="text-[11px] text-amber-800 bg-amber-50 border border-amber-200 p-2.5 rounded-lg leading-relaxed">
                <strong>Notice:</strong> Browser activity is monitored. Switching tabs, exiting full-screen, or copying content will be recorded in the test log and visible to your evaluator.
              </p>
            )}
          </div>

          <div className="flex flex-wrap items-center justify-between gap-4 pt-2">
            <Link
              href="/assessments"
              className="text-xs font-semibold text-slate-500 hover:text-navy-900"
            >
              Cancel and return
            </Link>

            <button
              onClick={handleStartTest}
              disabled={starting}
              className="inline-flex items-center gap-2 rounded-lg bg-primary hover:bg-primary-hover px-6 py-2.5 text-xs font-bold text-white shadow-md transition-all disabled:opacity-50"
            >
              <Maximize2 className="h-4 w-4" />
              {starting ? "Starting session..." : "Start Assessment Now"}
            </button>
          </div>
        </div>
      </div>
    );
  }

  // Active Test-Taking Screen
  const questions = attemptData.questions || [];
  const currentQuestion = questions[currentIndex];
  const totalQuestions = questions.length;
  const answeredCount = Object.keys(answers).length;
  const isTimeCritical = timeLeft !== null && timeLeft < 300; // < 5 mins

  return (
    <div className="max-w-4xl mx-auto space-y-4 pb-12">
      {/* Proctoring Warning Banner */}
      {showWarning && (
        <div className="sticky top-2 z-50 rounded-xl bg-red-600 text-white p-3 text-xs font-bold flex items-center justify-between shadow-lg animate-pulse">
          <div className="flex items-center gap-2">
            <AlertTriangle className="h-4 w-4" />
            <span>{warningText}</span>
          </div>
          <span className="bg-white/20 px-2 py-0.5 rounded text-[10px]">
            Tab switches: {tabSwitches}
          </span>
        </div>
      )}

      {/* Top Test Header Bar */}
      <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-4 flex items-center justify-between gap-4">
        <div>
          <span className="text-[10px] font-bold text-slate-400 uppercase tracking-wider block">
            {assessment.title}
          </span>
          <h2 className="text-sm font-bold text-navy-900">
            Question {currentIndex + 1} of {totalQuestions}
          </h2>
        </div>

        {/* Center: Save Indicator */}
        <div className="hidden sm:block text-[11px] text-slate-400">
          {saveStatus === "saving" ? (
            <span className="text-amber-600 font-medium">Autosaving...</span>
          ) : saveStatus === "saved" ? (
            <span className="text-emerald-600 font-medium">Progress saved ✓</span>
          ) : (
            <span>All changes saved</span>
          )}
        </div>

        {/* Right: Countdown Timer & Submit Button */}
        <div className="flex items-center gap-3">
          {timeLeft !== null && (
            <div
              className={`flex items-center gap-1.5 px-3 py-1.5 rounded-lg font-mono font-bold text-xs ${
                isTimeCritical
                  ? "bg-red-50 text-red-600 border border-red-200 animate-pulse"
                  : "bg-slate-100 text-slate-700"
              }`}
            >
              <Clock className="h-3.5 w-3.5" />
              <span>{formatTime(timeLeft)}</span>
            </div>
          )}

          <button
            onClick={() => setShowConfirmModal(true)}
            className="rounded-lg bg-emerald-600 hover:bg-emerald-700 px-3.5 py-1.5 text-xs font-bold text-white shadow-sm transition-colors"
          >
            Finish & Submit
          </button>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-4 gap-6">
        {/* Main Question Card (Left 3 columns) */}
        <div className="md:col-span-3 space-y-4">
          {currentQuestion ? (
            <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-6 space-y-6">
              {/* Question Text */}
              <div className="space-y-2">
                <div className="flex items-center justify-between text-xs text-slate-400">
                  <span>Question ID: {currentQuestion.position}</span>
                  <span>{currentQuestion.marks} Mark{currentQuestion.marks > 1 ? "s" : ""}</span>
                </div>
                <h3 className="text-base sm:text-lg font-semibold text-slate-900 leading-relaxed">
                  {currentQuestion.text}
                </h3>
              </div>

              {/* 4 Options */}
              <div className="space-y-2.5">
                {(currentQuestion.options || []).map((opt) => {
                  const isSelected = answers[currentQuestion.id] === opt.id;
                  return (
                    <button
                      key={opt.id}
                      onClick={() => handleSelectOption(currentQuestion.id, opt.id)}
                      className={`w-full text-left p-3.5 rounded-xl border text-xs sm:text-sm font-medium transition-all flex items-start gap-3 ${
                        isSelected
                          ? "border-primary bg-blue-50/70 text-primary shadow-xs"
                          : "border-slate-200 bg-white hover:bg-slate-50 text-slate-700"
                      }`}
                    >
                      <div
                        className={`h-4 w-4 rounded-full border mt-0.5 flex-shrink-0 flex items-center justify-center ${
                          isSelected
                            ? "border-primary bg-primary"
                            : "border-slate-300 bg-white"
                        }`}
                      >
                        {isSelected && <div className="h-1.5 w-1.5 rounded-full bg-white" />}
                      </div>
                      <span className="leading-snug">{opt.text}</span>
                    </button>
                  );
                })}
              </div>

              {/* Navigation Controls: Prev / Next */}
              <div className="pt-4 border-t border-slate-100 flex items-center justify-between">
                <button
                  disabled={currentIndex === 0}
                  onClick={() => setCurrentIndex((prev) => Math.max(0, prev - 1))}
                  className="inline-flex items-center gap-1 rounded-lg border border-slate-200 bg-white hover:bg-slate-50 px-3.5 py-2 text-xs font-semibold text-slate-700 transition-colors disabled:opacity-40"
                >
                  <ChevronLeft className="h-4 w-4" /> Previous
                </button>

                {currentIndex < totalQuestions - 1 ? (
                  <button
                    onClick={() => setCurrentIndex((prev) => Math.min(totalQuestions - 1, prev + 1))}
                    className="inline-flex items-center gap-1 rounded-lg bg-navy-900 hover:bg-navy-800 px-4 py-2 text-xs font-semibold text-white shadow-sm transition-colors"
                  >
                    Next Question <ChevronRight className="h-4 w-4" />
                  </button>
                ) : (
                  <button
                    onClick={() => setShowConfirmModal(true)}
                    className="inline-flex items-center gap-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-700 px-4 py-2 text-xs font-bold text-white shadow-sm transition-colors"
                  >
                    Review & Submit <Send className="h-3.5 w-3.5" />
                  </button>
                )}
              </div>
            </div>
          ) : (
            <div className="p-12 text-center text-slate-400">Question not available.</div>
          )}
        </div>

        {/* Right Column: Question Navigator */}
        <div className="space-y-4">
          <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-4 space-y-4">
            <div className="flex items-center justify-between border-b border-slate-100 pb-2">
              <h4 className="text-xs font-bold text-navy-900 uppercase tracking-wider">
                Question Grid
              </h4>
              <span className="text-[11px] font-semibold text-slate-500">
                {answeredCount}/{totalQuestions}
              </span>
            </div>

            <div className="grid grid-cols-4 sm:grid-cols-5 md:grid-cols-4 gap-2">
              {questions.map((q, idx) => {
                const isAnswered = Boolean(answers[q.id]);
                const isCurrent = idx === currentIndex;

                return (
                  <button
                    key={q.id}
                    onClick={() => setCurrentIndex(idx)}
                    className={`h-9 rounded-lg text-xs font-bold transition-all ${
                      isCurrent
                        ? "bg-navy-900 text-white shadow-sm ring-2 ring-navy-900 ring-offset-1"
                        : isAnswered
                        ? "bg-emerald-50 text-emerald-700 border border-emerald-300"
                        : "bg-slate-100 text-slate-600 hover:bg-slate-200"
                    }`}
                  >
                    {idx + 1}
                  </button>
                );
              })}
            </div>

            {/* Legend */}
            <div className="pt-2 border-t border-slate-100 space-y-1.5 text-[11px] text-slate-500">
              <div className="flex items-center gap-2">
                <span className="h-2.5 w-2.5 rounded bg-emerald-50 border border-emerald-300 inline-block" />
                <span>Answered ({answeredCount})</span>
              </div>
              <div className="flex items-center gap-2">
                <span className="h-2.5 w-2.5 rounded bg-slate-100 inline-block" />
                <span>Unanswered ({totalQuestions - answeredCount})</span>
              </div>
              <div className="flex items-center gap-2">
                <span className="h-2.5 w-2.5 rounded bg-navy-900 inline-block" />
                <span>Current Question</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* Confirmation Modal */}
      {showConfirmModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4">
          <div className="bg-white rounded-2xl max-w-sm w-full p-6 shadow-2xl space-y-4">
            <h3 className="text-base font-bold text-navy-900">Confirm Test Submission</h3>
            <p className="text-xs text-slate-600 leading-relaxed">
              You have answered <strong>{answeredCount}</strong> of <strong>{totalQuestions}</strong> questions.
              {totalQuestions - answeredCount > 0 && (
                <span className="text-amber-700 block mt-1">
                  Warning: You have {totalQuestions - answeredCount} unanswered questions remaining.
                </span>
              )}
            </p>
            <p className="text-xs text-slate-500">
              Once submitted, your answers will be graded by the server and results will be recorded in your competency profile.
            </p>

            <div className="flex justify-end gap-2 pt-2 border-t border-slate-100">
              <button
                type="button"
                onClick={() => setShowConfirmModal(false)}
                className="rounded-lg border border-slate-200 px-4 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50"
              >
                Return to Test
              </button>
              <button
                type="button"
                disabled={submitting}
                onClick={submitTest}
                className="rounded-lg bg-emerald-600 hover:bg-emerald-700 px-4 py-2 text-xs font-bold text-white shadow-sm disabled:opacity-50"
              >
                {submitting ? "Submitting..." : "Yes, Submit Now"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
