"use client";

import React from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Compass, BookOpen, UserCheck, User as UserIcon, Home, BarChart3 } from "lucide-react";
import { User } from "@/lib/api";

interface MobileNavProps {
  user: User | null;
}

export const MobileNav: React.FC<MobileNavProps> = ({ user }) => {
  const pathname = usePathname();

  const getLinks = () => {
    const base = [
      { href: "/", label: "Home", icon: Home },
      { href: "/courses", label: "Courses", icon: Compass },
    ];

    if (!user) {
      base.push({ href: "/login", label: "Login", icon: UserIcon });
      return base;
    }

    if (user.role === "trainer") {
      return [
        { href: "/trainer/courses", label: "Courses", icon: BookOpen },
        { href: "/trainer/questions", label: "Questions", icon: Home },
        { href: "/trainer/assessments", label: "Tests", icon: Compass },
        { href: "/profile", label: "Profile", icon: UserIcon },
      ];
    } else if (user.role === "admin") {
      return [
        { href: "/admin", label: "Dashboard", icon: Home },
        { href: "/admin/users", label: "Users", icon: UserCheck },
        { href: "/admin/competency", label: "Skills", icon: Compass },
        { href: "/profile", label: "Profile", icon: UserIcon },
      ];
    }

    // Trainee — include workspace and assessments
    return [
      { href: "/trainee", label: "Workspace", icon: Home },
      { href: "/courses", label: "Courses", icon: Compass },
      { href: "/assessments", label: "Tests", icon: BookOpen },
      { href: "/trainee/skills", label: "Skills", icon: BarChart3 },
      { href: "/profile", label: "Profile", icon: UserIcon },
    ];
  };

  const links = getLinks();

  return (
    <nav className="md:hidden fixed bottom-0 left-0 right-0 z-50 bg-white border-t border-slate-200 px-1 pt-1 shadow-lg"
      style={{ paddingBottom: "max(0.25rem, env(safe-area-inset-bottom))" }}
    >
      <div className="flex items-center justify-around">
        {links.map((item) => {
          const Icon = item.icon;
          const isActive = pathname === item.href || (item.href !== "/" && pathname.startsWith(item.href));
          return (
            <Link
              key={item.href}
              href={item.href}
              className={`flex flex-col items-center justify-center py-2 px-2 min-h-[44px] rounded-md transition-colors ${
                isActive ? "text-primary font-semibold" : "text-slate-500 hover:text-slate-900"
              }`}
            >
              <Icon className="h-5 w-5 mb-0.5" />
              <span className="text-[10px] leading-none">{item.label}</span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
};
