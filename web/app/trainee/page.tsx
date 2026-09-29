"use client";

import React, { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import {
  BookOpen,
  Award,
  CheckCircle2,
  Clock,
  Play,
  ArrowRight,
  BrainCircuit,
  Compass,
  AlertTriangle,
  Sparkles
} from "lucide-react";
import {
  api,
  TraineeEnrollmentItem,
  TraineeAssessmentItem,
} from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function TraineeDashboardPage() {
  const router = useRouter();
  const { user, loading: authLoading } = useAuth();

  const [enrollments, setEnrollments] = useState<TraineeEnrollmentItem[]>([]);
  const [assessments, setAssessments] = useState<TraineeAssessmentItem[]>([]);
  const [competencyData, setCompetencyData] = useState<any>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!authLoading) {
      if (!user) {
        router.push("/login");
        return;
      }
      if (user.role === "trainer") {
        router.push("/trainer/courses");
        return;
      }
      if (user.role === "admin") {
        router.push("/admin");
        return;
      }

      setLoading(true);
      Promise.all([
        api.courses.getMyEnrollments().catch(() => ({ items: [] })),
        api.assessments.myAssessments().catch(() => ({ items: [] })),
        api.competency.mine().catch(() => null),
      ])
        .then(([enrollRes, assessRes, compRes]) => {
          setEnrollments(enrollRes.items);
          setAssessments(assessRes.items);
          setCompetencyData(compRes);
        })
        .finally(() => setLoading(false));
    }
  }, [user, authLoading, router]);

  if (loading || authLoading) {
    return (
      <div className="flex flex-col items-center justify-center p-20 space-y-3">
        <div className="h-8 w-8 animate-spin rounded-full border-4 border-primary border-t-transparent"></div>
        <p className="text-xs text-slate-500">Loading your learning workspace...</p>
      </div>
    );
  }

  const completedEnrollments = enrollments.filter((e) => e.status === "completed");
  const inProgressEnrollments = enrollments.filter((e) => e.status !== "completed");
  const availableAssessments = assessments.filter((a) => a.can_start);

  return (
    <div className="space-y-7 pb-12">
      {/* Greeting Banner */}
      <div className="rounded-2xl bg-gradient-to-r from-navy-900 to-navy-800 text-white p-6 sm:p-8 shadow-sm flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div className="space-y-1.5">
          <span className="text-xs font-semibold text-emerald-400 uppercase tracking-wider">
            IMD Operational Trainee
          </span>
          <h1 className="text-2xl sm:text-3xl font-extrabold tracking-tight">
            Welcome back, {user?.full_name}!
          </h1>
          <p className="text-xs sm:text-sm text-slate-300 max-w-xl">
            {user?.department || "India Meteorological Department"} · Continue your technical training modules and benchmark competencies.
          </p>
        </div>

        <div className="flex items-center gap-2">
          <Link
            href="/courses"
            className="inline-flex items-center gap-1.5 rounded-lg bg-primary hover:bg-primary-hover px-4 py-2 text-xs font-semibold text-white shadow-sm transition-colors"
          >
            <Compass className="h-4 w-4" /> Explore Catalogue
          </Link>
          <Link
            href="/trainee/skills"
            className="inline-flex items-center gap-1.5 rounded-lg bg-white/10 hover:bg-white/20 border border-white/20 px-3.5 py-2 text-xs font-semibold text-white transition-colors"
          >
            <BrainCircuit className="h-4 w-4" /> My Skills
          </Link>
        </div>
      </div>

      {/* Stats Cards */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
        <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-xs space-y-1">
          <span className="text-[10px] uppercase font-bold text-slate-400 block">Enrolled Courses</span>
          <strong className="text-2xl font-black text-navy-900">{enrollments.length}</strong>
        </div>

        <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-xs space-y-1">
          <span className="text-[10px] uppercase font-bold text-slate-400 block">Completed Courses</span>
          <strong className="text-2xl font-black text-emerald-700">{completedEnrollments.length}</strong>
        </div>

        <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-xs space-y-1">
          <span className="text-[10px] uppercase font-bold text-slate-400 block">Available Tests</span>
          <strong className="text-2xl font-black text-primary">{availableAssessments.length}</strong>
        </div>

        <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-xs space-y-1">
          <span className="text-[10px] uppercase font-bold text-slate-400 block">Certificates</span>
          <strong className="text-2xl font-black text-purple-700">
            {enrollments.filter((e) => e.certificate_no).length}
          </strong>
        </div>
      </div>

      {/* Main Grid: Continue Learning + Assessments */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Left 2 Columns: In-Progress Courses */}
        <div className="lg:col-span-2 space-y-4">
          <div className="flex items-center justify-between">
            <h2 className="text-base font-bold text-navy-900 flex items-center gap-2">
              <BookOpen className="h-4 w-4 text-primary" />
              <span>Continue Learning</span>
            </h2>
            <Link href="/courses" className="text-xs text-primary font-semibold hover:underline">
              View All Courses
            </Link>
          </div>

          {inProgressEnrollments.length === 0 ? (
            <div className="p-10 rounded-xl border border-dashed border-slate-200 bg-white text-center space-y-3">
              <BookOpen className="h-8 w-8 text-slate-300 mx-auto" />
              <p className="text-xs text-slate-500 font-medium">You have no active courses in progress.</p>
              <Link
                href="/courses"
                className="inline-flex items-center gap-1.5 rounded-lg bg-primary text-white text-xs font-semibold px-4 py-2"
              >
                Browse Available Courses
              </Link>
            </div>
          ) : (
            <div className="space-y-3">
              {inProgressEnrollments.map((item) => (
                <div
                  key={item.enrollment_id}
                  className="bg-white p-4 rounded-xl border border-slate-200 shadow-xs hover:border-slate-300 transition-colors flex flex-col sm:flex-row sm:items-center justify-between gap-4"
                >
                  <div className="space-y-1.5 flex-1">
                    <div className="flex items-center gap-2">
                      <span className="text-[10px] font-bold text-primary bg-blue-50 px-2 py-0.5 rounded uppercase">
                        {item.code}
                      </span>
                      <span className="text-[10px] text-slate-400 capitalize">{item.level} Level</span>
                      {item.skill_name && (
                        <span className="text-[10px] text-slate-600 bg-slate-100 px-2 py-0.5 rounded">
                          {item.skill_name}
                        </span>
                      )}
                    </div>

                    <h3 className="font-bold text-navy-900 text-sm leading-snug">{item.title}</h3>

                    <div className="w-full max-w-md pt-1">
                      <div className="flex justify-between text-[11px] text-slate-500 mb-1">
                        <span>Progress</span>
                        <span className="font-bold text-slate-700">{item.progress_pct}%</span>
                      </div>
                      <div className="h-2 bg-slate-100 rounded-full overflow-hidden">
                        <div
                          className="h-full bg-primary rounded-full transition-all duration-300"
                          style={{ width: `${item.progress_pct}%` }}
                        />
                      </div>
                    </div>
                  </div>

                  <div className="flex items-center gap-2">
                    <Link
                      href={`/courses/${item.course_id}/learn`}
                      className="inline-flex items-center gap-1.5 rounded-lg bg-navy-900 hover:bg-navy-800 text-white px-4 py-2 text-xs font-semibold shadow-xs transition-colors"
                    >
                      <Play className="h-3.5 w-3.5 fill-current" /> Continue
                    </Link>
                  </div>
                </div>
              ))}
            </div>
          )}

          {/* Completed Courses Section if any */}
          {completedEnrollments.length > 0 && (
            <div className="pt-4 space-y-3">
              <h3 className="text-sm font-bold text-navy-900 flex items-center gap-1.5">
                <CheckCircle2 className="h-4 w-4 text-emerald-600" />
                <span>Completed Courses ({completedEnrollments.length})</span>
              </h3>

              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                {completedEnrollments.map((ce) => (
                  <div
                    key={ce.enrollment_id}
                    className="p-3.5 rounded-xl border border-emerald-200 bg-emerald-50/30 space-y-2 flex flex-col justify-between"
                  >
                    <div>
                      <span className="text-[10px] font-bold text-emerald-800 uppercase">{ce.code}</span>
                      <h4 className="font-bold text-navy-900 text-xs leading-snug mt-0.5">{ce.title}</h4>
                    </div>

                    <div className="flex items-center justify-between pt-2 border-t border-emerald-100 text-xs">
                      {ce.certificate_no ? (
                        <Link
                          href={`/verify?number=${ce.certificate_no}`}
                          className="text-emerald-700 hover:underline font-semibold flex items-center gap-1 text-[11px]"
                        >
                          <Award className="h-3.5 w-3.5" /> {ce.certificate_no}
                        </Link>
                      ) : (
                        <span className="text-slate-400 text-[11px]">100% Completed</span>
                      )}

                      <Link
                        href={`/courses/${ce.course_id}/learn`}
                        className="text-primary hover:underline font-semibold text-[11px]"
                      >
                        Review Notes
                      </Link>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Right Column: Upcoming Assessments & Skill Highlights */}
        <div className="space-y-6">
          {/* Upcoming Tests */}
          <div className="bg-white rounded-xl border border-slate-200 p-5 shadow-xs space-y-4">
            <div className="flex items-center justify-between border-b border-slate-100 pb-2">
              <h3 className="text-sm font-bold text-navy-900 flex items-center gap-1.5">
                <Award className="h-4 w-4 text-primary" />
                <span>Assigned Assessments</span>
              </h3>
              <Link href="/assessments" className="text-xs text-primary font-semibold hover:underline">
                View All
              </Link>
            </div>

            {availableAssessments.length === 0 ? (
              <p className="text-xs text-slate-400 text-center py-4 italic">
                No active tests waiting for your submission.
              </p>
            ) : (
              <div className="space-y-3">
                {availableAssessments.slice(0, 3).map((test) => (
                  <div
                    key={test.id}
                    className="p-3 rounded-lg border border-slate-200 bg-slate-50/50 space-y-2 text-xs"
                  >
                    <div>
                      <span className="text-[10px] font-semibold text-slate-500 uppercase">
                        {test.skill_name || "General"}
                      </span>
                      <h4 className="font-bold text-navy-900 text-xs leading-snug">{test.title}</h4>
                    </div>

                    <div className="flex items-center justify-between text-[11px] text-slate-500 pt-1">
                      <span>{test.duration_minutes ? `${test.duration_minutes} Mins` : "Untimed"}</span>
                      <Link
                        href={`/assessments/${test.id}`}
                        className="font-bold text-primary hover:underline"
                      >
                        Start Test →
                      </Link>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </div>

          {/* Weak Skills & Reminders */}
          {competencyData && competencyData.weak_skills?.length > 0 && (
            <div className="bg-amber-50/60 rounded-xl border border-amber-200 p-5 space-y-3">
              <div className="flex items-center gap-2 text-amber-900">
                <AlertTriangle className="h-4 w-4 text-amber-600 flex-shrink-0" />
                <h3 className="text-xs font-bold uppercase tracking-wider">
                  Recommended Focus Areas
                </h3>
              </div>
              <p className="text-xs text-amber-800 leading-relaxed">
                Test evaluations indicate you have {competencyData.weak_skills.length} subject gaps below the 60% standard.
              </p>
              <div className="space-y-1.5">
                {competencyData.weak_skills.slice(0, 2).map((ws: any) => (
                  <div key={ws.skill_id} className="flex justify-between text-xs font-semibold text-slate-700 bg-white p-2 rounded border border-amber-200">
                    <span>{ws.skill}</span>
                    <strong className="text-amber-800">{ws.average_pct}%</strong>
                  </div>
                ))}
              </div>
              <div className="pt-2 border-t border-amber-200/60">
                <Link
                  href="/trainee/skills"
                  className="inline-flex items-center gap-1 text-xs font-bold text-amber-900 hover:underline"
                >
                  View Skill Remedies <ArrowRight className="h-3 w-3" />
                </Link>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
