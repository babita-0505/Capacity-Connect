"use client";

import React, { useEffect, useState } from "react";
import { 
  User as UserIcon, 
  GraduationCap, 
  Briefcase, 
  Award, 
  Plus, 
  Trash2, 
  CheckCircle, 
  AlertCircle,
  Save
} from "lucide-react";
import { api, Profile, ProfileCompletion, SkillNode } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function ProfilePage() {
  const { user } = useAuth();

  const [activeTab, setActiveTab] = useState<"overview" | "qual" | "exp" | "skills" | "certs">("overview");
  const [profile, setProfile] = useState<Profile | null>(null);
  const [completion, setCompletion] = useState<ProfileCompletion | null>(null);
  const [qualifications, setQualifications] = useState<any[]>([]);
  const [experience, setExperience] = useState<any[]>([]);
  const [skills, setSkills] = useState<any[]>([]);
  const [certs, setCerts] = useState<any[]>([]);
  const [skillsTree, setSkillsTree] = useState<SkillNode[]>([]);

  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  // Form states for adding items
  const [newQual, setNewQual] = useState({ degree: "", specialization: "", institution: "", year_completed: "" });
  const [newExp, setNewExp] = useState({ organization: "", designation: "", start_date: "", end_date: "", description: "" });
  const [newSkill, setNewSkill] = useState({ skill_id: "", kind: "skill", proficiency: "3", years: "1" });
  const [newCert, setNewCert] = useState({ title: "", issuer: "", issue_date: "", credential_id: "" });

  const loadData = async () => {
    try {
      setLoading(true);
      const [p, comp, q, e, s, c, tree] = await Promise.all([
        api.profile.get(),
        api.profile.getCompletion(),
        api.profile.getQualifications(),
        api.profile.getExperience(),
        api.profile.getSkills(),
        api.profile.getCertificates(),
        api.profile.getSkillsTree(),
      ]);
      setProfile(p);
      setCompletion(comp);
      setQualifications(q);
      setExperience(e);
      setSkills(s);
      setCerts(c);
      setSkillsTree(tree);
    } catch (err: any) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    loadData();
  }, []);

  const handleUpdateProfile = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!profile) return;
    setSaving(true);
    setMessage(null);
    try {
      await api.profile.update({
        headline: profile.headline,
        bio: profile.bio,
        location: profile.location,
        total_experience_months: Number(profile.total_experience_months),
        expertise_summary: profile.expertise_summary,
      });
      setMessage("Profile overview saved successfully!");
      const comp = await api.profile.getCompletion();
      setCompletion(comp);
    } catch (err: any) {
      setMessage(`Error: ${err.message}`);
    } finally {
      setSaving(false);
    }
  };

  const handleAddQual = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      await api.profile.addQualification({
        degree: newQual.degree,
        specialization: newQual.specialization || null,
        institution: newQual.institution,
        year_completed: newQual.year_completed ? Number(newQual.year_completed) : null,
      });
      setNewQual({ degree: "", specialization: "", institution: "", year_completed: "" });
      const [q, comp] = await Promise.all([api.profile.getQualifications(), api.profile.getCompletion()]);
      setQualifications(q);
      setCompletion(comp);
    } catch (err: any) {
      alert(err.message);
    }
  };

  const handleDeleteQual = async (id: string) => {
    try {
      await api.profile.deleteQualification(id);
      const [q, comp] = await Promise.all([api.profile.getQualifications(), api.profile.getCompletion()]);
      setQualifications(q);
      setCompletion(comp);
    } catch (err: any) {
      alert(err.message);
    }
  };

  const handleAddExp = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      await api.profile.addExperience({
        organization: newExp.organization,
        designation: newExp.designation,
        start_date: newExp.start_date,
        end_date: newExp.end_date || null,
        description: newExp.description || null,
      });
      setNewExp({ organization: "", designation: "", start_date: "", end_date: "", description: "" });
      const [expList, comp] = await Promise.all([api.profile.getExperience(), api.profile.getCompletion()]);
      setExperience(expList);
      setCompletion(comp);
    } catch (err: any) {
      alert(err.message);
    }
  };

  const handleDeleteExp = async (id: string) => {
    try {
      await api.profile.deleteExperience(id);
      const [expList, comp] = await Promise.all([api.profile.getExperience(), api.profile.getCompletion()]);
      setExperience(expList);
      setCompletion(comp);
    } catch (err: any) {
      alert(err.message);
    }
  };

  const handleAddSkill = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!newSkill.skill_id) return;
    try {
      await api.profile.addSkill({
        skill_id: Number(newSkill.skill_id),
        kind: newSkill.kind,
        proficiency: newSkill.kind === "skill" ? Number(newSkill.proficiency) : null,
        years: newSkill.kind === "skill" ? Number(newSkill.years) : null,
      });
      setNewSkill({ skill_id: "", kind: "skill", proficiency: "3", years: "1" });
      const [sList, comp] = await Promise.all([api.profile.getSkills(), api.profile.getCompletion()]);
      setSkills(sList);
      setCompletion(comp);
    } catch (err: any) {
      alert(err.message);
    }
  };

  const handleDeleteSkill = async (skillId: number, kind: string) => {
    try {
      await api.profile.deleteSkill(skillId, kind);
      const [sList, comp] = await Promise.all([api.profile.getSkills(), api.profile.getCompletion()]);
      setSkills(sList);
      setCompletion(comp);
    } catch (err: any) {
      alert(err.message);
    }
  };

  const handleAddCert = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      await api.profile.addCertificate({
        title: newCert.title,
        issuer: newCert.issuer,
        issue_date: newCert.issue_date || null,
        credential_id: newCert.credential_id || null,
      });
      setNewCert({ title: "", issuer: "", issue_date: "", credential_id: "" });
      const [cList, comp] = await Promise.all([api.profile.getCertificates(), api.profile.getCompletion()]);
      setCerts(cList);
      setCompletion(comp);
    } catch (err: any) {
      alert(err.message);
    }
  };

  const handleDeleteCert = async (id: string) => {
    try {
      await api.profile.deleteCertificate(id);
      const [cList, comp] = await Promise.all([api.profile.getCertificates(), api.profile.getCompletion()]);
      setCerts(cList);
      setCompletion(comp);
    } catch (err: any) {
      alert(err.message);
    }
  };

  if (loading) {
    return <div className="text-center py-12 text-slate-500">Loading user profile...</div>;
  }

  // Flatten leaf skills for dropdown
  const leafSkills: { id: number; name: string; category?: string }[] = [];
  skillsTree.forEach((root) => {
    if (root.children && root.children.length > 0) {
      root.children.forEach((child) => {
        leafSkills.push({ id: child.id, name: child.name, category: root.name });
      });
    } else {
      leafSkills.push({ id: root.id, name: root.name });
    }
  });

  return (
    <div className="space-y-6">
      {/* Header with user info */}
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 bg-white p-6 rounded-xl border border-slate-200 shadow-sm">
        <div className="flex items-center gap-4">
          <div className="h-16 w-16 rounded-full bg-navy-900 text-white flex items-center justify-center font-bold text-2xl">
            {user?.full_name?.charAt(0) || "U"}
          </div>
          <div>
            <h1 className="text-xl font-bold text-navy-900">{user?.full_name}</h1>
            <p className="text-sm text-slate-500 capitalize">
              {user?.designation || "Staff"} · {user?.department || "India Meteorological Department"}
            </p>
            <div className="flex items-center gap-2 mt-1">
              <span className="inline-block px-2 py-0.5 text-xs font-semibold rounded bg-navy-100 text-navy-900 uppercase">
                {user?.role}
              </span>
              <span className="text-xs text-slate-400">ID: {user?.employee_code || "N/A"}</span>
            </div>
          </div>
        </div>

        {/* Profile Completion Bar */}
        {completion && (
          <div className="sm:w-72 bg-slate-50 p-4 rounded-lg border border-slate-200 space-y-2">
            <div className="flex justify-between text-xs font-semibold">
              <span className="text-slate-700">Profile Completion</span>
              <span className="text-primary font-bold">{completion.completion_pct}%</span>
            </div>
            <div className="w-full h-2.5 bg-slate-200 rounded-full overflow-hidden">
              <div
                className="h-full bg-primary transition-all duration-500 rounded-full"
                style={{ width: `${completion.completion_pct}%` }}
              ></div>
            </div>
            {completion.missing_sections.length > 0 ? (
              <p className="text-[11px] text-slate-500">
                Missing: {completion.missing_sections.join(", ")}
              </p>
            ) : (
              <p className="text-[11px] text-emerald-600 font-medium flex items-center gap-1">
                <CheckCircle className="h-3 w-3" /> Profile fully completed!
              </p>
            )}
          </div>
        )}
      </div>

      {/* Tabs */}
      <div className="flex border-b border-slate-200 bg-white px-4 rounded-t-xl gap-2 sm:gap-4 overflow-x-auto">
        <button
          onClick={() => setActiveTab("overview")}
          className={`py-3 px-3 text-sm font-semibold border-b-2 flex items-center gap-2 whitespace-nowrap transition-colors ${
            activeTab === "overview"
              ? "border-primary text-primary"
              : "border-transparent text-slate-600 hover:text-navy-900"
          }`}
        >
          <UserIcon className="h-4 w-4" />
          Overview & Bio
        </button>

        <button
          onClick={() => setActiveTab("qual")}
          className={`py-3 px-3 text-sm font-semibold border-b-2 flex items-center gap-2 whitespace-nowrap transition-colors ${
            activeTab === "qual"
              ? "border-primary text-primary"
              : "border-transparent text-slate-600 hover:text-navy-900"
          }`}
        >
          <GraduationCap className="h-4 w-4" />
          Qualifications ({qualifications.length})
        </button>

        <button
          onClick={() => setActiveTab("exp")}
          className={`py-3 px-3 text-sm font-semibold border-b-2 flex items-center gap-2 whitespace-nowrap transition-colors ${
            activeTab === "exp"
              ? "border-primary text-primary"
              : "border-transparent text-slate-600 hover:text-navy-900"
          }`}
        >
          <Briefcase className="h-4 w-4" />
          Experience ({experience.length})
        </button>

        <button
          onClick={() => setActiveTab("skills")}
          className={`py-3 px-3 text-sm font-semibold border-b-2 flex items-center gap-2 whitespace-nowrap transition-colors ${
            activeTab === "skills"
              ? "border-primary text-primary"
              : "border-transparent text-slate-600 hover:text-navy-900"
          }`}
        >
          <Award className="h-4 w-4" />
          Skills & Taxonomy ({skills.length})
        </button>

        <button
          onClick={() => setActiveTab("certs")}
          className={`py-3 px-3 text-sm font-semibold border-b-2 flex items-center gap-2 whitespace-nowrap transition-colors ${
            activeTab === "certs"
              ? "border-primary text-primary"
              : "border-transparent text-slate-600 hover:text-navy-900"
          }`}
        >
          <Award className="h-4 w-4" />
          Certificates ({certs.length})
        </button>
      </div>

      {/* Tab Contents */}
      <div className="bg-white p-6 rounded-b-xl border border-t-0 border-slate-200 shadow-sm">
        {/* Tab 1: Overview */}
        {activeTab === "overview" && profile && (
          <form onSubmit={handleUpdateProfile} className="space-y-4 max-w-2xl">
            {message && (
              <div className="p-3 rounded-lg bg-emerald-50 border border-emerald-200 text-emerald-800 text-sm">
                {message}
              </div>
            )}

            <div className="space-y-1">
              <label className="text-xs font-semibold text-slate-700">Headline</label>
              <input
                type="text"
                value={profile.headline || ""}
                onChange={(e) => setProfile({ ...profile, headline: e.target.value })}
                placeholder="e.g. Radar Meteorologist & Numerical Modelling Specialist"
                className="w-full rounded-lg border border-slate-300 p-2 text-sm focus:ring-2 focus:ring-primary focus:outline-none"
              />
            </div>

            <div className="space-y-1">
              <label className="text-xs font-semibold text-slate-700">Professional Bio</label>
              <textarea
                rows={3}
                value={profile.bio || ""}
                onChange={(e) => setProfile({ ...profile, bio: e.target.value })}
                placeholder="Brief summary of duties and operational research..."
                className="w-full rounded-lg border border-slate-300 p-2 text-sm focus:ring-2 focus:ring-primary focus:outline-none"
              />
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Posting Location</label>
                <input
                  type="text"
                  value={profile.location || ""}
                  onChange={(e) => setProfile({ ...profile, location: e.target.value })}
                  placeholder="e.g. New Delhi, Mumbai, Pune"
                  className="w-full rounded-lg border border-slate-300 p-2 text-sm focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>

              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Total Experience (Months)</label>
                <input
                  type="number"
                  min="0"
                  value={profile.total_experience_months || 0}
                  onChange={(e) => setProfile({ ...profile, total_experience_months: Number(e.target.value) })}
                  className="w-full rounded-lg border border-slate-300 p-2 text-sm focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>
            </div>

            {user?.role === "trainer" && (
              <div className="space-y-1 pt-2">
                <label className="text-xs font-semibold text-slate-700">
                  Trainer Expertise Summary (Used by Competency Engine)
                </label>
                <textarea
                  rows={3}
                  value={profile.expertise_summary || ""}
                  onChange={(e) => setProfile({ ...profile, expertise_summary: e.target.value })}
                  placeholder="Describe your subject specializations, instruments handled, or training modules conducted..."
                  className="w-full rounded-lg border border-slate-300 p-2 text-sm focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>
            )}

            <button
              type="submit"
              disabled={saving}
              className="inline-flex items-center gap-2 rounded-lg bg-primary py-2 px-5 text-sm font-semibold text-white shadow-sm hover:bg-primary-hover transition-colors disabled:opacity-50"
            >
              <Save className="h-4 w-4" />
              {saving ? "Saving..." : "Save Overview"}
            </button>
          </form>
        )}

        {/* Tab 2: Qualifications */}
        {activeTab === "qual" && (
          <div className="space-y-6">
            <div className="space-y-3">
              <h3 className="text-sm font-bold text-navy-900 uppercase tracking-wide">
                Recorded Qualifications
              </h3>
              {qualifications.length === 0 ? (
                <p className="text-xs text-slate-500 italic">No qualifications added yet.</p>
              ) : (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                  {qualifications.map((q) => (
                    <div
                      key={q.id}
                      className="p-4 rounded-lg border border-slate-200 bg-slate-50 flex items-start justify-between"
                    >
                      <div className="space-y-1">
                        <div className="font-semibold text-sm text-slate-900">
                          {q.degree} {q.specialization ? `in ${q.specialization}` : ""}
                        </div>
                        <div className="text-xs text-slate-600">{q.institution}</div>
                        {q.year_completed && (
                          <div className="text-[11px] text-slate-400">Completed: {q.year_completed}</div>
                        )}
                      </div>
                      <button
                        onClick={() => handleDeleteQual(q.id)}
                        className="text-slate-400 hover:text-red-600 transition-colors p-1"
                        title="Delete"
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Add Qualification Form */}
            <form onSubmit={handleAddQual} className="p-4 rounded-lg border border-slate-200 bg-white space-y-4 max-w-xl">
              <h4 className="text-xs font-bold uppercase tracking-wider text-slate-700">Add Qualification</h4>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <input
                  type="text"
                  required
                  placeholder="Degree (e.g. M.Sc, M.Tech, PhD)"
                  value={newQual.degree}
                  onChange={(e) => setNewQual({ ...newQual, degree: e.target.value })}
                  className="rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
                <input
                  type="text"
                  placeholder="Specialization (e.g. Meteorology)"
                  value={newQual.specialization}
                  onChange={(e) => setNewQual({ ...newQual, specialization: e.target.value })}
                  className="rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
                <input
                  type="text"
                  required
                  placeholder="Institution / University"
                  value={newQual.institution}
                  onChange={(e) => setNewQual({ ...newQual, institution: e.target.value })}
                  className="rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none sm:col-span-2"
                />
                <input
                  type="number"
                  placeholder="Year Completed (e.g. 2020)"
                  value={newQual.year_completed}
                  onChange={(e) => setNewQual({ ...newQual, year_completed: e.target.value })}
                  className="rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>
              <button
                type="submit"
                className="inline-flex items-center gap-1.5 rounded-lg bg-navy-900 py-1.5 px-3 text-xs font-semibold text-white hover:bg-navy-800 transition-colors"
              >
                <Plus className="h-3.5 w-3.5" /> Add Qualification
              </button>
            </form>
          </div>
        )}

        {/* Tab 3: Experience */}
        {activeTab === "exp" && (
          <div className="space-y-6">
            <div className="space-y-3">
              <h3 className="text-sm font-bold text-navy-900 uppercase tracking-wide">
                Work Experience History
              </h3>
              {experience.length === 0 ? (
                <p className="text-xs text-slate-500 italic">No experience records added yet.</p>
              ) : (
                <div className="space-y-3">
                  {experience.map((e) => (
                    <div
                      key={e.id}
                      className="p-4 rounded-lg border border-slate-200 bg-slate-50 flex items-start justify-between"
                    >
                      <div className="space-y-1">
                        <div className="font-semibold text-sm text-slate-900">{e.designation}</div>
                        <div className="text-xs font-medium text-slate-700">{e.organization}</div>
                        <div className="text-[11px] text-slate-500">
                          {e.start_date} to {e.end_date || "Present"}
                        </div>
                        {e.description && <p className="text-xs text-slate-600 pt-1">{e.description}</p>}
                      </div>
                      <button
                        onClick={() => handleDeleteExp(e.id)}
                        className="text-slate-400 hover:text-red-600 transition-colors p-1"
                        title="Delete"
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Add Experience Form */}
            <form onSubmit={handleAddExp} className="p-4 rounded-lg border border-slate-200 bg-white space-y-4 max-w-xl">
              <h4 className="text-xs font-bold uppercase tracking-wider text-slate-700">Add Work Experience</h4>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <input
                  type="text"
                  required
                  placeholder="Organization (e.g. IMD, NCMRWF)"
                  value={newExp.organization}
                  onChange={(e) => setNewExp({ ...newExp, organization: e.target.value })}
                  className="rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
                <input
                  type="text"
                  required
                  placeholder="Designation (e.g. Meteorologist Gr-I)"
                  value={newExp.designation}
                  onChange={(e) => setNewExp({ ...newExp, designation: e.target.value })}
                  className="rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
                <div>
                  <label className="text-[10px] text-slate-500 block mb-0.5">Start Date</label>
                  <input
                    type="date"
                    required
                    value={newExp.start_date}
                    onChange={(e) => setNewExp({ ...newExp, start_date: e.target.value })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  />
                </div>
                <div>
                  <label className="text-[10px] text-slate-500 block mb-0.5">End Date (Blank if current)</label>
                  <input
                    type="date"
                    value={newExp.end_date}
                    onChange={(e) => setNewExp({ ...newExp, end_date: e.target.value })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  />
                </div>
                <textarea
                  rows={2}
                  placeholder="Key responsibilities..."
                  value={newExp.description}
                  onChange={(e) => setNewExp({ ...newExp, description: e.target.value })}
                  className="rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none sm:col-span-2"
                />
              </div>
              <button
                type="submit"
                className="inline-flex items-center gap-1.5 rounded-lg bg-navy-900 py-1.5 px-3 text-xs font-semibold text-white hover:bg-navy-800 transition-colors"
              >
                <Plus className="h-3.5 w-3.5" /> Add Experience Record
              </button>
            </form>
          </div>
        )}

        {/* Tab 4: Skills & Interests */}
        {activeTab === "skills" && (
          <div className="space-y-6">
            <div className="space-y-3">
              <h3 className="text-sm font-bold text-navy-900 uppercase tracking-wide">
                My Meteorological Skills & Interests
              </h3>
              {skills.length === 0 ? (
                <p className="text-xs text-slate-500 italic">No skills recorded yet.</p>
              ) : (
                <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-3">
                  {skills.map((s) => (
                    <div
                      key={`${s.skill_id}-${s.kind}`}
                      className="p-3 rounded-lg border border-slate-200 bg-slate-50 flex items-start justify-between"
                    >
                      <div className="space-y-1">
                        <div className="font-semibold text-sm text-slate-900">{s.skill_name}</div>
                        <div className="flex items-center gap-2">
                          <span
                            className={`px-1.5 py-0.5 text-[10px] font-semibold rounded uppercase ${
                              s.kind === "skill" ? "bg-blue-100 text-primary" : "bg-purple-100 text-purple-700"
                            }`}
                          >
                            {s.kind}
                          </span>
                          {s.kind === "skill" && (
                            <span className="text-xs text-slate-600">
                              Level {s.proficiency}/5 · {s.years} yrs
                            </span>
                          )}
                        </div>
                      </div>
                      <button
                        onClick={() => handleDeleteSkill(s.skill_id, s.kind)}
                        className="text-slate-400 hover:text-red-600 transition-colors p-1"
                        title="Remove"
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Add Skill Form */}
            <form onSubmit={handleAddSkill} className="p-4 rounded-lg border border-slate-200 bg-white space-y-4 max-w-xl">
              <h4 className="text-xs font-bold uppercase tracking-wider text-slate-700">Add Skill or Interest</h4>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <div className="sm:col-span-2">
                  <label className="text-[10px] text-slate-500 block mb-0.5">Select Subject from Taxonomy</label>
                  <select
                    required
                    value={newSkill.skill_id}
                    onChange={(e) => setNewSkill({ ...newSkill, skill_id: e.target.value })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  >
                    <option value="">-- Choose Subject --</option>
                    {leafSkills.map((sk) => (
                      <option key={sk.id} value={sk.id}>
                        {sk.category ? `${sk.category} > ` : ""}{sk.name}
                      </option>
                    ))}
                  </select>
                </div>

                <div>
                  <label className="text-[10px] text-slate-500 block mb-0.5">Type</label>
                  <select
                    value={newSkill.kind}
                    onChange={(e) => setNewSkill({ ...newSkill, kind: e.target.value })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  >
                    <option value="skill">Proficient Skill</option>
                    <option value="interest">Learning Interest</option>
                  </select>
                </div>

                {newSkill.kind === "skill" && (
                  <>
                    <div>
                      <label className="text-[10px] text-slate-500 block mb-0.5">Proficiency (1 to 5)</label>
                      <select
                        value={newSkill.proficiency}
                        onChange={(e) => setNewSkill({ ...newSkill, proficiency: e.target.value })}
                        className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                      >
                        <option value="1">1 - Novice</option>
                        <option value="2">2 - Basic</option>
                        <option value="3">3 - Competent</option>
                        <option value="4">4 - Proficient</option>
                        <option value="5">5 - Expert</option>
                      </select>
                    </div>

                    <div>
                      <label className="text-[10px] text-slate-500 block mb-0.5">Years of Experience</label>
                      <input
                        type="number"
                        step="0.5"
                        min="0"
                        value={newSkill.years}
                        onChange={(e) => setNewSkill({ ...newSkill, years: e.target.value })}
                        className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                      />
                    </div>
                  </>
                )}
              </div>
              <button
                type="submit"
                className="inline-flex items-center gap-1.5 rounded-lg bg-navy-900 py-1.5 px-3 text-xs font-semibold text-white hover:bg-navy-800 transition-colors"
              >
                <Plus className="h-3.5 w-3.5" /> Save to Profile
              </button>
            </form>
          </div>
        )}

        {/* Tab 5: Certificates */}
        {activeTab === "certs" && (
          <div className="space-y-6">
            <div className="space-y-3">
              <h3 className="text-sm font-bold text-navy-900 uppercase tracking-wide">
                External Certificates
              </h3>
              {certs.length === 0 ? (
                <p className="text-xs text-slate-500 italic">No external certificates uploaded yet.</p>
              ) : (
                <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                  {certs.map((c) => (
                    <div
                      key={c.id}
                      className="p-4 rounded-lg border border-slate-200 bg-slate-50 flex items-start justify-between"
                    >
                      <div className="space-y-1">
                        <div className="font-semibold text-sm text-slate-900">{c.title}</div>
                        <div className="text-xs text-slate-600">{c.issuer}</div>
                        {c.credential_id && (
                          <div className="text-[11px] text-slate-400">ID: {c.credential_id}</div>
                        )}
                        {c.issue_date && (
                          <div className="text-[11px] text-slate-400">Issued: {c.issue_date}</div>
                        )}
                      </div>
                      <button
                        onClick={() => handleDeleteCert(c.id)}
                        className="text-slate-400 hover:text-red-600 transition-colors p-1"
                        title="Delete"
                      >
                        <Trash2 className="h-4 w-4" />
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Add Certificate Form */}
            <form onSubmit={handleAddCert} className="p-4 rounded-lg border border-slate-200 bg-white space-y-4 max-w-xl">
              <h4 className="text-xs font-bold uppercase tracking-wider text-slate-700">Add Certificate</h4>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <input
                  type="text"
                  required
                  placeholder="Certificate Title"
                  value={newCert.title}
                  onChange={(e) => setNewCert({ ...newCert, title: e.target.value })}
                  className="rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none sm:col-span-2"
                />
                <input
                  type="text"
                  required
                  placeholder="Issuing Authority (e.g. WMO, IIT)"
                  value={newCert.issuer}
                  onChange={(e) => setNewCert({ ...newCert, issuer: e.target.value })}
                  className="rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
                <input
                  type="text"
                  placeholder="Credential ID"
                  value={newCert.credential_id}
                  onChange={(e) => setNewCert({ ...newCert, credential_id: e.target.value })}
                  className="rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
                <div>
                  <label className="text-[10px] text-slate-500 block mb-0.5">Issue Date</label>
                  <input
                    type="date"
                    value={newCert.issue_date}
                    onChange={(e) => setNewCert({ ...newCert, issue_date: e.target.value })}
                    className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                  />
                </div>
              </div>
              <button
                type="submit"
                className="inline-flex items-center gap-1.5 rounded-lg bg-navy-900 py-1.5 px-3 text-xs font-semibold text-white hover:bg-navy-800 transition-colors"
              >
                <Plus className="h-3.5 w-3.5" /> Add Certificate
              </button>
            </form>
          </div>
        )}
      </div>
    </div>
  );
}
