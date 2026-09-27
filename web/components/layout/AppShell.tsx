"use client";

import React, { createContext, useContext, useEffect, useState } from "react";
import { User, api } from "@/lib/api";
import { Navbar } from "@/components/layout/Navbar";
import { Sidebar } from "@/components/layout/Sidebar";
import { MobileNav } from "@/components/layout/MobileNav";

interface AuthContextType {
  user: User | null;
  loading: boolean;
  refreshUser: () => Promise<void>;
  setUser: (u: User | null) => void;
}

const AuthContext = createContext<AuthContextType>({
  user: null,
  loading: true,
  refreshUser: async () => {},
  setUser: () => {},
});

export const useAuth = () => useContext(AuthContext);

export const AppShell: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);

  const refreshUser = async () => {
    try {
      const me = await api.auth.me();
      setUser(me);
    } catch {
      setUser(null);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    refreshUser();
  }, []);

  return (
    <AuthContext.Provider value={{ user, loading, refreshUser, setUser }}>
      <div className="min-h-screen flex flex-col bg-slate-50 text-slate-900">
        <Navbar user={user} onLogout={() => setUser(null)} />
        <div className="flex flex-1">
          <Sidebar user={user} />
          <main className="flex-1 p-4 sm:p-6 md:p-8 pb-20 md:pb-8 max-w-7xl w-full mx-auto">
            {children}
          </main>
        </div>
        <MobileNav user={user} />
      </div>
    </AuthContext.Provider>
  );
};
