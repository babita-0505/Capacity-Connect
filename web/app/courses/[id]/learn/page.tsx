"use client";

import React, { useEffect, useState } from "react";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import {
  ArrowLeft,
  ArrowRight,
  CheckCircle2,
  Circle,
  FileText,
  Video,
  Award,
  BookOpen,
  Menu,
  X,
  ExternalLink,
  Download,
  AlertCircle
} from "lucide-react";
import { api, Course, CourseResource, EnrollmentRecord } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function CoursePlayerPage() {
  const params = useParams();
  const router = useRouter();
  const courseId = params.id as string;
  const { user, loading: authLoading } = useAuth();

  const [course, setCourse] = useState<Course | null>(null);
  const [enrollment, setEnrollment] = useState<EnrollmentRecord | null>(null);
  const [activeResource, setActiveResource] = useState<CourseResource | null>(null);
  const [loading, setLoading] = useState(true);
  const [actionLoading, setActionLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const [completionNotice, setCompletionNotice] = useState<string | null>(null);

  const loadData = async () => {
    try {
      setLoading(true);
      setError(null);
      const [courseData, enrollData] = await Promise.all([
        api.courses.get(courseId),
        api.courses.getEnrollment(courseId).catch(() => ({ enrolled: false, enrollment: null }))
      ]);

      setCourse(courseData);

      if (!enrollData.enrolled || !enrollData.enrollment) {
        // Not enrolled, redirect to preview page
        router.push(`/courses/${courseId}`);
        return;
      }

      setEnrollment(enrollData.enrollment);

      const allResources = courseData.resources || [];
      if (allResources.length > 0) {
        // Find first incomplete resource or default to first
        const completedIds = new Set(enrollData.enrollment.completed_resource_ids || []);
        const firstIncomplete = allResources.find(r => !completedIds.has(r.id)) || allResources[0];
        setActiveResource(firstIncomplete);
      }
    } catch (err: any) {
      setError(err.message || "Failed to load course");
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
      loadData();
    }
  }, [courseId, user, authLoading]);

  const handleMarkComplete = async (resourceId: string) => {
    if (!enrollment) return;
    try {
      setActionLoading(true);
      const res = await api.courses.completeResource(enrollment.id, resourceId);

      // Update local enrollment state
      const updatedCompleted = Array.from(new Set([...(enrollment.completed_resource_ids || []), resourceId]));
      setEnrollment({
        ...enrollment,
        progress_pct: res.progress_pct,
        completed_resource_ids: updatedCompleted,
        status: res.progress_pct >= 100 ? "completed" : "in_progress"
      });

      if (res.progress_pct >= 100) {
        setCompletionNotice("Congratulations! You have completed all mandatory learning resources.");
      }

      // Automatically advance to the next resource if available
      const allResources = course?.resources || [];
      const currentIndex = allResources.findIndex(r => r.id === resourceId);
      if (currentIndex >= 0 && currentIndex < allResources.length - 1) {
        setActiveResource(allResources[currentIndex + 1]);
      }
    } catch (err: any) {
      alert(err.message || "Unable to mark resource complete");
    } finally {
      setActionLoading(false);
    }
  };

  if (loading || authLoading) {
    return (
      <div className="flex flex-col items-center justify-center p-20 space-y-3">
        <div className="h-8 w-8 animate-spin rounded-full border-4 border-primary border-t-transparent"></div>
        <p className="text-xs text-slate-500">Loading course curriculum...</p>
      </div>
    );
  }

  if (error || !course || !enrollment) {
    return (
      <div className="max-w-md mx-auto my-12 p-6 bg-white rounded-xl border border-slate-200 text-center space-y-4">
        <AlertCircle className="h-10 w-10 text-red-500 mx-auto" />
        <h2 className="text-base font-bold text-navy-900">Unable to Open Course</h2>
        <p className="text-xs text-slate-500">{error || "Please enroll in this course first."}</p>
        <Link
          href={`/courses/${courseId}`}
          className="inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-xs font-semibold text-white"
        >
          View Course Overview
        </Link>
      </div>
    );
  }

  const allResources = course.resources || [];
  const completedSet = new Set(enrollment.completed_resource_ids || []);
  const mandatoryResources = allResources.filter(r => r.is_mandatory);
  const completedMandatory = mandatoryResources.filter(r => completedSet.has(r.id)).length;

  // Group by module
  const modulesMap: Record<string, CourseResource[]> = {};
  allResources.forEach((r) => {
    const mod = r.module_title || "Module 1";
    if (!modulesMap[mod]) modulesMap[mod] = [];
    modulesMap[mod].push(r);
  });

  const isCurrentCompleted = activeResource ? completedSet.has(activeResource.id) : false;
  const currentIndex = activeResource ? allResources.findIndex(r => r.id === activeResource.id) : -1;
  const nextResource = currentIndex >= 0 && currentIndex < allResources.length - 1 ? allResources[currentIndex + 1] : null;
  const prevResource = currentIndex > 0 ? allResources[currentIndex - 1] : null;

  return (
    <div className="space-y-4">
      {/* Top Banner / Navigation */}
      <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-4 flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div className="flex items-center gap-3">
          <Link
            href={`/courses/${course.id}`}
            className="p-2 rounded-lg hover:bg-slate-100 text-slate-500 hover:text-navy-900 transition-colors"
            title="Course details"
          >
            <ArrowLeft className="h-4 w-4" />
          </Link>
          <div>
            <div className="flex items-center gap-2">
              <span className="text-[10px] font-bold text-primary bg-blue-50 px-2 py-0.5 rounded uppercase">
                {course.code}
              </span>
              <span className="text-xs font-semibold text-slate-500">Learning Mode</span>
            </div>
            <h1 className="text-base sm:text-lg font-bold text-navy-900 leading-tight">
              {course.title}
            </h1>
          </div>
        </div>

        {/* Progress Display */}
        <div className="flex items-center gap-4">
          <div className="text-right">
            <div className="text-xs font-bold text-navy-900">
              {enrollment.progress_pct}% Completed
            </div>
            <div className="text-[11px] text-slate-500">
              {completedMandatory} of {mandatoryResources.length} mandatory modules
            </div>
          </div>
          <div className="w-24 h-2 bg-slate-100 rounded-full overflow-hidden">
            <div
              className="h-full bg-emerald-500 transition-all duration-300 rounded-full"
              style={{ width: `${enrollment.progress_pct}%` }}
            />
          </div>

          <button
            onClick={() => setSidebarOpen(!sidebarOpen)}
            className="lg:hidden p-2 rounded-lg border border-slate-200 text-slate-600 hover:bg-slate-50"
            title="Toggle curriculum"
          >
            {sidebarOpen ? <X className="h-4 w-4" /> : <Menu className="h-4 w-4" />}
          </button>
        </div>
      </div>

      {completionNotice && (
        <div className="p-3 rounded-lg bg-emerald-50 border border-emerald-200 text-emerald-800 text-xs flex items-center justify-between">
          <div className="flex items-center gap-2">
            <CheckCircle2 className="h-4 w-4 text-emerald-600" />
            <span>{completionNotice}</span>
          </div>
          {enrollment.assessment_id && (
            <Link
              href={`/assessments/${enrollment.assessment_id}`}
              className="rounded bg-emerald-700 text-white font-semibold px-3 py-1 hover:bg-emerald-800 transition-colors"
            >
              Take Assessment Now
            </Link>
          )}
        </div>
      )}

      {/* Main Grid: Player + Curriculum Sidebar */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Main Resource Screen */}
        <div className="lg:col-span-2 space-y-4">
          <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-5 space-y-4">
            {activeResource ? (
              <div className="space-y-4">
                <div className="flex items-center justify-between border-b border-slate-100 pb-3">
                  <div>
                    <span className="text-[10px] font-bold uppercase tracking-wider text-slate-400">
                      {activeResource.module_title}
                    </span>
                    <h2 className="text-base font-bold text-navy-900">{activeResource.title}</h2>
                  </div>
                  <div className="flex items-center gap-2">
                    {isCurrentCompleted ? (
                      <span className="inline-flex items-center gap-1 text-[11px] font-bold text-emerald-700 bg-emerald-50 border border-emerald-200 px-2.5 py-1 rounded">
                        <CheckCircle2 className="h-3 w-3" /> Completed
                      </span>
                    ) : (
                      <button
                        onClick={() => handleMarkComplete(activeResource.id)}
                        disabled={actionLoading}
                        className="inline-flex items-center gap-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-700 px-3 py-1.5 text-xs font-semibold text-white shadow-sm transition-colors disabled:opacity-50"
                      >
                        <CheckCircle2 className="h-3.5 w-3.5" />
                        {actionLoading ? "Saving..." : "Mark Complete"}
                      </button>
                    )}
                  </div>
                </div>

                {/* Resource Viewer */}
                {activeResource.type === "video" ? (
                  <div className="rounded-lg overflow-hidden bg-black aspect-video flex items-center justify-center shadow-inner">
                    {activeResource.file_path ? (
                      <video
                        key={activeResource.file_path}
                        controls
                        preload="metadata"
                        src={activeResource.file_path}
                        className="w-full h-full"
                      >
                        Your browser does not support the video tag.
                      </video>
                    ) : activeResource.external_url ? (
                      <iframe
                        src={activeResource.external_url}
                        className="w-full h-full border-0"
                        allowFullScreen
                      />
                    ) : (
                      <div className="text-slate-400 text-xs">Video content pending upload</div>
                    )}
                  </div>
                ) : activeResource.type === "pdf" ? (
                  <div className="space-y-3">
                    {activeResource.file_path ? (
                      <div className="border border-slate-200 rounded-lg overflow-hidden bg-slate-900 h-[520px]">
                        <iframe
                          src={`${activeResource.file_path}#toolbar=1`}
                          className="w-full h-full"
                          title={activeResource.title}
                        />
                      </div>
                    ) : (
                      <div className="p-12 text-center bg-slate-50 border border-slate-200 rounded-lg space-y-2">
                        <FileText className="h-10 w-10 text-slate-300 mx-auto" />
                        <p className="text-xs text-slate-500">PDF file has not been uploaded yet.</p>
                      </div>
                    )}
                  </div>
                ) : (
                  <div className="p-8 rounded-lg bg-slate-50 border border-slate-200 space-y-3">
                    <h3 className="font-semibold text-slate-800">{activeResource.title}</h3>
                    <p className="text-xs text-slate-600">{activeResource.description || "No description provided."}</p>
                    {activeResource.file_path ? (
                      <a
                        href={activeResource.file_path}
                        download
                        className="inline-flex items-center gap-1.5 rounded-lg bg-primary px-4 py-2 text-xs font-semibold text-white"
                      >
                        <Download className="h-3.5 w-3.5" /> Download Document
                      </a>
                    ) : activeResource.external_url ? (
                      <a
                        href={activeResource.external_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="inline-flex items-center gap-1.5 rounded-lg bg-primary px-4 py-2 text-xs font-semibold text-white"
                      >
                        <ExternalLink className="h-3.5 w-3.5" /> Open External Link
                      </a>
                    ) : null}
                  </div>
                )}

                {/* Resource description */}
                {activeResource.description && (
                  <p className="text-xs text-slate-600 pt-2 leading-relaxed">
                    {activeResource.description}
                  </p>
                )}

                {/* Next / Previous resource buttons */}
                <div className="flex flex-wrap items-center justify-between gap-2 border-t border-slate-100 pt-3">
                  {prevResource ? (
                    <button
                      onClick={() => setActiveResource(prevResource)}
                      className="inline-flex items-center gap-1.5 text-xs font-semibold text-slate-600 hover:text-navy-900 py-1.5 px-3 rounded-lg border border-slate-200 hover:bg-slate-50 transition-colors max-w-[45%] sm:max-w-none"
                    >
                      <ArrowLeft className="h-3.5 w-3.5 flex-shrink-0" /> <span className="truncate">Previous: {prevResource.title}</span>
                    </button>
                  ) : <div />}

                  {nextResource ? (
                    <button
                      onClick={() => setActiveResource(nextResource)}
                      className="inline-flex items-center gap-1.5 text-xs font-semibold text-primary hover:text-primary-hover py-1.5 px-3 rounded-lg border border-blue-200 bg-blue-50 hover:bg-blue-100 transition-colors max-w-[45%] sm:max-w-none"
                    >
                      <span className="truncate">Next: {nextResource.title}</span> <ArrowRight className="h-3.5 w-3.5 flex-shrink-0" />
                    </button>
                  ) : enrollment.assessment_id ? (
                    <Link
                      href={`/assessments/${enrollment.assessment_id}`}
                      className="inline-flex items-center gap-1.5 text-xs font-semibold text-white py-1.5 px-4 rounded-lg bg-primary hover:bg-primary-hover transition-colors"
                    >
                      <Award className="h-3.5 w-3.5" /> Take Course Assessment
                    </Link>
                  ) : null}
                </div>
              </div>
            ) : (
              <div className="text-center py-12 text-slate-400 space-y-2">
                <BookOpen className="h-8 w-8 mx-auto" />
                <p className="text-xs">Select a module resource to begin learning.</p>
              </div>
            )}
          </div>
        </div>

        {/* Modules & Curriculum Sidebar */}
        <div className={`lg:block ${sidebarOpen ? "block" : "hidden"} space-y-4`}>
          <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-4 space-y-4">
            <div className="flex items-center justify-between border-b border-slate-100 pb-2">
              <h3 className="font-bold text-navy-900 text-xs uppercase tracking-wider">
                Course Curriculum
              </h3>
              <span className="text-[11px] font-semibold text-slate-500">
                {allResources.length} Items
              </span>
            </div>

            <div className="space-y-4">
              {Object.entries(modulesMap).map(([modTitle, resList]) => (
                <div key={modTitle} className="space-y-1.5">
                  <h4 className="text-xs font-bold text-slate-700 bg-slate-50 px-2.5 py-1.5 rounded border border-slate-100">
                    {modTitle}
                  </h4>
                  <div className="space-y-1">
                    {resList.map((r) => {
                      const isSelected = activeResource?.id === r.id;
                      const isCompleted = completedSet.has(r.id);
                      return (
                        <button
                          key={r.id}
                          onClick={() => {
                            setActiveResource(r);
                            setSidebarOpen(false);
                          }}
                          className={`w-full text-left p-2.5 rounded-lg text-xs flex items-center justify-between transition-colors ${
                            isSelected
                              ? "bg-blue-50 text-primary font-semibold border border-blue-200 shadow-xs"
                              : "hover:bg-slate-50 text-slate-700"
                          }`}
                        >
                          <div className="flex items-center gap-2 truncate">
                            {isCompleted ? (
                              <CheckCircle2 className="h-4 w-4 text-emerald-600 flex-shrink-0" />
                            ) : (
                              <Circle className="h-4 w-4 text-slate-300 flex-shrink-0" />
                            )}
                            {r.type === "video" ? (
                              <Video className="h-3.5 w-3.5 text-blue-600 flex-shrink-0" />
                            ) : (
                              <FileText className="h-3.5 w-3.5 text-amber-600 flex-shrink-0" />
                            )}
                            <span className="truncate">{r.title}</span>
                          </div>
                          {r.is_mandatory && (
                            <span className="text-[9px] font-bold text-slate-400 uppercase flex-shrink-0 ml-1">
                              Req
                            </span>
                          )}
                        </button>
                      );
                    })}
                  </div>
                </div>
              ))}

              {/* Assessment link in curriculum */}
              {enrollment.assessment_id && (
                <div className="pt-2 border-t border-slate-100">
                  <Link
                    href={`/assessments/${enrollment.assessment_id}`}
                    className="w-full p-2.5 rounded-lg text-xs flex items-center justify-between bg-purple-50 text-purple-800 font-semibold border border-purple-200 hover:bg-purple-100 transition-colors"
                  >
                    <div className="flex items-center gap-2">
                      <Award className="h-4 w-4 text-purple-700" />
                      <span>Course Assessment Test</span>
                    </div>
                    <ArrowRight className="h-3.5 w-3.5" />
                  </Link>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
