"use client";

import React from "react";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { Compass, BookOpen, UserCheck, User as UserIcon, Home } from "lucide-react";
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
      base.push({ href: "/trainer/courses", label: "Teaching", icon: BookOpen });
    } else if (user.role === "admin") {
      base.push({ href: "/admin/users", label: "Approvals", icon: UserCheck });
    }

    base.push({ href: "/profile", label: "Profile", icon: UserIcon });
    return base;
  };

  const links = getLinks();

  return (
    <nav className="md:hidden fixed bottom-0 left-0 right-0 z-50 bg-white border-t border-slate-200 px-2 py-1 shadow-lg">
      <div className="flex items-center justify-around">
        {links.map((item) => {
          const Icon = item.icon;
          const isActive = pathname === item.href || (item.href !== "/" && pathname.startsWith(item.href));
          return (
            <Link
              key={item.href}
              href={item.href}
              className={`flex flex-col items-center justify-center py-1 px-2 rounded-md transition-colors ${
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
