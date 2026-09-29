"use client";

import React, { useEffect, useState } from "react";
import Link from "next/link";
import { useParams } from "next/navigation";
import { 
  ArrowLeft, 
  Video, 
  FileText, 
  Award, 
  Clock, 
  User as UserIcon, 
  CheckCircle,
  ExternalLink,
  BookOpen
} from "lucide-react";
import { api, Course, CourseResource, EnrollmentRecord } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function CourseDetailPage() {
  const params = useParams();
  const courseId = params.id as string;
  const { user } = useAuth();

  const [course, setCourse] = useState<Course | null>(null);
  const [enrollment, setEnrollment] = useState<EnrollmentRecord | null>(null);
  const [enrolling, setEnrolling] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [activeResource, setActiveResource] = useState<CourseResource | null>(null);

  const loadData = async () => {
    if (!courseId) return;
    try {
      setLoading(true);
      const courseData = await api.courses.get(courseId);
      setCourse(courseData);
      if (courseData.resources && courseData.resources.length > 0) {
        setActiveResource(courseData.resources[0]);
      }
      if (user && user.role === "trainee") {
        const enrollData = await api.courses.getEnrollment(courseId).catch(() => ({ enrolled: false, enrollment: null }));
        if (enrollData.enrolled) {
          setEnrollment(enrollData.enrollment);
        }
      }
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    loadData();
  }, [courseId, user]);

  const handleEnroll = async () => {
    try {
      setEnrolling(true);
      await api.courses.enroll(courseId);
      await loadData();
    } catch (err: any) {
      alert(err.message || "Failed to enroll in course");
    } finally {
      setEnrolling(false);
    }
  };

  if (loading) {
    return <div className="p-12 text-center text-slate-500 text-sm">Loading course details...</div>;
  }

  if (error || !course) {
    return (
      <div className="bg-white p-8 rounded-xl border border-slate-200 shadow-sm text-center space-y-4 max-w-md mx-auto my-12">
        <h2 className="text-lg font-bold text-navy-900">Course Not Found</h2>
        <p className="text-xs text-slate-500">{error || "The requested course could not be loaded."}</p>
        <Link
          href="/courses"
          className="inline-flex items-center gap-2 rounded-lg bg-navy-900 text-white px-4 py-2 text-xs font-semibold"
        >
          <ArrowLeft className="h-4 w-4" /> Return to Catalogue
        </Link>
      </div>
    );
  }

  // Group resources by module
  const modulesMap: Record<string, CourseResource[]> = {};
  (course.resources || []).forEach((r) => {
    const mod = r.module_title || "General";
    if (!modulesMap[mod]) modulesMap[mod] = [];
    modulesMap[mod].push(r);
  });

  return (
    <div className="space-y-6">
      {/* Top Breadcrumb */}
      <div>
        <Link
          href="/courses"
          className="inline-flex items-center gap-1.5 text-xs font-semibold text-slate-500 hover:text-navy-900 transition-colors"
        >
          <ArrowLeft className="h-4 w-4" /> Back to Catalogue
        </Link>
      </div>

      {/* Course Header Banner */}
      <div className="bg-white p-6 rounded-xl border border-slate-200 shadow-sm space-y-4">
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-xs font-bold text-primary bg-blue-50 px-2.5 py-1 rounded uppercase tracking-wide">
            {course.code}
          </span>
          <span className="text-xs font-semibold text-slate-600 bg-slate-100 px-2.5 py-1 rounded capitalize">
            {course.level} Level
          </span>
          {course.skill_name && (
            <span className="text-xs font-semibold text-navy-900 bg-slate-100 px-2.5 py-1 rounded">
              {course.skill_name}
            </span>
          )}
          {course.issues_certificate && (
            <span className="text-xs font-semibold text-emerald-800 bg-emerald-50 border border-emerald-200 px-2.5 py-0.5 rounded flex items-center gap-1">
              <Award className="h-3 w-3" /> Certificate Included
            </span>
          )}
        </div>

        <h1 className="text-2xl sm:text-3xl font-extrabold text-navy-900 tracking-tight">
          {course.title}
        </h1>

        {course.summary && (
          <p className="text-sm text-slate-600 max-w-3xl leading-relaxed">
            {course.summary}
          </p>
        )}

        <div className="pt-2 flex flex-wrap items-center justify-between gap-4 text-xs border-t border-slate-100">
          <div className="flex flex-wrap items-center gap-6 text-slate-500">
            <div className="flex items-center gap-1.5 font-medium text-slate-700">
              <UserIcon className="h-4 w-4 text-slate-400" />
              <span>Lead Trainer: {course.trainer_name || "Assigned IMD Scientist"}</span>
            </div>
            <div className="flex items-center gap-1.5">
              <Clock className="h-4 w-4 text-slate-400" />
              <span>Est. Duration: {course.duration_hours || 4} Hours</span>
            </div>
            <div>
              <span>Pass Threshold: {course.pass_criteria_pct}%</span>
            </div>
          </div>

          <div>
            {enrollment ? (
              <div className="flex items-center gap-3">
                <span className="text-xs font-semibold text-emerald-700">
                  {enrollment.progress_pct}% Completed
                </span>
                <Link
                  href={`/courses/${course.id}/learn`}
                  className="inline-flex items-center gap-1.5 rounded-lg bg-primary hover:bg-primary-hover text-white px-4 py-2 text-xs font-semibold shadow-sm transition-colors"
                >
                  <BookOpen className="h-3.5 w-3.5" /> Continue Learning
                </Link>
              </div>
            ) : user && user.role === "trainee" ? (
              <button
                onClick={handleEnroll}
                disabled={enrolling}
                className="inline-flex items-center gap-1.5 rounded-lg bg-primary hover:bg-primary-hover text-white px-4 py-2 text-xs font-semibold shadow-sm transition-colors disabled:opacity-50"
              >
                <CheckCircle className="h-3.5 w-3.5" />
                {enrolling ? "Enrolling..." : "Enroll in Course"}
              </button>
            ) : user ? (
              <Link
                href={`/courses/${course.id}/learn`}
                className="inline-flex items-center gap-1.5 rounded-lg bg-navy-900 hover:bg-navy-800 text-white px-4 py-2 text-xs font-semibold shadow-sm transition-colors"
              >
                <BookOpen className="h-3.5 w-3.5" /> Open Course Player
              </Link>
            ) : (
              <Link
                href="/login"
                className="inline-flex items-center gap-1.5 rounded-lg bg-primary hover:bg-primary-hover text-white px-4 py-2 text-xs font-semibold shadow-sm transition-colors"
              >
                Login to Enroll
              </Link>
            )}
          </div>
        </div>
      </div>

      {/* Content Layout: Main Viewer + Module Sidebar */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Main Resource Viewer */}
        <div className="lg:col-span-2 bg-white rounded-xl border border-slate-200 shadow-sm p-6 space-y-4">
          {activeResource ? (
            <div className="space-y-4">
              <div className="flex justify-between items-start border-b border-slate-100 pb-3">
                <div>
                  <span className="text-[11px] font-semibold text-slate-400 uppercase tracking-wider block">
                    {activeResource.module_title}
                  </span>
                  <h2 className="text-lg font-bold text-navy-900">{activeResource.title}</h2>
                </div>
                <span className="text-xs px-2 py-0.5 rounded bg-slate-100 font-semibold uppercase text-slate-600">
                  {activeResource.type}
                </span>
              </div>

              {/* Resource Content: Video Player or Document */}
              {activeResource.type === "video" ? (
                <div className="rounded-lg overflow-hidden bg-black aspect-video flex items-center justify-center">
                  {activeResource.file_path ? (
                    <video
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
                    ></iframe>
                  ) : (
                    <div className="text-slate-400 text-xs">Video content pending upload</div>
                  )}
                </div>
              ) : activeResource.type === "pdf" ? (
                <div className="p-8 rounded-lg bg-slate-50 border border-slate-200 text-center space-y-4">
                  <FileText className="h-12 w-12 text-primary mx-auto" />
                  <div>
                    <h3 className="font-bold text-slate-900">{activeResource.title}</h3>
                    <p className="text-xs text-slate-500">Document / Lecture Notes</p>
                  </div>
                  {activeResource.file_path ? (
                    <a
                      href={activeResource.file_path}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-xs font-semibold text-white hover:bg-primary-hover transition-colors"
                    >
                      Open PDF in Viewer <ExternalLink className="h-3.5 w-3.5" />
                    </a>
                  ) : (
                    <p className="text-xs text-slate-400 italic">File not uploaded yet.</p>
                  )}
                </div>
              ) : (
                <div className="p-6 rounded-lg bg-slate-50 border border-slate-200 space-y-2">
                  <h3 className="font-semibold text-slate-900">{activeResource.title}</h3>
                  <p className="text-xs text-slate-600">{activeResource.description || "No description provided."}</p>
                  {activeResource.external_url && (
                    <a
                      href={activeResource.external_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="inline-flex items-center gap-1 text-xs font-semibold text-primary hover:underline"
                    >
                      External Resource Link <ExternalLink className="h-3 w-3" />
                    </a>
                  )}
                </div>
              )}

              {activeResource.description && (
                <p className="text-xs text-slate-600 pt-2">{activeResource.description}</p>
              )}
            </div>
          ) : (
            <div className="text-center py-12 text-slate-400 space-y-2">
              <BookOpen className="h-10 w-10 mx-auto" />
              <p className="text-sm font-medium">Select a resource from the curriculum to begin</p>
            </div>
          )}
        </div>

        {/* Modules & Curriculum Sidebar */}
        <div className="bg-white rounded-xl border border-slate-200 shadow-sm p-4 space-y-4 h-fit">
          <h3 className="font-bold text-navy-900 text-sm uppercase tracking-wide border-b border-slate-100 pb-2">
            Curriculum & Modules
          </h3>

          {Object.keys(modulesMap).length === 0 ? (
            <p className="text-xs text-slate-400 italic">No resources added to this course yet.</p>
          ) : (
            <div className="space-y-4">
              {Object.entries(modulesMap).map(([modTitle, resList]) => (
                <div key={modTitle} className="space-y-1.5">
                  <h4 className="text-xs font-bold text-slate-700 bg-slate-50 px-2 py-1.5 rounded">
                    {modTitle}
                  </h4>
                  <div className="space-y-1 pl-1">
                    {resList.map((r) => {
                      const isSelected = activeResource?.id === r.id;
                      return (
                        <button
                          key={r.id}
                          onClick={() => setActiveResource(r)}
                          className={`w-full text-left p-2 rounded-lg text-xs flex items-center justify-between transition-colors ${
                            isSelected
                              ? "bg-blue-50 text-primary font-semibold border border-blue-200"
                              : "hover:bg-slate-50 text-slate-700"
                          }`}
                        >
                          <div className="flex items-center gap-2 truncate">
                            {r.type === "video" ? (
                              <Video className="h-3.5 w-3.5 text-blue-600 flex-shrink-0" />
                            ) : (
                              <FileText className="h-3.5 w-3.5 text-amber-600 flex-shrink-0" />
                            )}
                            <span className="truncate">{r.title}</span>
                          </div>
                          {r.is_mandatory && (
                            <span className="text-[9px] font-bold text-slate-400 uppercase">
                              Req
                            </span>
                          )}
                        </button>
                      );
                    })}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
