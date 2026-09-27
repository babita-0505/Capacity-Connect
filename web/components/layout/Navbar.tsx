"use client";

import React from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { LogOut, User as UserIcon, BookOpen, Compass } from "lucide-react";
import { User, api } from "@/lib/api";

interface NavbarProps {
  user?: User | null;
  onLogout?: () => void;
}

export const Navbar: React.FC<NavbarProps> = ({ user, onLogout }) => {
  const router = useRouter();

  const handleLogout = async () => {
    try {
      await api.auth.logout();
      if (onLogout) onLogout();
      router.push("/login");
    } catch {
      router.push("/login");
    }
  };

  return (
    <header className="sticky top-0 z-40 w-full border-b border-slate-200 bg-white shadow-sm">
      <div className="flex h-16 items-center justify-between px-4 sm:px-6">
        <div className="flex items-center gap-3">
          <Link href="/" className="flex items-center gap-2">
            <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-navy-900 text-white font-bold text-lg tracking-wider">
              CC
            </div>
            <div>
              <span className="font-bold text-navy-900 text-lg tracking-tight block leading-tight">
                CAPACITY CONNECT
              </span>
              <span className="text-[11px] font-medium text-slate-500 uppercase tracking-wider block">
                MoES · India Meteorological Department
              </span>
            </div>
          </Link>
        </div>

        <div className="flex items-center gap-4">
          {user ? (
            <div className="flex items-center gap-3">
              <Link
                href="/profile"
                className="flex items-center gap-2 rounded-full border border-slate-200 bg-slate-50 py-1.5 px-3 text-sm font-medium text-slate-700 hover:bg-slate-100 transition-colors"
              >
                <UserIcon className="h-4 w-4 text-primary" />
                <span className="hidden sm:inline">{user.full_name}</span>
                <span className="rounded bg-navy-900 px-1.5 py-0.5 text-[10px] font-semibold text-white uppercase">
                  {user.role}
                </span>
              </Link>
              <button
                onClick={handleLogout}
                title="Log out"
                className="flex items-center gap-1 rounded-md p-2 text-slate-500 hover:bg-slate-100 hover:text-red-600 transition-colors"
              >
                <LogOut className="h-5 w-5" />
              </button>
            </div>
          ) : (
            <div className="flex items-center gap-2">
              <Link
                href="/courses"
                className="hidden sm:flex items-center gap-1 text-sm font-medium text-slate-600 hover:text-navy-900 px-3 py-2 rounded-md hover:bg-slate-50"
              >
                <Compass className="h-4 w-4" />
                Explore Courses
              </Link>
              <Link
                href="/login"
                className="text-sm font-semibold text-slate-700 hover:text-primary px-3 py-2 rounded-md transition-colors"
              >
                Log In
              </Link>
              <Link
                href="/signup"
                className="text-sm font-semibold text-white bg-primary hover:bg-primary-hover px-4 py-2 rounded-md shadow-sm transition-colors"
              >
                Sign Up
              </Link>
            </div>
          )}
        </div>
      </div>
    </header>
  );
};
