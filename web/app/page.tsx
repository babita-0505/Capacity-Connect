"use client";

import React from "react";
import Link from "next/link";
import { 
  Compass, 
  ArrowRight, 
  ShieldCheck, 
  CheckCircle2, 
  Target, 
  BarChart2, 
  BookOpen, 
  Users 
} from "lucide-react";
import { useAuth } from "@/components/layout/AppShell";

export default function HomePage() {
  const { user } = useAuth();

  return (
    <div className="space-y-12 py-4">
      {/* Hero Section */}
      <section className="rounded-2xl bg-gradient-to-b from-navy-900 to-navy-800 text-white p-8 sm:p-12 md:p-16 shadow-xl relative overflow-hidden">
        <div className="max-w-3xl space-y-6 relative z-10">
          <div className="inline-flex items-center gap-2 rounded-full bg-navy-700/60 border border-slate-700 px-3.5 py-1 text-xs font-medium text-slate-300">
            <span className="h-2 w-2 rounded-full bg-emerald-400"></span>
            SIH 2026 · PS SIH26075 · Ministry of Earth Sciences / IMD
          </div>

          <h1 className="text-3xl sm:text-4xl md:text-5xl font-extrabold tracking-tight leading-tight">
            Build Skills. Measure Competency. Connect Learning to Outcomes.
          </h1>

          <p className="text-base sm:text-lg text-slate-300 leading-relaxed">
            The unified digital training and competency mapping portal for India Meteorological Department personnel. 
            Empowering scientists, forecasters, and observers through structured learning, verified assessments, and transparent skill analytics.
          </p>

          <div className="flex flex-wrap gap-4 pt-2">
            <Link
              href="/courses"
              className="inline-flex items-center gap-2 rounded-lg bg-primary px-5 py-3 text-sm font-semibold text-white shadow-md hover:bg-primary-hover transition-colors"
            >
              <Compass className="h-4 w-4" />
              Explore Courses
            </Link>

            {user ? (
              <Link
                href="/profile"
                className="inline-flex items-center gap-2 rounded-lg bg-white/10 hover:bg-white/20 border border-white/20 px-5 py-3 text-sm font-semibold text-white transition-colors"
              >
                Go to My Profile
                <ArrowRight className="h-4 w-4" />
              </Link>
            ) : (
              <Link
                href="/login"
                className="inline-flex items-center gap-2 rounded-lg bg-white/10 hover:bg-white/20 border border-white/20 px-5 py-3 text-sm font-semibold text-white transition-colors"
              >
                Login to Portal
                <ArrowRight className="h-4 w-4" />
              </Link>
            )}
          </div>
        </div>
      </section>

      {/* The Competency Loop Explanation */}
      <section className="space-y-6">
        <div className="text-center max-w-2xl mx-auto space-y-2">
          <h2 className="text-2xl sm:text-3xl font-bold text-navy-900 tracking-tight">
            The Continuous Competency Loop
          </h2>
          <p className="text-sm sm:text-base text-slate-600">
            A closed-loop system connecting curriculum design, training delivery, objective evaluation, and institutional deployment.
          </p>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-4 gap-6">
          <div className="bg-white p-6 rounded-xl border border-slate-200 shadow-sm space-y-3">
            <div className="h-10 w-10 rounded-lg bg-blue-50 text-primary flex items-center justify-center font-bold">
              <Target className="h-5 w-5" />
            </div>
            <h3 className="font-semibold text-navy-900 text-base">1. Standard Taxonomy</h3>
            <p className="text-xs text-slate-600 leading-relaxed">
              Standardized meteorological taxonomy covering Radar, NWP, Cyclone Forecasting, Satellite, and Observations.
            </p>
          </div>

          <div className="bg-white p-6 rounded-xl border border-slate-200 shadow-sm space-y-3">
            <div className="h-10 w-10 rounded-lg bg-blue-50 text-primary flex items-center justify-center font-bold">
              <BookOpen className="h-5 w-5" />
            </div>
            <h3 className="font-semibold text-navy-900 text-base">2. Targeted Training</h3>
            <p className="text-xs text-slate-600 leading-relaxed">
              Specialized courses with interactive video lectures and notes created directly by certified IMD trainers.
            </p>
          </div>

          <div className="bg-white p-6 rounded-xl border border-slate-200 shadow-sm space-y-3">
            <div className="h-10 w-10 rounded-lg bg-blue-50 text-primary flex items-center justify-center font-bold">
              <CheckCircle2 className="h-5 w-5" />
            </div>
            <h3 className="font-semibold text-navy-900 text-base">3. Timed Assessments</h3>
            <p className="text-xs text-slate-600 leading-relaxed">
              Secure subject-wise MCQ assessments with browser activity monitoring and server-side grading.
            </p>
          </div>

          <div className="bg-white p-6 rounded-xl border border-slate-200 shadow-sm space-y-3">
            <div className="h-10 w-10 rounded-lg bg-blue-50 text-primary flex items-center justify-center font-bold">
              <BarChart2 className="h-5 w-5" />
            </div>
            <h3 className="font-semibold text-navy-900 text-base">4. Competency Mapping</h3>
            <p className="text-xs text-slate-600 leading-relaxed">
              Pure SQL ranking engine computes trainer scores and identifies critical regional skill gaps automatically.
            </p>
          </div>
        </div>
      </section>

      {/* Role Access Cards */}
      <section className="bg-slate-100 rounded-2xl p-6 sm:p-8 space-y-6 border border-slate-200">
        <h3 className="text-lg font-bold text-navy-900">Platform Access Roles</h3>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          <div className="bg-white p-5 rounded-lg border border-slate-200 space-y-2">
            <span className="inline-block px-2 py-0.5 text-xs font-semibold rounded bg-blue-100 text-primary">Trainee</span>
            <h4 className="font-semibold text-slate-900">Meteorologists & Staff</h4>
            <p className="text-xs text-slate-600">
              Enroll in specialized meteorological modules, complete quizzes, view personalized skill levels and receive verified credentials.
            </p>
          </div>

          <div className="bg-white p-5 rounded-lg border border-slate-200 space-y-2">
            <span className="inline-block px-2 py-0.5 text-xs font-semibold rounded bg-indigo-100 text-indigo-700">Trainer</span>
            <h4 className="font-semibold text-slate-900">Instructors & Scientists</h4>
            <p className="text-xs text-slate-600">
              Publish learning materials (MP4, PDF), build subject question banks, schedule assessments, and monitor learner performance.
            </p>
          </div>

          <div className="bg-white p-5 rounded-lg border border-slate-200 space-y-2">
            <span className="inline-block px-2 py-0.5 text-xs font-semibold rounded bg-slate-200 text-navy-900">Admin</span>
            <h4 className="font-semibold text-slate-900">Capacity Building Cell</h4>
            <p className="text-xs text-slate-600">
              Manage user approvals, inspect regional skill gap heatmaps, and discover the best-qualified trainers per subject.
            </p>
          </div>
        </div>
      </section>
    </div>
  );
}
