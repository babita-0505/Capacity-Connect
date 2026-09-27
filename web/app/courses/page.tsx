"use client";

import React, { useEffect, useState } from "react";
import Link from "next/link";
import { 
  Compass, 
  Search, 
  Clock, 
  Award, 
  User as UserIcon, 
  ArrowRight,
  BookOpen
} from "lucide-react";
import { api, Course, SkillNode } from "@/lib/api";

export default function CoursesPage() {
  const [courses, setCourses] = useState<Course[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [skillsTree, setSkillsTree] = useState<SkillNode[]>([]);

  const [searchQuery, setSearchQuery] = useState("");
  const [selectedSkill, setSelectedSkill] = useState<string>("");
  const [selectedLevel, setSelectedLevel] = useState<string>("");
  const [loading, setLoading] = useState(true);

  const loadCourses = async () => {
    try {
      setLoading(true);
      const res = await api.courses.list({
        q: searchQuery || undefined,
        skill_id: selectedSkill ? Number(selectedSkill) : undefined,
        level: selectedLevel || undefined,
        page,
        page_size: 12,
      });
      setCourses(res.items);
      setTotal(res.total);
    } catch (err: any) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    api.profile.getSkillsTree().then(setSkillsTree).catch(console.error);
  }, []);

  useEffect(() => {
    loadCourses();
  }, [page, selectedSkill, selectedLevel]);

  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
    setPage(1);
    loadCourses();
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
      <div>
        <h1 className="text-2xl font-bold text-navy-900 tracking-tight">Course Catalogue</h1>
        <p className="text-sm text-slate-500">
          Operational meteorological training, instruments calibration, and forecasting modules
        </p>
      </div>

      {/* Filter and Search Bar */}
      <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-sm flex flex-col md:flex-row gap-3">
        <form onSubmit={handleSearch} className="flex-1 relative">
          <Search className="absolute left-3 top-2.5 h-4 w-4 text-slate-400" />
          <input
            type="text"
            placeholder="Search by title, subject, or code..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="w-full rounded-lg border border-slate-300 pl-9 pr-3 py-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
          />
        </form>

        <div className="flex flex-wrap gap-2">
          <select
            value={selectedSkill}
            onChange={(e) => {
              setSelectedSkill(e.target.value);
              setPage(1);
            }}
            className="rounded-lg border border-slate-300 py-2 px-3 text-xs focus:ring-2 focus:ring-primary focus:outline-none bg-white"
          >
            <option value="">All Disciplines</option>
            {leafSkills.map((sk) => (
              <option key={sk.id} value={sk.id}>
                {sk.name}
              </option>
            ))}
          </select>

          <select
            value={selectedLevel}
            onChange={(e) => {
              setSelectedLevel(e.target.value);
              setPage(1);
            }}
            className="rounded-lg border border-slate-300 py-2 px-3 text-xs focus:ring-2 focus:ring-primary focus:outline-none bg-white"
          >
            <option value="">All Levels</option>
            <option value="beginner">Beginner</option>
            <option value="intermediate">Intermediate</option>
            <option value="advanced">Advanced</option>
          </select>

          <button
            onClick={() => {
              setSearchQuery("");
              setSelectedSkill("");
              setSelectedLevel("");
              setPage(1);
            }}
            className="rounded-lg border border-slate-200 bg-slate-50 hover:bg-slate-100 py-2 px-3 text-xs font-semibold text-slate-600 transition-colors"
          >
            Reset
          </button>
        </div>
      </div>

      {/* Courses Grid */}
      {loading ? (
        <div className="p-12 text-center text-slate-500 text-sm">Loading course catalogue...</div>
      ) : courses.length === 0 ? (
        <div className="bg-white rounded-xl p-12 text-center border border-slate-200 shadow-sm space-y-2">
          <BookOpen className="h-10 w-10 text-slate-300 mx-auto" />
          <p className="font-semibold text-slate-700">No courses match your criteria</p>
          <p className="text-xs text-slate-500">Try adjusting your keyword search or discipline filter.</p>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
          {courses.map((course) => (
            <div
              key={course.id}
              className="bg-white rounded-xl border border-slate-200 shadow-sm hover:shadow-md transition-shadow flex flex-col overflow-hidden"
            >
              <div className="p-5 flex-1 space-y-3">
                <div className="flex justify-between items-start gap-2">
                  <span className="text-[11px] font-bold text-primary bg-blue-50 px-2 py-0.5 rounded uppercase">
                    {course.code}
                  </span>
                  <span
                    className={`text-[10px] font-semibold px-2 py-0.5 rounded capitalize ${
                      course.level === "advanced"
                        ? "bg-purple-100 text-purple-700"
                        : course.level === "intermediate"
                        ? "bg-blue-100 text-blue-700"
                        : "bg-emerald-100 text-emerald-700"
                    }`}
                  >
                    {course.level}
                  </span>
                </div>

                <h3 className="font-bold text-navy-900 text-base leading-snug line-clamp-2">
                  {course.title}
                </h3>

                {course.summary && (
                  <p className="text-xs text-slate-600 line-clamp-3 leading-relaxed">
                    {course.summary}
                  </p>
                )}

                <div className="pt-2 flex flex-wrap gap-y-2 text-xs text-slate-500 border-t border-slate-100">
                  <div className="w-full flex items-center gap-1.5 text-slate-700 font-medium">
                    <UserIcon className="h-3.5 w-3.5 text-slate-400" />
                    <span className="truncate">{course.trainer_name || "Lead Scientist"}</span>
                  </div>

                  <div className="w-1/2 flex items-center gap-1.5">
                    <Clock className="h-3.5 w-3.5 text-slate-400" />
                    <span>{course.duration_hours || 4} hrs</span>
                  </div>

                  {course.issues_certificate && (
                    <div className="w-1/2 flex items-center gap-1.5 text-emerald-700">
                      <Award className="h-3.5 w-3.5" />
                      <span>Certified</span>
                    </div>
                  )}
                </div>
              </div>

              <div className="p-3 bg-slate-50 border-t border-slate-100 flex items-center justify-between">
                <span className="text-[11px] text-slate-500 font-medium truncate max-w-[160px]">
                  {course.skill_name || "General Meteorology"}
                </span>

                <Link
                  href={`/courses/${course.id}`}
                  className="inline-flex items-center gap-1 text-xs font-semibold text-primary hover:text-primary-hover"
                >
                  View Course <ArrowRight className="h-3.5 w-3.5" />
                </Link>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
