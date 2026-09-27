"use client";

import React, { useEffect, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { 
  Plus, 
  Upload, 
  Check, 
  Send, 
  BookOpen, 
  Video, 
  FileText, 
  Clock, 
  AlertCircle,
  Eye,
  CheckCircle2
} from "lucide-react";
import { api, Course, SkillNode } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function TrainerCoursesPage() {
  const router = useRouter();
  const { user, loading: authLoading } = useAuth();

  const [courses, setCourses] = useState<Course[]>([]);
  const [skillsTree, setSkillsTree] = useState<SkillNode[]>([]);
  const [loading, setLoading] = useState(true);

  // Create course modal state
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [createData, setCreateData] = useState({
    code: "",
    title: "",
    summary: "",
    skill_id: "",
    level: "beginner",
    duration_hours: 4,
    issues_certificate: true,
  });
  const [createLoading, setCreateLoading] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);

  // Upload Resource modal state
  const [selectedCourse, setSelectedCourse] = useState<Course | null>(null);
  const [showUploadModal, setShowUploadModal] = useState(false);
  const [uploadData, setUploadData] = useState({
    title: "",
    module_title: "Module 1",
    type: "video",
    is_mandatory: true,
  });
  const [selectedFile, setSelectedFile] = useState<File | null>(null);
  const [uploadProgress, setUploadProgress] = useState<number | null>(null);
  const [uploadError, setUploadError] = useState<string | null>(null);

  useEffect(() => {
    if (!authLoading && user && user.role !== "trainer" && user.role !== "admin") {
      router.push("/unauthorized");
    }
  }, [user, authLoading, router]);

  const loadTrainerCourses = async () => {
    try {
      setLoading(true);
      if (!user) return;
      const res = await api.courses.list({
        trainer_id: user.id,
        page_size: 50,
      });
      setCourses(res.items);
    } catch (err: any) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    api.profile.getSkillsTree().then(setSkillsTree).catch(console.error);
    if (user) {
      loadTrainerCourses();
    }
  }, [user]);

  const handleCreateCourse = async (e: React.FormEvent) => {
    e.preventDefault();
    setCreateError(null);
    setCreateLoading(true);

    try {
      await api.courses.create({
        code: createData.code,
        title: createData.title,
        summary: createData.summary || null,
        skill_id: createData.skill_id ? Number(createData.skill_id) : null,
        level: createData.level,
        duration_hours: Number(createData.duration_hours),
        issues_certificate: createData.issues_certificate,
      });
      setShowCreateModal(false);
      setCreateData({
        code: "",
        title: "",
        summary: "",
        skill_id: "",
        level: "beginner",
        duration_hours: 4,
        issues_certificate: true,
      });
      loadTrainerCourses();
    } catch (err: any) {
      setCreateError(err.message || "Failed to create course");
    } finally {
      setCreateLoading(false);
    }
  };

  const handlePublishCourse = async (courseId: string) => {
    if (!confirm("Are you sure you want to publish this course to the IMD catalogue?")) return;
    try {
      await api.courses.publish(courseId);
      loadTrainerCourses();
    } catch (err: any) {
      alert(err.message || "Failed to publish course");
    }
  };

  const handleUploadResource = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!selectedCourse || !selectedFile) return;

    setUploadError(null);
    setUploadProgress(20);

    try {
      // 1. Upload file
      setUploadProgress(50);
      const fileRes = await api.files.upload(selectedFile);
      setUploadProgress(80);

      // 2. Link to course
      await api.courses.addResource(selectedCourse.id, {
        title: uploadData.title,
        type: uploadData.type,
        file_id: fileRes.id,
        module_title: uploadData.module_title,
        position: 1,
        is_mandatory: uploadData.is_mandatory,
      });

      setUploadProgress(100);
      setTimeout(() => {
        setShowUploadModal(false);
        setSelectedFile(null);
        setUploadProgress(null);
        setUploadData({ title: "", module_title: "Module 1", type: "video", is_mandatory: true });
        loadTrainerCourses();
      }, 500);
    } catch (err: any) {
      setUploadError(err.message || "Failed to upload file");
      setUploadProgress(null);
    }
  };

  // Flatten leaf skills
  const leafSkills: { id: number; name: string }[] = [];
  skillsTree.forEach((root) => {
    if (root.children && root.children.length > 0) {
      root.children.forEach((c) => leafSkills.push({ id: c.id, name: `${root.name} > ${c.name}` }));
    } else {
      leafSkills.push({ id: root.id, name: root.name });
    }
  });

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-navy-900 tracking-tight">Trainer Course Management</h1>
          <p className="text-sm text-slate-500">
            Create courses, upload module materials, and publish approved curriculum to IMD personnel
          </p>
        </div>

        <button
          onClick={() => setShowCreateModal(true)}
          className="inline-flex items-center gap-2 rounded-lg bg-primary py-2.5 px-4 text-xs font-semibold text-white shadow-sm hover:bg-primary-hover transition-colors"
        >
          <Plus className="h-4 w-4" /> Create New Course
        </button>
      </div>

      {/* Courses List */}
      {loading ? (
        <div className="p-12 text-center text-slate-500 text-sm">Loading your courses...</div>
      ) : courses.length === 0 ? (
        <div className="bg-white rounded-xl p-12 text-center border border-slate-200 shadow-sm space-y-4">
          <BookOpen className="h-12 w-12 text-slate-300 mx-auto" />
          <div className="space-y-1">
            <h3 className="font-bold text-slate-800">No courses created yet</h3>
            <p className="text-xs text-slate-500 max-w-sm mx-auto">
              Start building your specialized meteorological curriculum by clicking &quot;Create New Course&quot;.
            </p>
          </div>
          <button
            onClick={() => setShowCreateModal(true)}
            className="inline-flex items-center gap-1.5 rounded-lg bg-primary py-2 px-4 text-xs font-semibold text-white"
          >
            <Plus className="h-3.5 w-3.5" /> Create Course Now
          </button>
        </div>
      ) : (
        <div className="space-y-4">
          {courses.map((course) => (
            <div
              key={course.id}
              className="bg-white p-5 rounded-xl border border-slate-200 shadow-sm flex flex-col md:flex-row md:items-center justify-between gap-4"
            >
              <div className="space-y-2">
                <div className="flex items-center gap-2">
                  <span className="text-xs font-bold text-primary bg-blue-50 px-2 py-0.5 rounded uppercase">
                    {course.code}
                  </span>
                  <span
                    className={`text-[10px] font-bold px-2 py-0.5 rounded uppercase ${
                      course.status === "published"
                        ? "bg-emerald-100 text-emerald-800"
                        : "bg-amber-100 text-amber-800"
                    }`}
                  >
                    {course.status}
                  </span>
                  <span className="text-xs text-slate-400 capitalize">{course.level} Level</span>
                </div>

                <h3 className="font-bold text-navy-900 text-base">{course.title}</h3>

                <p className="text-xs text-slate-600 line-clamp-1 max-w-2xl">{course.summary || "No description."}</p>

                <div className="flex items-center gap-4 text-xs text-slate-500">
                  <span>Subject: {course.skill_name || "General"}</span>
                  <span>Duration: {course.duration_hours || 4}h</span>
                  <span>Pass Threshold: {course.pass_criteria_pct}%</span>
                </div>
              </div>

              <div className="flex flex-wrap items-center gap-2 pt-2 md:pt-0">
                <button
                  onClick={() => {
                    setSelectedCourse(course);
                    setShowUploadModal(true);
                  }}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-slate-300 bg-white hover:bg-slate-50 py-2 px-3 text-xs font-semibold text-slate-700 transition-colors"
                >
                  <Upload className="h-3.5 w-3.5" /> Add Material
                </button>

                {course.status === "draft" && (
                  <button
                    onClick={() => handlePublishCourse(course.id)}
                    className="inline-flex items-center gap-1.5 rounded-lg bg-emerald-600 hover:bg-emerald-700 py-2 px-3 text-xs font-semibold text-white shadow-sm transition-colors"
                  >
                    <Send className="h-3.5 w-3.5" /> Publish
                  </button>
                )}

                <Link
                  href={`/courses/${course.id}`}
                  className="inline-flex items-center gap-1.5 rounded-lg bg-navy-900 hover:bg-navy-800 py-2 px-3 text-xs font-semibold text-white transition-colors"
                >
                  <Eye className="h-3.5 w-3.5" /> Preview
                </Link>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Modal: Create Course */}
      {showCreateModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="bg-white w-full max-w-lg rounded-xl p-6 shadow-xl space-y-4 max-h-[90vh] overflow-y-auto">
            <h3 className="text-lg font-bold text-navy-900">Create New Course</h3>

            {createError && (
              <div className="p-3 rounded-lg bg-red-50 border border-red-200 text-red-700 text-xs">
                {createError}
              </div>
            )}

            <form onSubmit={handleCreateCourse} className="space-y-4">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Course Code</label>
                  <input
                    type="text"
                    required
                    placeholder="e.g. IMD-DWR-101"
                    value={createData.code}
                    onChange={(e) => setCreateData({ ...createData, code: e.target.value })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  />
                </div>

                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Level</label>
                  <select
                    value={createData.level}
                    onChange={(e) => setCreateData({ ...createData, level: e.target.value })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  >
                    <option value="beginner">Beginner</option>
                    <option value="intermediate">Intermediate</option>
                    <option value="advanced">Advanced</option>
                  </select>
                </div>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Course Title</label>
                <input
                  type="text"
                  required
                  placeholder="e.g. Fundamentals of Doppler Weather Radar Operations"
                  value={createData.title}
                  onChange={(e) => setCreateData({ ...createData, title: e.target.value })}
                  className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Subject Discipline</label>
                <select
                  value={createData.skill_id}
                  onChange={(e) => setCreateData({ ...createData, skill_id: e.target.value })}
                  className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                >
                  <option value="">-- Choose Subject --</option>
                  {leafSkills.map((sk) => (
                    <option key={sk.id} value={sk.id}>
                      {sk.name}
                    </option>
                  ))}
                </select>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Course Overview</label>
                <textarea
                  rows={3}
                  placeholder="Describe learning objectives and curriculum..."
                  value={createData.summary}
                  onChange={(e) => setCreateData({ ...createData, summary: e.target.value })}
                  className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Est. Hours</label>
                  <input
                    type="number"
                    step="0.5"
                    value={createData.duration_hours}
                    onChange={(e) => setCreateData({ ...createData, duration_hours: Number(e.target.value) })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  />
                </div>

                <div className="flex items-center gap-2 pt-6">
                  <input
                    type="checkbox"
                    id="issues_cert"
                    checked={createData.issues_certificate}
                    onChange={(e) => setCreateData({ ...createData, issues_certificate: e.target.checked })}
                    className="rounded text-primary focus:ring-primary h-4 w-4"
                  />
                  <label htmlFor="issues_cert" className="text-xs font-medium text-slate-700">
                    Issues Certificate
                  </label>
                </div>
              </div>

              <div className="flex justify-end gap-2 pt-3 border-t border-slate-100">
                <button
                  type="button"
                  onClick={() => setShowCreateModal(false)}
                  className="rounded-lg border border-slate-300 px-4 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={createLoading}
                  className="rounded-lg bg-primary px-4 py-2 text-xs font-semibold text-white shadow-sm hover:bg-primary-hover disabled:opacity-50"
                >
                  {createLoading ? "Creating..." : "Save Course"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Modal: Upload Resource */}
      {showUploadModal && selectedCourse && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="bg-white w-full max-w-lg rounded-xl p-6 shadow-xl space-y-4">
            <div>
              <h3 className="text-lg font-bold text-navy-900">Upload Learning Material</h3>
              <p className="text-xs text-slate-500">Adding content to: {selectedCourse.title}</p>
            </div>

            {uploadError && (
              <div className="p-3 rounded-lg bg-red-50 border border-red-200 text-red-700 text-xs">
                {uploadError}
              </div>
            )}

            <form onSubmit={handleUploadResource} className="space-y-4">
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Resource Title</label>
                <input
                  type="text"
                  required
                  placeholder="e.g. Lecture 1: Radar Reflectivity and Echo Analysis"
                  value={uploadData.title}
                  onChange={(e) => setUploadData({ ...uploadData, title: e.target.value })}
                  className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Module Grouping</label>
                  <input
                    type="text"
                    required
                    placeholder="e.g. Module 1"
                    value={uploadData.module_title}
                    onChange={(e) => setUploadData({ ...uploadData, module_title: e.target.value })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  />
                </div>

                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Content Type</label>
                  <select
                    value={uploadData.type}
                    onChange={(e) => setUploadData({ ...uploadData, type: e.target.value })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  >
                    <option value="video">Video (MP4)</option>
                    <option value="pdf">Document / Lecture Note (PDF)</option>
                    <option value="presentation">Presentation (PPTX)</option>
                  </select>
                </div>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Select File</label>
                <input
                  type="file"
                  required
                  accept={uploadData.type === "video" ? "video/mp4" : ".pdf,.docx,.pptx"}
                  onChange={(e) => {
                    if (e.target.files && e.target.files[0]) {
                      setSelectedFile(e.target.files[0]);
                    }
                  }}
                  className="w-full text-xs text-slate-500 file:mr-3 file:py-2 file:px-3 file:rounded-lg file:border-0 file:text-xs file:font-semibold file:bg-blue-50 file:text-primary hover:file:bg-blue-100"
                />
                <p className="text-[10px] text-slate-400">
                  {uploadData.type === "video"
                    ? "MP4 video (up to 500 MB). Supports byte-range seeking."
                    : "PDF document (up to 25 MB)."}
                </p>
              </div>

              {/* Upload Progress Bar */}
              {uploadProgress !== null && (
                <div className="space-y-1.5 pt-2">
                  <div className="flex justify-between text-xs font-semibold text-slate-600">
                    <span>Uploading...</span>
                    <span>{uploadProgress}%</span>
                  </div>
                  <div className="w-full h-2 bg-slate-100 rounded-full overflow-hidden">
                    <div
                      className="h-full bg-primary transition-all duration-300 rounded-full"
                      style={{ width: `${uploadProgress}%` }}
                    ></div>
                  </div>
                </div>
              )}

              <div className="flex justify-end gap-2 pt-3 border-t border-slate-100">
                <button
                  type="button"
                  onClick={() => setShowUploadModal(false)}
                  className="rounded-lg border border-slate-300 px-4 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={uploadProgress !== null || !selectedFile}
                  className="rounded-lg bg-primary px-4 py-2 text-xs font-semibold text-white shadow-sm hover:bg-primary-hover disabled:opacity-50"
                >
                  Upload & Link
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
