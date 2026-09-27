"use client";

import React from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { 
  Compass, 
  BookOpen, 
  UserCheck, 
  Layers, 
  User as UserIcon, 
  Award, 
  BarChart3,
  BrainCircuit,
  HelpCircle
} from "lucide-react";
import { User } from "@/lib/api";

interface SidebarProps {
  user: User | null;
}

export const Sidebar: React.FC<SidebarProps> = ({ user }) => {
  const pathname = usePathname();

  const getNavLinks = () => {
    if (!user) {
      return [
        { href: "/courses", label: "Course Catalogue", icon: Compass },
      ];
    }

    const links = [
      { href: "/courses", label: "Course Catalogue", icon: Compass },
      { href: "/profile", label: "My Profile", icon: UserIcon },
    ];

    if (user.role === "trainer") {
      links.splice(1, 0, {
        href: "/trainer/courses",
        label: "My Courses & Content",
        icon: BookOpen,
      });
      links.splice(2, 0, { href: "/trainer/questions", label: "Question Generator", icon: HelpCircle });
    }

    if (user.role === "admin") {
      links.splice(1, 0, {
        href: "/admin/users",
        label: "User Approvals",
        icon: UserCheck,
      });
      links.splice(2, 0, { href: "/admin/competency", label: "Competency Mapping", icon: BrainCircuit });
    }

    return links;
  };

  const navLinks = getNavLinks();

  return (
    <aside className="hidden md:flex w-64 flex-col bg-navy-900 text-slate-300 min-h-[calc(100vh-4rem)] p-4 border-r border-navy-800">
      <div className="mb-6 px-2">
        <p className="text-xs font-semibold uppercase tracking-wider text-slate-400">
          Navigation
        </p>
      </div>

      <nav className="flex-1 space-y-1.5">
        {navLinks.map((item) => {
          const Icon = item.icon;
          const isActive = pathname === item.href || (item.href !== "/" && pathname.startsWith(item.href));
          return (
            <Link
              key={item.href}
              href={item.href}
              className={`flex items-center gap-3 rounded-lg px-3 py-2.5 text-sm font-medium transition-colors ${
                isActive
                  ? "bg-primary text-white shadow-sm"
                  : "text-slate-300 hover:bg-navy-800 hover:text-white"
              }`}
            >
              <Icon className="h-5 w-5" />
              <span>{item.label}</span>
            </Link>
          );
        })}
      </nav>

      {user && (
        <div className="mt-auto pt-4 border-t border-navy-800 px-2 text-xs text-slate-400">
          <div className="font-semibold text-slate-200 truncate">{user.full_name}</div>
          <div className="capitalize text-slate-400">{user.role} · {user.department || "IMD"}</div>
        </div>
      )}
    </aside>
  );
};
