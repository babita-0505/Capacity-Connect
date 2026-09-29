"use client";

import React, { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import {
  Award,
  Plus,
  Play,
  Pause,
  Users,
  Settings,
  Clock,
  CheckCircle2,
  AlertCircle,
  ShieldAlert,
  Search,
  Check,
  X,
  FileQuestion,
  TrendingUp
} from "lucide-react";
import {
  api,
  Assessment,
  QuestionItem,
  Course,
  SkillNode,
  AssessmentParticipationResponse
} from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function TrainerAssessmentsPage() {
  const router = useRouter();
  const { user, loading: authLoading } = useAuth();

  const [assessments, setAssessments] = useState<Assessment[]>([]);
  const [courses, setCourses] = useState<Course[]>([]);
  const [skillsTree, setSkillsTree] = useState<SkillNode[]>([]);
  const [loading, setLoading] = useState(true);

  // Create Assessment Modal
  const [showCreateModal, setShowCreateModal] = useState(false);
  const [createData, setCreateData] = useState({
    title: "",
    instructions: "",
    course_id: "",
    skill_id: "",
    duration_minutes: 20,
    pass_pct: 60,
    max_attempts: 1,
    shuffle_questions: true,
    lockdown_enabled: true,
  });
  const [createLoading, setCreateLoading] = useState(false);
  const [createError, setCreateError] = useState<string | null>(null);

  // Manage Questions Modal
  const [showQuestionsModal, setShowQuestionsModal] = useState(false);
  const [selectedAssessment, setSelectedAssessment] = useState<Assessment | null>(null);
  const [availableQuestions, setAvailableQuestions] = useState<QuestionItem[]>([]);
  const [questionsLoading, setQuestionsLoading] = useState(false);

  // Participation Details Modal
  const [showParticipationModal, setShowParticipationModal] = useState(false);
  const [participationData, setParticipationData] = useState<AssessmentParticipationResponse | null>(null);
  const [participationLoading, setParticipationLoading] = useState(false);

  useEffect(() => {
    if (!authLoading && user && user.role !== "trainer" && user.role !== "admin") {
      router.push("/unauthorized");
    }
  }, [user, authLoading, router]);

  const loadData = async () => {
    try {
      setLoading(true);
      const [assessRes, coursesRes, tree] = await Promise.all([
        api.assessments.list({ page_size: 50 }),
        api.courses.list({ trainer_id: user?.id, page_size: 50 }),
        api.profile.getSkillsTree().catch(() => []),
      ]);
      setAssessments(assessRes.items);
      setCourses(coursesRes.items);
      setSkillsTree(tree);
    } catch (err: any) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (user) {
      loadData();
    }
  }, [user]);

  const handleCreateAssessment = async (e: React.FormEvent) => {
    e.preventDefault();
    setCreateLoading(true);
    setCreateError(null);

    try {
      await api.assessments.create({
        title: createData.title,
        instructions: createData.instructions || null,
        course_id: createData.course_id || null,
        skill_id: createData.skill_id ? Number(createData.skill_id) : null,
        duration_minutes: Number(createData.duration_minutes),
        pass_pct: Number(createData.pass_pct),
        max_attempts: Number(createData.max_attempts),
        shuffle_questions: createData.shuffle_questions,
        lockdown_enabled: createData.lockdown_enabled,
      });

      setShowCreateModal(false);
      setCreateData({
        title: "",
        instructions: "",
        course_id: "",
        skill_id: "",
        duration_minutes: 20,
        pass_pct: 60,
        max_attempts: 1,
        shuffle_questions: true,
        lockdown_enabled: true,
      });
      loadData();
    } catch (err: any) {
      setCreateError(err.message || "Failed to create assessment");
    } finally {
      setCreateLoading(false);
    }
  };

  const handleToggleStatus = async (item: Assessment) => {
    try {
      if (item.status === "open") {
        await api.assessments.close(item.id);
      } else {
        await api.assessments.open(item.id);
      }
      loadData();
    } catch (err: any) {
      alert(err.message || "Failed to update assessment status");
    }
  };

  const openQuestionsModal = async (item: Assessment) => {
    setSelectedAssessment(item);
    setShowQuestionsModal(true);
    setQuestionsLoading(true);

    try {
      const [detail, qRes] = await Promise.all([
        api.assessments.get(item.id),
        api.questions.list({ status: "approved", page_size: 100 }),
      ]);
      setSelectedAssessment(detail);
      setAvailableQuestions(qRes.items);
    } catch (err) {
      console.error(err);
    } finally {
      setQuestionsLoading(false);
    }
  };

  const handleAddQuestionToTest = async (questionId: string) => {
    if (!selectedAssessment) return;
    try {
      await api.assessments.addQuestion(selectedAssessment.id, questionId);
      // Reload detail
      const detail = await api.assessments.get(selectedAssessment.id);
      setSelectedAssessment(detail);
      loadData();
    } catch (err: any) {
      alert(err.message || "Failed to add question");
    }
  };

  const handleRemoveQuestionFromTest = async (questionId: string) => {
    if (!selectedAssessment) return;
    try {
      await api.assessments.removeQuestion(selectedAssessment.id, questionId);
      // Reload detail
      const detail = await api.assessments.get(selectedAssessment.id);
      setSelectedAssessment(detail);
      loadData();
    } catch (err: any) {
      alert(err.message || "Failed to remove question");
    }
  };

  const openParticipationModal = async (item: Assessment) => {
    setSelectedAssessment(item);
    setShowParticipationModal(true);
    setParticipationLoading(true);

    try {
      const data = await api.assessments.participation(item.id);
      setParticipationData(data);
    } catch (err: any) {
      alert(err.message || "Failed to load participation data");
      setShowParticipationModal(false);
    } finally {
      setParticipationLoading(false);
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
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-navy-900 tracking-tight">Assessments & Test Builder</h1>
          <p className="text-sm text-slate-500">
            Design subject tests, configure timers & proctoring, and review learner participation metrics
          </p>
        </div>

        <button
          onClick={() => setShowCreateModal(true)}
          className="inline-flex items-center gap-1.5 rounded-lg bg-primary hover:bg-primary-hover text-white py-2.5 px-4 text-xs font-semibold shadow-sm transition-colors"
        >
          <Plus className="h-4 w-4" /> Build New Assessment
        </button>
      </div>

      {/* Assessments List */}
      {loading ? (
        <div className="p-12 text-center text-slate-500 text-sm">Loading assessments...</div>
      ) : assessments.length === 0 ? (
        <div className="bg-white rounded-xl p-12 text-center border border-slate-200 shadow-sm space-y-3">
          <Award className="h-10 w-10 text-slate-300 mx-auto" />
          <h3 className="font-bold text-slate-700">No assessments created yet</h3>
          <p className="text-xs text-slate-500 max-w-sm mx-auto">
            Build your first MCQ test, link it to your published course modules, and set passing thresholds.
          </p>
          <button
            onClick={() => setShowCreateModal(true)}
            className="inline-flex items-center gap-1.5 rounded-lg bg-primary py-2 px-4 text-xs font-semibold text-white shadow-sm"
          >
            <Plus className="h-3.5 w-3.5" /> Build Assessment Now
          </button>
        </div>
      ) : (
        <div className="space-y-4">
          {assessments.map((item) => (
            <div
              key={item.id}
              className="bg-white p-5 rounded-xl border border-slate-200 shadow-sm flex flex-col md:flex-row md:items-center justify-between gap-4 hover:border-slate-300 transition-colors"
            >
              <div className="space-y-2">
                <div className="flex flex-wrap items-center gap-2">
                  <span
                    className={`text-[10px] font-bold px-2.5 py-0.5 rounded uppercase ${
                      item.status === "open"
                        ? "bg-emerald-100 text-emerald-800"
                        : item.status === "draft"
                        ? "bg-amber-100 text-amber-800"
                        : "bg-slate-100 text-slate-600"
                    }`}
                  >
                    {item.status}
                  </span>

                  {item.skill_name && (
                    <span className="text-[10px] font-semibold text-navy-900 bg-slate-100 px-2 py-0.5 rounded">
                      {item.skill_name}
                    </span>
                  )}

                  {item.course_title ? (
                    <span className="text-[10px] font-semibold text-primary bg-blue-50 px-2 py-0.5 rounded">
                      Course: {item.course_title}
                    </span>
                  ) : (
                    <span className="text-[10px] font-semibold text-purple-700 bg-purple-50 px-2 py-0.5 rounded">
                      Standalone Assessment
                    </span>
                  )}
                </div>

                <h3 className="font-bold text-navy-900 text-base">{item.title}</h3>

                <div className="flex flex-wrap items-center gap-4 text-xs text-slate-500">
                  <span className="flex items-center gap-1">
                    <Clock className="h-3.5 w-3.5" />
                    {item.duration_minutes ? `${item.duration_minutes} Mins` : "Untimed"}
                  </span>
                  <span>Pass Threshold: {item.pass_pct}%</span>
                  <span>Max Attempts: {item.max_attempts}</span>
                  <span className="font-semibold text-slate-700">
                    {item.question_count || 0} Questions Assigned
                  </span>
                  <span>{item.completed_attempts || 0} Completed Attempts</span>
                </div>
              </div>

              {/* Actions */}
              <div className="flex flex-wrap items-center gap-2 pt-2 md:pt-0">
                <button
                  onClick={() => openQuestionsModal(item)}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-slate-300 bg-white hover:bg-slate-50 py-2 px-3 text-xs font-semibold text-slate-700 transition-colors"
                >
                  <FileQuestion className="h-3.5 w-3.5" /> Manage Questions ({item.question_count || 0})
                </button>

                <button
                  onClick={() => openParticipationModal(item)}
                  className="inline-flex items-center gap-1.5 rounded-lg border border-slate-300 bg-white hover:bg-slate-50 py-2 px-3 text-xs font-semibold text-slate-700 transition-colors"
                >
                  <Users className="h-3.5 w-3.5" /> Participation ({item.completed_attempts || 0})
                </button>

                <button
                  onClick={() => handleToggleStatus(item)}
                  className={`inline-flex items-center gap-1.5 rounded-lg py-2 px-3 text-xs font-semibold text-white shadow-xs transition-colors ${
                    item.status === "open"
                      ? "bg-amber-600 hover:bg-amber-700"
                      : "bg-emerald-600 hover:bg-emerald-700"
                  }`}
                >
                  {item.status === "open" ? (
                    <>
                      <Pause className="h-3.5 w-3.5" /> Close Test
                    </>
                  ) : (
                    <>
                      <Play className="h-3.5 w-3.5 fill-current" /> Open Test
                    </>
                  )}
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {/* Modal: Create Assessment */}
      {showCreateModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="bg-white rounded-2xl max-w-lg w-full p-6 shadow-2xl space-y-4 max-h-[90vh] overflow-y-auto">
            <h3 className="text-lg font-bold text-navy-900">Build New Assessment</h3>

            {createError && (
              <div className="p-3 rounded-lg bg-red-50 border border-red-200 text-red-700 text-xs">
                {createError}
              </div>
            )}

            <form onSubmit={handleCreateAssessment} className="space-y-4">
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Assessment Title</label>
                <input
                  type="text"
                  required
                  placeholder="e.g. Doppler Radar Reflectivity & Interpretation Quiz"
                  value={createData.title}
                  onChange={(e) => setCreateData({ ...createData, title: e.target.value })}
                  className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Link to Course</label>
                  <select
                    value={createData.course_id}
                    onChange={(e) => setCreateData({ ...createData, course_id: e.target.value })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  >
                    <option value="">Standalone (No Course)</option>
                    {courses.map((c) => (
                      <option key={c.id} value={c.id}>
                        {c.code} - {c.title}
                      </option>
                    ))}
                  </select>
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
              </div>

              <div className="grid grid-cols-3 gap-3">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Duration (Mins)</label>
                  <input
                    type="number"
                    min={1}
                    value={createData.duration_minutes}
                    onChange={(e) => setCreateData({ ...createData, duration_minutes: Number(e.target.value) })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  />
                </div>

                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Pass Pass %</label>
                  <input
                    type="number"
                    min={0}
                    max={100}
                    value={createData.pass_pct}
                    onChange={(e) => setCreateData({ ...createData, pass_pct: Number(e.target.value) })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  />
                </div>

                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Max Attempts</label>
                  <input
                    type="number"
                    min={1}
                    value={createData.max_attempts}
                    onChange={(e) => setCreateData({ ...createData, max_attempts: Number(e.target.value) })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  />
                </div>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Instructions for Learners</label>
                <textarea
                  rows={2}
                  placeholder="Answer all questions within the allotted duration..."
                  value={createData.instructions}
                  onChange={(e) => setCreateData({ ...createData, instructions: e.target.value })}
                  className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>

              <div className="space-y-2 pt-2 border-t border-slate-100">
                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="shuffle"
                    checked={createData.shuffle_questions}
                    onChange={(e) => setCreateData({ ...createData, shuffle_questions: e.target.checked })}
                    className="h-4 w-4 text-primary rounded"
                  />
                  <label htmlFor="shuffle" className="text-xs font-medium text-slate-700">
                    Shuffle questions randomly for each learner
                  </label>
                </div>

                <div className="flex items-center gap-2">
                  <input
                    type="checkbox"
                    id="lockdown"
                    checked={createData.lockdown_enabled}
                    onChange={(e) => setCreateData({ ...createData, lockdown_enabled: e.target.checked })}
                    className="h-4 w-4 text-primary rounded"
                  />
                  <label htmlFor="lockdown" className="text-xs font-medium text-slate-700">
                    Enable browser activity monitoring (tab switches, full-screen exits)
                  </label>
                </div>
              </div>

              <div className="flex justify-end gap-2 pt-3 border-t border-slate-100">
                <button
                  type="button"
                  onClick={() => setShowCreateModal(false)}
                  className="rounded-lg border border-slate-200 px-4 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={createLoading}
                  className="rounded-lg bg-primary hover:bg-primary-hover px-5 py-2 text-xs font-bold text-white shadow-sm disabled:opacity-50"
                >
                  {createLoading ? "Creating..." : "Save Assessment"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Modal: Manage Questions */}
      {showQuestionsModal && selectedAssessment && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="bg-white rounded-2xl max-w-3xl w-full p-6 shadow-2xl space-y-4 max-h-[90vh] overflow-y-auto">
            <div className="flex items-center justify-between border-b border-slate-100 pb-3">
              <div>
                <h3 className="text-lg font-bold text-navy-900">
                  Assign Questions to: {selectedAssessment.title}
                </h3>
                <p className="text-xs text-slate-500">
                  Select approved questions from the question bank to include in this test.
                </p>
              </div>
              <button
                onClick={() => setShowQuestionsModal(false)}
                className="p-1 rounded-lg text-slate-400 hover:text-navy-900"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            {questionsLoading ? (
              <div className="p-8 text-center text-xs text-slate-400">Loading questions...</div>
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                {/* Questions Currently in Test */}
                <div className="space-y-3">
                  <h4 className="text-xs font-bold text-navy-900 uppercase tracking-wider flex items-center justify-between">
                    <span>In This Test</span>
                    <span className="text-primary font-bold">
                      {selectedAssessment.questions?.length || 0} Questions
                    </span>
                  </h4>

                  <div className="space-y-2 max-h-[420px] overflow-y-auto pr-1">
                    {(selectedAssessment.questions || []).length === 0 ? (
                      <p className="text-xs text-slate-400 italic p-4 text-center border border-dashed rounded-lg">
                        No questions added yet. Choose from the available bank on the right.
                      </p>
                    ) : (
                      (selectedAssessment.questions || []).map((q, idx) => (
                        <div
                          key={q.id}
                          className="p-3 rounded-lg border border-slate-200 bg-white text-xs space-y-2 flex flex-col justify-between"
                        >
                          <div className="space-y-1">
                            <span className="text-slate-400 font-bold mr-1">Q{idx + 1}.</span>
                            <span className="font-semibold text-slate-800">{q.text}</span>
                          </div>
                          <div className="flex items-center justify-between border-t border-slate-100 pt-1.5 text-[11px] text-slate-500">
                            <span>{q.marks} Mark</span>
                            <button
                              onClick={() => handleRemoveQuestionFromTest(q.id)}
                              className="text-red-600 hover:underline font-semibold"
                            >
                              Remove
                            </button>
                          </div>
                        </div>
                      ))
                    )}
                  </div>
                </div>

                {/* Available Approved Questions in Bank */}
                <div className="space-y-3 border-t md:border-t-0 md:border-l border-slate-100 md:pl-4">
                  <h4 className="text-xs font-bold text-navy-900 uppercase tracking-wider">
                    Available in Question Bank
                  </h4>

                  <div className="space-y-2 max-h-[420px] overflow-y-auto pr-1">
                    {availableQuestions.map((q) => {
                      const alreadyInTest = (selectedAssessment.questions || []).some(
                        (existing) => existing.id === q.id
                      );

                      return (
                        <div
                          key={q.id}
                          className={`p-3 rounded-lg border text-xs space-y-2 ${
                            alreadyInTest ? "bg-slate-50 border-slate-200 opacity-60" : "bg-white border-slate-200"
                          }`}
                        >
                          <p className="font-semibold text-slate-800 line-clamp-2">{q.text}</p>
                          <div className="flex items-center justify-between text-[11px] text-slate-500 pt-1 border-t border-slate-100">
                            <span>{q.skill_name || "Meteorology"}</span>
                            {alreadyInTest ? (
                              <span className="text-emerald-700 font-semibold flex items-center gap-0.5">
                                <Check className="h-3 w-3" /> Added
                              </span>
                            ) : (
                              <button
                                onClick={() => handleAddQuestionToTest(q.id)}
                                className="text-primary hover:underline font-bold"
                              >
                                + Add to Test
                              </button>
                            )}
                          </div>
                        </div>
                      );
                    })}
                  </div>
                </div>
              </div>
            )}

            <div className="flex justify-end pt-3 border-t border-slate-100">
              <button
                type="button"
                onClick={() => setShowQuestionsModal(false)}
                className="rounded-lg bg-navy-900 text-white px-5 py-2 text-xs font-semibold"
              >
                Done
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Modal: Participation Details */}
      {showParticipationModal && selectedAssessment && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="bg-white rounded-2xl max-w-3xl w-full p-6 shadow-2xl space-y-4 max-h-[90vh] overflow-y-auto">
            <div className="flex items-center justify-between border-b border-slate-100 pb-3">
              <div>
                <h3 className="text-lg font-bold text-navy-900">
                  Learner Participation: {selectedAssessment.title}
                </h3>
                <p className="text-xs text-slate-500">
                  Summary stats and proctoring activity from all test sessions
                </p>
              </div>
              <button
                onClick={() => setShowParticipationModal(false)}
                className="p-1 rounded-lg text-slate-400 hover:text-navy-900"
              >
                <X className="h-5 w-5" />
              </button>
            </div>

            {participationLoading ? (
              <div className="p-8 text-center text-xs text-slate-400">Loading participation data...</div>
            ) : participationData ? (
              <div className="space-y-4">
                {/* Stats Row */}
                <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-xs">
                  <div className="p-3 bg-slate-50 rounded-xl border border-slate-200">
                    <span className="text-[10px] uppercase text-slate-500 block">Submissions</span>
                    <strong className="text-base text-navy-900">{participationData.attempts.length}</strong>
                  </div>
                  <div className="p-3 bg-slate-50 rounded-xl border border-slate-200">
                    <span className="text-[10px] uppercase text-slate-500 block">Avg Score</span>
                    <strong className="text-base text-navy-900">
                      {participationData.stats.average_score ||
                        (participationData.attempts.length
                          ? Math.round(
                              participationData.attempts.reduce((acc, a) => acc + (a.percentage || 0), 0) /
                                participationData.attempts.length
                            )
                          : 0)}
                      %
                    </strong>
                  </div>
                  <div className="p-3 bg-slate-50 rounded-xl border border-slate-200">
                    <span className="text-[10px] uppercase text-slate-500 block">Pass Rate</span>
                    <strong className="text-base text-emerald-700">
                      {participationData.stats.pass_rate_pct ||
                        (participationData.attempts.length
                          ? Math.round(
                              (100 * participationData.attempts.filter((a) => a.passed).length) /
                                participationData.attempts.length
                            )
                          : 0)}
                      %
                    </strong>
                  </div>
                  <div className="p-3 bg-slate-50 rounded-xl border border-slate-200">
                    <span className="text-[10px] uppercase text-slate-500 block">Avg Tab Switches</span>
                    <strong className="text-base text-amber-700">
                      {participationData.attempts.length
                        ? (
                            participationData.attempts.reduce((acc, a) => acc + (a.tab_switch_count || 0), 0) /
                            participationData.attempts.length
                          ).toFixed(1)
                        : 0}
                    </strong>
                  </div>
                </div>

                {/* Trainee Submissions Table */}
                <div className="border border-slate-200 rounded-xl overflow-hidden">
                  <table className="w-full text-left text-xs">
                    <thead className="bg-slate-50 text-slate-600 font-semibold border-b border-slate-200">
                      <tr>
                        <th className="p-3">Learner</th>
                        <th className="p-3">Department</th>
                        <th className="p-3">Score</th>
                        <th className="p-3">Status</th>
                        <th className="p-3">Proctor Signals</th>
                        <th className="p-3">Submitted</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100">
                      {participationData.attempts.length === 0 ? (
                        <tr>
                          <td colSpan={6} className="p-6 text-center text-slate-400 italic">
                            No learners have submitted attempts for this test yet.
                          </td>
                        </tr>
                      ) : (
                        participationData.attempts.map((att) => (
                          <tr key={att.id} className="hover:bg-slate-50">
                            <td className="p-3 font-semibold text-slate-800">{att.full_name}</td>
                            <td className="p-3 text-slate-500">{att.department || "IMD"}</td>
                            <td className="p-3 font-bold text-navy-900">{att.percentage}%</td>
                            <td className="p-3">
                              <span
                                className={`px-2 py-0.5 rounded text-[10px] font-bold ${
                                  att.passed ? "bg-emerald-100 text-emerald-800" : "bg-red-100 text-red-800"
                                }`}
                              >
                                {att.passed ? "PASSED" : "FAILED"}
                              </span>
                            </td>
                            <td className="p-3 text-slate-600">
                              <span
                                className={
                                  att.tab_switch_count > 0 ? "text-amber-700 font-semibold" : "text-slate-400"
                                }
                              >
                                {att.tab_switch_count} tab switches
                              </span>
                            </td>
                            <td className="p-3 text-slate-400">
                              {att.submitted_at ? new Date(att.submitted_at).toLocaleDateString() : "In progress"}
                            </td>
                          </tr>
                        ))
                      )}
                    </tbody>
                  </table>
                </div>
              </div>
            ) : null}

            <div className="flex justify-end pt-3 border-t border-slate-100">
              <button
                type="button"
                onClick={() => setShowParticipationModal(false)}
                className="rounded-lg bg-navy-900 text-white px-5 py-2 text-xs font-semibold"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
