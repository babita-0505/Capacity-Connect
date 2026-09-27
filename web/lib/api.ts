export interface User {
  id: string;
  email: string;
  full_name: string;
  role: "trainee" | "trainer" | "admin";
  status: "pending" | "approved" | "rejected" | "suspended";
  department?: string;
  designation?: string;
  employee_code?: string;
  preferred_lang?: string;
  avatar_file_id?: string;
  token_version: number;
  created_at: string;
}

export interface Profile {
  user_id: string;
  headline?: string;
  bio?: string;
  date_of_joining?: string;
  total_experience_months: number;
  location?: string;
  expertise_summary?: string;
  is_available: boolean;
  updated_at: string;
}

export interface ProfileCompletion {
  completion_pct: number;
  missing_sections: string[];
  has_profile: boolean;
  has_qualifications: boolean;
  has_experience: boolean;
  has_skills: boolean;
  has_certificates: boolean;
}

export interface SkillNode {
  id: number;
  name: string;
  slug: string;
  parent_id?: number;
  description?: string;
  keywords: string[];
  children?: SkillNode[];
}

export interface Course {
  id: string;
  code: string;
  title: string;
  summary?: string;
  skill_id?: number;
  skill_name?: string;
  tags: string[];
  level: "beginner" | "intermediate" | "advanced";
  duration_hours?: number;
  trainer_id?: string;
  trainer_name?: string;
  status: "draft" | "published" | "archived";
  pass_criteria_pct: number;
  issues_certificate: boolean;
  published_at?: string;
  created_at: string;
  resources?: CourseResource[];
}

export interface CourseResource {
  id: string;
  trainer_id: string;
  title: string;
  description?: string;
  type: "video" | "pdf" | "presentation" | "document" | "link";
  file_id?: string;
  file_path?: string;
  external_url?: string;
  duration_seconds?: number;
  page_count?: number;
  module_title: string;
  position: number;
  is_mandatory: boolean;
}

export interface CompetencyRecommendation {
  trainer_id: string; full_name: string; department?: string; total_score: number;
  rank_in_skill: number; skill_match: number; pass_rate: number; rating_score: number; experience_score: number;
  declared_proficiency?: number; courses_taught: number; resources_uploaded: number; keyword_hits: number; attempts_count: number; feedback_count: number;
}

export interface SkillGap { skill_id: number; skill: string; category?: string; best_trainer_score: number; strong_trainers: number; demand: number; gap_status: "critical gap" | "weak coverage" | "covered"; }

const API_BASE = typeof window !== "undefined" ? "/api" : (process.env.INTERNAL_API_URL || "http://127.0.0.1:8000/api");

export async function fetchApi<T>(endpoint: string, options: RequestInit = {}): Promise<T> {
  const url = `${API_BASE}${endpoint.startsWith("/") ? endpoint : `/${endpoint}`}`;
  const headers = new Headers(options.headers || {});

  if (!(options.body instanceof FormData) && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }

  const res = await fetch(url, {
    ...options,
    headers,
    credentials: "include", // send and receive httpOnly cookies
  });

  if (!res.ok) {
    let errorDetail = "An unexpected error occurred";
    try {
      const errorJson = await res.json();
      errorDetail = errorJson.detail || errorJson.message || JSON.stringify(errorJson);
    } catch {
      errorDetail = await res.text();
    }
    throw new Error(errorDetail || `HTTP error ${res.status}`);
  }

  return res.json();
}

