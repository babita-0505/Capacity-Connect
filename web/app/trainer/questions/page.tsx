"use client";

import React, { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import {
  Plus,
  Search,
  Sparkles,
  CheckCircle2,
  Trash2,
  Edit2,
  FileText,
  Star,
  Check,
  AlertCircle,
  HelpCircle,
  Clock
} from "lucide-react";
import { api, QuestionItem, SkillNode, Course } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function QuestionBankPage() {
  const router = useRouter();
  const { user, loading: authLoading } = useAuth();

  const [questions, setQuestions] = useState<QuestionItem[]>([]);
  const [skillsTree, setSkillsTree] = useState<SkillNode[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(true);

  // Filters
  const [searchQuery, setSearchQuery] = useState("");
  const [selectedSkill, setSelectedSkill] = useState<string>("");
  const [selectedStatus, setSelectedStatus] = useState<string>("");
  const [selectedDifficulty, setSelectedDifficulty] = useState<string>("");

  // Create / Edit modal state
  const [showEditorModal, setShowEditorModal] = useState(false);
  const [editingQuestionId, setEditingQuestionId] = useState<string | null>(null);
  const [editorData, setEditorData] = useState({
    skill_id: "",
    text: "",
    explanation: "",
    difficulty: 2,
    options: [
      { text: "", is_correct: true },
      { text: "", is_correct: false },
      { text: "", is_correct: false },
      { text: "", is_correct: false },
    ],
  });
  const [editorLoading, setEditorLoading] = useState(false);
  const [editorError, setEditorError] = useState<string | null>(null);

  // PDF Generator modal state
  const [showGenerateModal, setShowGenerateModal] = useState(false);
  const [genResourceId, setGenResourceId] = useState("");
  const [genCount, setGenCount] = useState(5);
  const [genDifficulty, setGenDifficulty] = useState(2);
  const [genMessage, setGenMessage] = useState("");
  const [genBusy, setGenBusy] = useState(false);

  useEffect(() => {
    if (!authLoading && user && user.role !== "trainer" && user.role !== "admin") {
      router.push("/unauthorized");
    }
  }, [user, authLoading, router]);

  const loadQuestions = async () => {
    try {
      setLoading(true);
      const res = await api.questions.list({
        skill_id: selectedSkill ? Number(selectedSkill) : undefined,
        status: selectedStatus || undefined,
        q: searchQuery || undefined,
        difficulty: selectedDifficulty ? Number(selectedDifficulty) : undefined,
        page,
        page_size: 15,
      });
      setQuestions(res.items);
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
    if (user) {
      loadQuestions();
    }
  }, [user, page, selectedSkill, selectedStatus, selectedDifficulty]);

  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
    setPage(1);
    loadQuestions();
  };

  const handleApprove = async (id: string) => {
    try {
      await api.questions.approve(id);
      loadQuestions();
    } catch (err: any) {
      alert(err.message || "Failed to approve question");
    }
  };

  const handleDelete = async (id: string) => {
    if (!confirm("Are you sure you want to remove this question?")) return;
    try {
      await api.questions.delete(id);
      loadQuestions();
    } catch (err: any) {
      alert(err.message || "Failed to delete question");
    }
  };

  const openCreateModal = () => {
    setEditingQuestionId(null);
    setEditorData({
      skill_id: leafSkills[0]?.id ? String(leafSkills[0].id) : "",
      text: "",
      explanation: "",
      difficulty: 2,
      options: [
        { text: "", is_correct: true },
        { text: "", is_correct: false },
        { text: "", is_correct: false },
        { text: "", is_correct: false },
      ],
    });
    setEditorError(null);
    setShowEditorModal(true);
  };

  const openEditModal = (q: QuestionItem) => {
    setEditingQuestionId(q.id);
    const opts = (q.options || []).map((o) => ({
      text: o.text,
      is_correct: Boolean(o.is_correct),
    }));
    while (opts.length < 4) {
      opts.push({ text: "", is_correct: false });
    }
    setEditorData({
      skill_id: String(q.skill_id),
      text: q.text,
      explanation: q.explanation || "",
      difficulty: q.difficulty || 2,
      options: opts,
    });
    setEditorError(null);
    setShowEditorModal(true);
  };

  const handleSaveQuestion = async (e: React.FormEvent) => {
    e.preventDefault();
    setEditorError(null);

    // Validation
    if (!editorData.skill_id) {
      setEditorError("Please select a subject discipline");
      return;
    }
    if (editorData.options.some((o) => !o.text.trim())) {
      setEditorError("All 4 option choices must have text");
      return;
    }
    if (editorData.options.filter((o) => o.is_correct).length !== 1) {
      setEditorError("Exactly one option must be marked as correct");
      return;
    }

    setEditorLoading(true);
    try {
      const payload = {
        skill_id: Number(editorData.skill_id),
        text: editorData.text,
        explanation: editorData.explanation || null,
        difficulty: Number(editorData.difficulty),
        options: editorData.options,
      };

      if (editingQuestionId) {
        await api.questions.update(editingQuestionId, payload);
      } else {
        await api.questions.create(payload);
      }

      setShowEditorModal(false);
      loadQuestions();
    } catch (err: any) {
      setEditorError(err.message || "Failed to save question");
    } finally {
      setEditorLoading(false);
    }
  };

  const handleGenerateMCQs = async (e: React.FormEvent) => {
    e.preventDefault();
    setGenBusy(true);
    setGenMessage("");

    try {
      const response = await fetch(`/api/resources/${genResourceId.trim()}/generate-mcqs`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "include",
        body: JSON.stringify({ count: genCount, difficulty: genDifficulty }),
      });
      const data = await response.json();
      if (!response.ok) throw new Error(data.detail || "Unable to start generation");

      if (data.cached) {
        setGenMessage("Draft questions loaded instantly from cache! Refreshing bank...");
        setTimeout(() => {
          setShowGenerateModal(false);
          setGenBusy(false);
          setGenMessage("");
          loadQuestions();
        }, 1500);
      } else {
        setGenMessage("Generation queued in background. Polling for completion...");
        const poll = async () => {
          try {
            const state = await api.competency.job(data.job_id);
            if (state.status === "done") {
              setGenMessage("Draft questions generated successfully! Refreshing bank...");
              setTimeout(() => {
                setShowGenerateModal(false);
                setGenBusy(false);
                setGenMessage("");
                loadQuestions();
              }, 1200);
            } else if (state.status === "failed") {
              setGenMessage(state.error || "Generation failed.");
              setGenBusy(false);
            } else {
              window.setTimeout(poll, 2000);
            }
          } catch (e) {
            setGenBusy(false);
          }
        };
        poll();
      }
    } catch (err: any) {
      setGenMessage(err.message || "Failed to trigger generation");
      setGenBusy(false);
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
      {/* Header bar */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-navy-900 tracking-tight">Question Bank</h1>
          <p className="text-sm text-slate-500">
            Author, review, and manage verified meteorological MCQ questions for timed assessments
          </p>
        </div>

        <div className="flex items-center gap-2">
          <button
            onClick={() => setShowGenerateModal(true)}
            className="inline-flex items-center gap-1.5 rounded-lg border border-purple-200 bg-purple-50 hover:bg-purple-100 text-purple-700 py-2.5 px-3.5 text-xs font-semibold shadow-xs transition-colors"
          >
            <Sparkles className="h-4 w-4 text-purple-600" /> Generate from PDF
          </button>

          <button
            onClick={openCreateModal}
            className="inline-flex items-center gap-1.5 rounded-lg bg-primary hover:bg-primary-hover text-white py-2.5 px-4 text-xs font-semibold shadow-sm transition-colors"
          >
            <Plus className="h-4 w-4" /> Create Question
          </button>
        </div>
      </div>

      {/* Filter and Search Bar */}
      <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-sm flex flex-col md:flex-row gap-3">
        <form onSubmit={handleSearch} className="flex-1 relative">
          <Search className="absolute left-3 top-2.5 h-4 w-4 text-slate-400" />
          <input
            type="text"
            placeholder="Search questions by text or concept..."
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
            className="rounded-lg border border-slate-300 py-2 px-3 text-xs bg-white focus:ring-2 focus:ring-primary focus:outline-none"
          >
            <option value="">All Disciplines</option>
            {leafSkills.map((sk) => (
              <option key={sk.id} value={sk.id}>
                {sk.name}
              </option>
            ))}
          </select>

          <select
            value={selectedStatus}
            onChange={(e) => {
              setSelectedStatus(e.target.value);
              setPage(1);
            }}
            className="rounded-lg border border-slate-300 py-2 px-3 text-xs bg-white focus:ring-2 focus:ring-primary focus:outline-none"
          >
            <option value="">All Statuses</option>
            <option value="draft">Draft (Review Needed)</option>
            <option value="approved">Approved (Live)</option>
            <option value="retired">Retired</option>
          </select>

          <select
            value={selectedDifficulty}
            onChange={(e) => {
              setSelectedDifficulty(e.target.value);
              setPage(1);
            }}
            className="rounded-lg border border-slate-300 py-2 px-3 text-xs bg-white focus:ring-2 focus:ring-primary focus:outline-none"
          >
            <option value="">All Difficulties</option>
            <option value="1">Level 1 (Basic)</option>
            <option value="2">Level 2 (Standard)</option>
            <option value="3">Level 3 (Intermediate)</option>
            <option value="4">Level 4 (Advanced)</option>
            <option value="5">Level 5 (Expert)</option>
          </select>

          <button
            onClick={() => {
              setSearchQuery("");
              setSelectedSkill("");
              setSelectedStatus("");
              setSelectedDifficulty("");
              setPage(1);
            }}
            className="rounded-lg border border-slate-200 bg-slate-50 hover:bg-slate-100 py-2 px-3 text-xs font-semibold text-slate-600 transition-colors"
          >
            Reset
          </button>
        </div>
      </div>

      {/* Questions List */}
      {loading ? (
        <div className="p-12 text-center text-slate-500 text-sm">Loading questions...</div>
      ) : questions.length === 0 ? (
        <div className="bg-white rounded-xl p-12 text-center border border-slate-200 shadow-sm space-y-3">
          <HelpCircle className="h-10 w-10 text-slate-300 mx-auto" />
          <h3 className="font-bold text-slate-700">No questions found</h3>
          <p className="text-xs text-slate-500 max-w-sm mx-auto">
            Create your first question manually or use the AI/rule-based generator to extract questions from lecture notes.
          </p>
          <button
            onClick={openCreateModal}
            className="inline-flex items-center gap-1.5 rounded-lg bg-primary py-2 px-4 text-xs font-semibold text-white"
          >
            <Plus className="h-3.5 w-3.5" /> Create Question
          </button>
        </div>
      ) : (
        <div className="space-y-3">
          {questions.map((q, idx) => (
            <div
              key={q.id}
              className="bg-white p-5 rounded-xl border border-slate-200 shadow-sm space-y-4 hover:border-slate-300 transition-colors"
            >
              <div className="flex flex-col sm:flex-row sm:items-start justify-between gap-3">
                <div className="space-y-1.5 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-[10px] font-bold text-navy-900 bg-slate-100 px-2.5 py-0.5 rounded">
                      {q.skill_name || "Meteorology"}
                    </span>

                    <span
                      className={`text-[10px] font-bold px-2 py-0.5 rounded uppercase ${
                        q.status === "approved"
                          ? "bg-emerald-100 text-emerald-800"
                          : q.status === "draft"
                          ? "bg-amber-100 text-amber-800"
                          : "bg-slate-100 text-slate-600"
                      }`}
                    >
                      {q.status}
                    </span>

                    <span
                      className={`text-[10px] font-semibold px-2 py-0.5 rounded ${
                        q.generation_method === "llm"
                          ? "bg-purple-100 text-purple-700"
                          : q.generation_method === "rule_based"
                          ? "bg-blue-100 text-blue-700"
                          : "bg-slate-100 text-slate-600"
                      }`}
                    >
                      {q.generation_method === "llm"
                        ? "AI Generated"
                        : q.generation_method === "rule_based"
                        ? "Rule-Based"
                        : "Manual"}
                    </span>

                    <div className="flex items-center gap-0.5 text-amber-500 text-xs pl-2">
                      {Array.from({ length: q.difficulty || 2 }).map((_, i) => (
                        <Star key={i} className="h-3 w-3 fill-current" />
                      ))}
                    </div>
                  </div>

                  <h3 className="text-sm sm:text-base font-semibold text-slate-900 leading-snug pt-1">
                    {q.text}
                  </h3>
                </div>

                {/* Actions */}
                <div className="flex items-center gap-2 flex-shrink-0">
                  {q.status === "draft" && (
                    <button
                      onClick={() => handleApprove(q.id)}
                      className="inline-flex items-center gap-1 rounded-lg bg-emerald-600 hover:bg-emerald-700 text-white px-3 py-1.5 text-xs font-semibold shadow-xs transition-colors"
                      title="Approve for test builder"
                    >
                      <CheckCircle2 className="h-3.5 w-3.5" /> Approve
                    </button>
                  )}

                  <button
                    onClick={() => openEditModal(q)}
                    className="p-1.5 rounded-lg border border-slate-200 text-slate-600 hover:bg-slate-50 transition-colors"
                    title="Edit question"
                  >
                    <Edit2 className="h-3.5 w-3.5" />
                  </button>

                  <button
                    onClick={() => handleDelete(q.id)}
                    className="p-1.5 rounded-lg border border-slate-200 text-slate-400 hover:text-red-600 hover:bg-red-50 transition-colors"
                    title="Remove question"
                  >
                    <Trash2 className="h-3.5 w-3.5" />
                  </button>
                </div>
              </div>

              {/* 4 Options Grid */}
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 text-xs">
                {(q.options || []).map((opt) => (
                  <div
                    key={opt.id}
                    className={`p-2.5 rounded-lg border flex items-center justify-between gap-2 ${
                      opt.is_correct
                        ? "bg-emerald-50 border-emerald-300 text-emerald-900 font-semibold"
                        : "bg-slate-50 border-slate-200 text-slate-700"
                    }`}
                  >
                    <span className="break-words">{opt.text}</span>
                    {opt.is_correct && (
                      <span className="text-[10px] uppercase font-bold text-emerald-700 bg-emerald-100 px-1.5 py-0.2 rounded">
                        Correct
                      </span>
                    )}
                  </div>
                ))}
              </div>

              {q.explanation && (
                <p className="text-[11px] text-slate-500 bg-slate-50 p-2.5 rounded-lg">
                  <strong>Explanation: </strong> {q.explanation}
                </p>
              )}
            </div>
          ))}
        </div>
      )}

      {/* Modal: Create / Edit Question */}
      {showEditorModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="bg-white rounded-2xl max-w-xl w-full p-6 shadow-2xl space-y-4 max-h-[90vh] overflow-y-auto">
            <h3 className="text-lg font-bold text-navy-900">
              {editingQuestionId ? "Edit Question" : "Create New Question"}
            </h3>

            {editorError && (
              <div className="p-3 rounded-lg bg-red-50 border border-red-200 text-red-700 text-xs">
                {editorError}
              </div>
            )}

            <form onSubmit={handleSaveQuestion} className="space-y-4">
              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Discipline / Skill</label>
                  <select
                    required
                    value={editorData.skill_id}
                    onChange={(e) => setEditorData({ ...editorData, skill_id: e.target.value })}
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
                  <label className="text-xs font-semibold text-slate-700">Difficulty (1-5)</label>
                  <select
                    value={editorData.difficulty}
                    onChange={(e) => setEditorData({ ...editorData, difficulty: Number(e.target.value) })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  >
                    <option value={1}>Level 1 - Basic</option>
                    <option value={2}>Level 2 - Standard</option>
                    <option value={3}>Level 3 - Intermediate</option>
                    <option value={4}>Level 4 - Advanced</option>
                    <option value={5}>Level 5 - Expert</option>
                  </select>
                </div>
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Question Statement</label>
                <textarea
                  rows={3}
                  required
                  placeholder="e.g. Which wavelength band is conventionally used in IMD S-band Doppler Weather Radars?"
                  value={editorData.text}
                  onChange={(e) => setEditorData({ ...editorData, text: e.target.value })}
                  className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>

              {/* 4 Options */}
              <div className="space-y-2">
                <label className="text-xs font-semibold text-slate-700 block">
                  Four Multiple-Choice Options (Select the correct answer)
                </label>
                {editorData.options.map((opt, i) => (
                  <div key={i} className="flex items-center gap-2">
                    <input
                      type="radio"
                      name="correct_option"
                      checked={opt.is_correct}
                      onChange={() => {
                        const newOpts = editorData.options.map((o, idx) => ({
                          ...o,
                          is_correct: idx === i,
                        }));
                        setEditorData({ ...editorData, options: newOpts });
                      }}
                      className="h-4 w-4 text-primary focus:ring-primary cursor-pointer"
                      title="Mark as correct answer"
                    />
                    <input
                      type="text"
                      required
                      placeholder={`Option ${i + 1}`}
                      value={opt.text}
                      onChange={(e) => {
                        const newOpts = [...editorData.options];
                        newOpts[i].text = e.target.value;
                        setEditorData({ ...editorData, options: newOpts });
                      }}
                      className={`flex-1 rounded-lg border p-2 text-xs focus:outline-none ${
                        opt.is_correct
                          ? "border-emerald-400 bg-emerald-50/40 focus:ring-2 focus:ring-emerald-500"
                          : "border-slate-300 focus:ring-2 focus:ring-primary"
                      }`}
                    />
                  </div>
                ))}
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Answer Explanation (Shown in review)</label>
                <textarea
                  rows={2}
                  placeholder="Detailed scientific rationale for the correct answer..."
                  value={editorData.explanation}
                  onChange={(e) => setEditorData({ ...editorData, explanation: e.target.value })}
                  className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>

              <div className="flex justify-end gap-2 pt-3 border-t border-slate-100">
                <button
                  type="button"
                  onClick={() => setShowEditorModal(false)}
                  className="rounded-lg border border-slate-200 px-4 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  disabled={editorLoading}
                  className="rounded-lg bg-primary hover:bg-primary-hover px-5 py-2 text-xs font-bold text-white shadow-sm disabled:opacity-50"
                >
                  {editorLoading ? "Saving..." : "Save Question"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}

      {/* Modal: PDF Question Generator */}
      {showGenerateModal && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="bg-white rounded-2xl max-w-md w-full p-6 shadow-2xl space-y-4">
            <div className="space-y-1">
              <div className="flex items-center gap-2">
                <Sparkles className="h-5 w-5 text-purple-600" />
                <h3 className="text-base font-bold text-navy-900">Generate Draft MCQs from PDF</h3>
              </div>
              <p className="text-xs text-slate-500">
                Uses keyword extraction and AI assistance to create draft questions from your course lecture notes.
              </p>
            </div>

            <form onSubmit={handleGenerateMCQs} className="space-y-3">
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">PDF Resource UUID</label>
                <input
                  type="text"
                  required
                  placeholder="Paste resource UUID from your course module..."
                  value={genResourceId}
                  onChange={(e) => setGenResourceId(e.target.value)}
                  className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-purple-500 focus:outline-none"
                />
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Number of Questions</label>
                  <input
                    type="number"
                    min={1}
                    max={20}
                    value={genCount}
                    onChange={(e) => setGenCount(Number(e.target.value))}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-purple-500 focus:outline-none"
                  />
                </div>

                <div className="space-y-1">
                  <label className="text-xs font-semibold text-slate-700">Target Difficulty</label>
                  <select
                    value={genDifficulty}
                    onChange={(e) => setGenDifficulty(Number(e.target.value))}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-purple-500 focus:outline-none"
                  >
                    <option value={1}>Level 1 - Basic</option>
                    <option value={2}>Level 2 - Standard</option>
                    <option value={3}>Level 3 - Intermediate</option>
                    <option value={4}>Level 4 - Advanced</option>
                  </select>
                </div>
              </div>

              {genMessage && (
                <div className="p-3 rounded-lg bg-purple-50 border border-purple-200 text-purple-900 text-xs space-y-1">
                  <p>{genMessage}</p>
                </div>
              )}

              <div className="flex justify-end gap-2 pt-3 border-t border-slate-100">
                <button
                  type="button"
                  disabled={genBusy}
                  onClick={() => setShowGenerateModal(false)}
                  className="rounded-lg border border-slate-200 px-4 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50"
                >
                  Close
                </button>
                <button
                  type="submit"
                  disabled={genBusy || !genResourceId.trim()}
                  className="rounded-lg bg-purple-600 hover:bg-purple-700 px-4 py-2 text-xs font-bold text-white shadow-sm disabled:opacity-50"
                >
                  {genBusy ? "Generating..." : "Start Generation"}
                </button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