export const api = {
  auth: {
    signup: (data: any) => fetchApi<{ message: string; user_id: string }>("/auth/signup", {
      method: "POST",
      body: JSON.stringify(data),
    }),
    login: (data: any) => fetchApi<{ access_token: string; user: User }>("/auth/login", {
      method: "POST",
      body: JSON.stringify(data),
    }),
    logout: () => fetchApi<{ message: string }>("/auth/logout", { method: "POST" }),
    me: () => fetchApi<User>("/me"),
  },

  admin: {
    getUsers: (params: { status?: string; role?: string; q?: string; page?: number; page_size?: number }) => {
      const search = new URLSearchParams();
      if (params.status) search.set("status", params.status);
      if (params.role) search.set("role", params.role);
      if (params.q) search.set("q", params.q);
      if (params.page) search.set("page", params.page.toString());
      if (params.page_size) search.set("page_size", params.page_size.toString());
      return fetchApi<{ items: User[]; total: number; page: number; page_size: number }>(`/admin/users?${search.toString()}`);
    },
    approveUser: (userId: string) => fetchApi(`/admin/users/${userId}/approve`, { method: "PATCH" }),
    rejectUser: (userId: string, reason: string) => fetchApi(`/admin/users/${userId}/reject`, {
      method: "PATCH",
      body: JSON.stringify({ reason }),
    }),
    suspendUser: (userId: string) => fetchApi(`/admin/users/${userId}/suspend`, { method: "PATCH" }),
    activateUser: (userId: string) => fetchApi(`/admin/users/${userId}/activate`, { method: "PATCH" }),
    changeRole: (userId: string, role: string) => fetchApi(`/admin/users/${userId}/role`, {
      method: "PATCH",
      body: JSON.stringify({ role }),
    }),
  },

  profile: {
    get: () => fetchApi<Profile>("/me/profile"),
    update: (data: Partial<Profile>) => fetchApi<Profile>("/me/profile", {
      method: "PUT",
      body: JSON.stringify(data),
    }),
    getCompletion: () => fetchApi<ProfileCompletion>("/me/profile-completion"),
    getQualifications: () => fetchApi<any[]>("/me/qualifications"),
    addQualification: (data: any) => fetchApi("/me/qualifications", { method: "POST", body: JSON.stringify(data) }),
    deleteQualification: (id: string) => fetchApi(`/me/qualifications/${id}`, { method: "DELETE" }),
    getExperience: () => fetchApi<any[]>("/me/experience"),
    addExperience: (data: any) => fetchApi("/me/experience", { method: "POST", body: JSON.stringify(data) }),
    deleteExperience: (id: string) => fetchApi(`/me/experience/${id}`, { method: "DELETE" }),
    getSkills: () => fetchApi<any[]>("/me/skills"),
    addSkill: (data: any) => fetchApi("/me/skills", { method: "POST", body: JSON.stringify(data) }),
    deleteSkill: (skillId: number, kind: string = "skill") => fetchApi(`/me/skills/${skillId}?kind=${kind}`, { method: "DELETE" }),
    getCertificates: () => fetchApi<any[]>("/me/certificates"),
    addCertificate: (data: any) => fetchApi("/me/certificates", { method: "POST", body: JSON.stringify(data) }),
    deleteCertificate: (id: string) => fetchApi(`/me/certificates/${id}`, { method: "DELETE" }),
    getSkillsTree: () => fetchApi<SkillNode[]>("/skills"),
  },

  courses: {
    list: (params: { q?: string; skill_id?: number; level?: string; trainer_id?: string; page?: number; page_size?: number }) => {
      const search = new URLSearchParams();
      if (params.q) search.set("q", params.q);
      if (params.skill_id) search.set("skill_id", params.skill_id.toString());
      if (params.level) search.set("level", params.level);
      if (params.trainer_id) search.set("trainer_id", params.trainer_id);
      if (params.page) search.set("page", params.page.toString());
      if (params.page_size) search.set("page_size", params.page_size.toString());
      return fetchApi<{ items: Course[]; total: number; page: number; page_size: number }>(`/courses?${search.toString()}`);
    },
    get: (id: string) => fetchApi<Course>(`/courses/${id}`),
    create: (data: any) => fetchApi<Course>("/courses", { method: "POST", body: JSON.stringify(data) }),
    update: (id: string, data: any) => fetchApi<Course>(`/courses/${id}`, { method: "PATCH", body: JSON.stringify(data) }),
    publish: (id: string) => fetchApi<Course>(`/courses/${id}/publish`, { method: "POST" }),
    addResource: (courseId: string, data: any) => fetchApi(`/courses/${courseId}/resources`, {
      method: "POST",
      body: JSON.stringify(data),
    }),
  },

  files: {
    upload: async (file: File): Promise<{ id: string; url: string; original_name: string; sha256: string }> => {
      const formData = new FormData();
      formData.append("file", file);
      return fetchApi("/files", {
        method: "POST",
        body: formData,
      });
    },
  },

  competency: {
    trainers: (skillId: number) => fetchApi<{ items: CompetencyRecommendation[]; total: number }>(`/competency/trainers?skill_id=${skillId}`),
    why: (trainerId: string, skillId: number) => fetchApi<CompetencyRecommendation & { weights: Record<string, number> }>(`/competency/trainers/${trainerId}/why?skill_id=${skillId}`),
    gaps: () => fetchApi<{ items: SkillGap[] }>("/competency/gaps"),
    heatmap: () => fetchApi<{ items: Array<{ department: string; skill: string; category?: string; avg_pct: number; trainees: number }> }>("/competency/heatmap"),
    refresh: () => fetchApi<{ job_id: string }>("/admin/competency/refresh", { method: "POST" }),
    job: (id: string) => fetchApi<{ status: string; result?: unknown; error?: string }>(`/jobs/${id}`),
    mine: () => fetchApi<{ skills: Array<{ skill: string; average_pct: number; level: string; weak: boolean }>; recommended_courses: Array<{ course_id: string; title: string; weak_skill: string; avg_pct: number }> }>("/me/competency"),
  },
  dashboard: {
    admin: () => fetchApi<{ kpis: Record<string, number>; courses: Array<{ title: string; enrollments: number; completions: number }>; assessments: Array<{ title: string; submitted: number; pass_rate_pct?: number }>; activity: Array<{ month: string; enrollments: number; attempts: number; certificates: number }> }>("/admin/dashboard"),
  },
};
