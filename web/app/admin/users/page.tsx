"use client";

import React, { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { 
  UserCheck, 
  Search, 
  Filter, 
  Check, 
  X, 
  Ban, 
  RefreshCw, 
  ShieldAlert,
  ChevronLeft,
  ChevronRight
} from "lucide-react";
import { api, User } from "@/lib/api";
import { useAuth } from "@/components/layout/AppShell";

export default function AdminUsersPage() {
  const router = useRouter();
  const { user: currentUser, loading: authLoading } = useAuth();

  const [users, setUsers] = useState<User[]>([]);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [statusFilter, setStatusFilter] = useState<string>("");
  const [roleFilter, setRoleFilter] = useState<string>("");
  const [searchQuery, setSearchQuery] = useState<string>("");
  const [loading, setLoading] = useState(true);

  // Dialog state
  const [selectedUser, setSelectedUser] = useState<User | null>(null);
  const [actionType, setActionType] = useState<"approve" | "reject" | "suspend" | "activate" | "role" | null>(null);
  const [rejectReason, setRejectReason] = useState("");
  const [targetRole, setTargetRole] = useState("trainee");
  const [actionLoading, setActionLoading] = useState(false);

  useEffect(() => {
    if (!authLoading && currentUser && currentUser.role !== "admin") {
      router.push("/unauthorized");
    }
  }, [currentUser, authLoading, router]);

  const loadUsers = async () => {
    try {
      setLoading(true);
      const res = await api.admin.getUsers({
        status: statusFilter || undefined,
        role: roleFilter || undefined,
        q: searchQuery || undefined,
        page,
        page_size: 15,
      });
      setUsers(res.items);
      setTotal(res.total);
    } catch (err: any) {
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (currentUser?.role === "admin") {
      loadUsers();
    }
  }, [currentUser, page, statusFilter, roleFilter]);

  const handleSearch = (e: React.FormEvent) => {
    e.preventDefault();
    setPage(1);
    loadUsers();
  };

  const handleConfirmAction = async () => {
    if (!selectedUser || !actionType) return;
    setActionLoading(true);
    try {
      if (actionType === "approve") {
        await api.admin.approveUser(selectedUser.id);
      } else if (actionType === "reject") {
        await api.admin.rejectUser(selectedUser.id, rejectReason || "Administrative decision");
      } else if (actionType === "suspend") {
        await api.admin.suspendUser(selectedUser.id);
      } else if (actionType === "activate") {
        await api.admin.activateUser(selectedUser.id);
      } else if (actionType === "role") {
        await api.admin.changeRole(selectedUser.id, targetRole);
      }
      setActionType(null);
      setSelectedUser(null);
      setRejectReason("");
      loadUsers();
    } catch (err: any) {
      alert(err.message || "Action failed");
    } finally {
      setActionLoading(false);
    }
  };

  if (authLoading) {
    return <div className="text-center py-12 text-slate-500">Checking authorization...</div>;
  }

  const totalPages = Math.ceil(total / 15) || 1;

  return (
    <div className="space-y-6">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-navy-900 tracking-tight">Staff Account Management</h1>
          <p className="text-sm text-slate-500">Review pending registrations and manage user statuses across IMD</p>
        </div>
      </div>

      {/* Filter and Search Bar */}
      <div className="bg-white p-4 rounded-xl border border-slate-200 shadow-sm flex flex-col md:flex-row gap-3">
        <form onSubmit={handleSearch} className="flex-1 relative">
          <Search className="absolute left-3 top-2.5 h-4 w-4 text-slate-400" />
          <input
            type="text"
            placeholder="Search by name, email, or employee code..."
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="w-full rounded-lg border border-slate-300 pl-9 pr-3 py-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
          />
        </form>

        <div className="flex flex-wrap gap-2">
          <select
            value={statusFilter}
            onChange={(e) => {
              setStatusFilter(e.target.value);
              setPage(1);
            }}
            className="rounded-lg border border-slate-300 py-2 px-3 text-xs focus:ring-2 focus:ring-primary focus:outline-none bg-white"
          >
            <option value="">All Statuses</option>
            <option value="pending">Pending Approval</option>
            <option value="approved">Approved</option>
            <option value="suspended">Suspended</option>
            <option value="rejected">Rejected</option>
          </select>

          <select
            value={roleFilter}
            onChange={(e) => {
              setRoleFilter(e.target.value);
              setPage(1);
            }}
            className="rounded-lg border border-slate-300 py-2 px-3 text-xs focus:ring-2 focus:ring-primary focus:outline-none bg-white"
          >
            <option value="">All Roles</option>
            <option value="trainee">Trainee</option>
            <option value="trainer">Trainer</option>
            <option value="admin">Admin</option>
          </select>

          <button
            onClick={() => {
              setSearchQuery("");
              setStatusFilter("");
              setRoleFilter("");
              setPage(1);
            }}
            className="rounded-lg border border-slate-200 bg-slate-50 hover:bg-slate-100 py-2 px-3 text-xs font-semibold text-slate-600 transition-colors"
          >
            Reset
          </button>
        </div>
      </div>

      {/* Desktop Table & Mobile Cards */}
      <div className="bg-white rounded-xl border border-slate-200 shadow-sm overflow-hidden">
        {loading ? (
          <div className="p-8 text-center text-slate-500 text-sm">Loading users...</div>
        ) : users.length === 0 ? (
          <div className="p-8 text-center text-slate-500 text-sm">No users found matching current filters.</div>
        ) : (
          <>
            {/* Desktop Table View */}
            <div className="hidden md:block overflow-x-auto">
              <table className="w-full text-left text-xs">
                <thead className="bg-slate-50 border-b border-slate-200 text-slate-500 uppercase font-semibold">
                  <tr>
                    <th className="py-3 px-4">User</th>
                    <th className="py-3 px-4">Role</th>
                    <th className="py-3 px-4">Department</th>
                    <th className="py-3 px-4">Status</th>
                    <th className="py-3 px-4 text-right">Actions</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {users.map((u) => (
                    <tr key={u.id} className="hover:bg-slate-50/75 transition-colors">
                      <td className="py-3 px-4">
                        <div className="font-semibold text-slate-900">{u.full_name}</div>
                        <div className="text-slate-500">{u.email}</div>
                        {u.employee_code && <div className="text-[10px] text-slate-400">Code: {u.employee_code}</div>}
                      </td>
                      <td className="py-3 px-4">
                        <span
                          className={`inline-block px-2 py-0.5 rounded text-[10px] font-bold uppercase ${
                            u.role === "admin"
                              ? "bg-purple-100 text-purple-700"
                              : u.role === "trainer"
                              ? "bg-indigo-100 text-indigo-700"
                              : "bg-blue-100 text-blue-700"
                          }`}
                        >
                          {u.role}
                        </span>
                      </td>
                      <td className="py-3 px-4 text-slate-600">
                        <div>{u.department || "IMD"}</div>
                        <div className="text-[11px] text-slate-400">{u.designation || "-"}</div>
                      </td>
                      <td className="py-3 px-4">
                        <span
                          className={`inline-block px-2 py-0.5 rounded text-[10px] font-bold uppercase ${
                            u.status === "approved"
                              ? "bg-emerald-100 text-emerald-800"
                              : u.status === "pending"
                              ? "bg-amber-100 text-amber-800"
                              : u.status === "rejected"
                              ? "bg-red-100 text-red-800"
                              : "bg-slate-200 text-slate-800"
                          }`}
                        >
                          {u.status}
                        </span>
                      </td>
                      <td className="py-3 px-4 text-right space-x-1">
                        {u.status === "pending" && (
                          <>
                            <button
                              onClick={() => {
                                setSelectedUser(u);
                                setActionType("approve");
                              }}
                              className="inline-flex items-center gap-1 rounded bg-emerald-600 hover:bg-emerald-700 text-white px-2.5 py-1 text-[11px] font-semibold transition-colors"
                            >
                              <Check className="h-3 w-3" /> Approve
                            </button>
                            <button
                              onClick={() => {
                                setSelectedUser(u);
                                setActionType("reject");
                              }}
                              className="inline-flex items-center gap-1 rounded bg-red-50 hover:bg-red-100 text-red-700 border border-red-200 px-2.5 py-1 text-[11px] font-semibold transition-colors"
                            >
                              <X className="h-3 w-3" /> Reject
                            </button>
                          </>
                        )}

                        {u.status === "approved" && u.role !== "admin" && (
                          <>
                            <button
                              onClick={() => {
                                setSelectedUser(u);
                                setTargetRole(u.role);
                                setActionType("role");
                              }}
                              className="rounded border border-slate-200 bg-white hover:bg-slate-50 text-slate-700 px-2 py-1 text-[11px] font-medium transition-colors"
                            >
                              Role
                            </button>
                            <button
                              onClick={() => {
                                setSelectedUser(u);
                                setActionType("suspend");
                              }}
                              className="rounded border border-slate-200 bg-white hover:bg-slate-50 text-red-600 px-2 py-1 text-[11px] font-medium transition-colors"
                            >
                              Suspend
                            </button>
                          </>
                        )}

                        {u.status === "suspended" && (
                          <button
                            onClick={() => {
                              setSelectedUser(u);
                              setActionType("activate");
                            }}
                            className="rounded bg-navy-900 hover:bg-navy-800 text-white px-2.5 py-1 text-[11px] font-semibold transition-colors"
                          >
                            Activate
                          </button>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {/* Mobile Cards View */}
            <div className="block md:hidden divide-y divide-slate-100">
              {users.map((u) => (
                <div key={u.id} className="p-4 space-y-2">
                  <div className="flex justify-between items-start">
                    <div>
                      <div className="font-semibold text-sm text-slate-900">{u.full_name}</div>
                      <div className="text-xs text-slate-500">{u.email}</div>
                    </div>
                    <span
                      className={`px-2 py-0.5 rounded text-[10px] font-bold uppercase ${
                        u.status === "approved"
                          ? "bg-emerald-100 text-emerald-800"
                          : u.status === "pending"
                          ? "bg-amber-100 text-amber-800"
                          : "bg-slate-200 text-slate-800"
                      }`}
                    >
                      {u.status}
                    </span>
                  </div>

                  <div className="text-xs text-slate-600 flex justify-between">
                    <span>{u.department || "IMD"}</span>
                    <span className="font-bold uppercase text-navy-900">{u.role}</span>
                  </div>

                  <div className="pt-2 flex flex-wrap gap-2 justify-end">
                    {u.status === "pending" && (
                      <>
                        <button
                          onClick={() => {
                            setSelectedUser(u);
                            setActionType("approve");
                          }}
                          className="rounded bg-emerald-600 text-white px-3 py-1 text-xs font-semibold"
                        >
                          Approve
                        </button>
                        <button
                          onClick={() => {
                            setSelectedUser(u);
                            setActionType("reject");
                          }}
                          className="rounded border border-red-200 bg-red-50 text-red-700 px-3 py-1 text-xs font-semibold"
                        >
                          Reject
                        </button>
                      </>
                    )}
                    {u.status === "approved" && u.role !== "admin" && (
                      <button
                        onClick={() => {
                          setSelectedUser(u);
                          setActionType("suspend");
                        }}
                        className="rounded border border-slate-200 text-red-600 px-3 py-1 text-xs font-semibold"
                      >
                        Suspend
                      </button>
                    )}
                  </div>
                </div>
              ))}
            </div>

            {/* Pagination Controls */}
            <div className="p-4 border-t border-slate-200 bg-slate-50 flex items-center justify-between text-xs text-slate-600">
              <div>
                Showing <span className="font-semibold">{users.length}</span> of{" "}
                <span className="font-semibold">{total}</span> users
              </div>
              <div className="flex items-center gap-2">
                <button
                  disabled={page <= 1}
                  onClick={() => setPage(page - 1)}
                  className="rounded border border-slate-300 bg-white p-1 hover:bg-slate-100 disabled:opacity-40"
                >
                  <ChevronLeft className="h-4 w-4" />
                </button>
                <span>
                  Page {page} of {totalPages}
                </span>
                <button
                  disabled={page >= totalPages}
                  onClick={() => setPage(page + 1)}
                  className="rounded border border-slate-300 bg-white p-1 hover:bg-slate-100 disabled:opacity-40"
                >
                  <ChevronRight className="h-4 w-4" />
                </button>
              </div>
            </div>
          </>
        )}
      </div>

      {/* Confirmation & Action Dialog */}
      {actionType && selectedUser && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="bg-white w-full max-w-md rounded-xl p-6 shadow-xl space-y-4">
            <h3 className="text-lg font-bold text-navy-900 capitalize">
              {actionType === "role" ? "Change Role" : `${actionType} User`}
            </h3>

            <p className="text-sm text-slate-600">
              Are you sure you want to perform this action for{" "}
              <strong className="text-slate-900">{selectedUser.full_name}</strong> ({selectedUser.email})?
            </p>

            {actionType === "reject" && (
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Rejection Reason</label>
                <textarea
                  rows={2}
                  required
                  value={rejectReason}
                  onChange={(e) => setRejectReason(e.target.value)}
                  placeholder="Provide reason for audit log..."
                  className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                />
              </div>
            )}

            {actionType === "role" && (
              <div className="space-y-1">
                <label className="text-xs font-semibold text-slate-700">Assign New Role</label>
                <select
                  value={targetRole}
                  onChange={(e) => setTargetRole(e.target.value)}
                  className="w-full rounded-lg border border-slate-300 p-2 text-xs focus:ring-2 focus:ring-primary focus:outline-none"
                >
                  <option value="trainee">Trainee</option>
                  <option value="trainer">Trainer</option>
                  <option value="admin">Administrator</option>
                </select>
              </div>
            )}

            <div className="flex justify-end gap-2 pt-2">
              <button
                type="button"
                onClick={() => {
                  setActionType(null);
                  setSelectedUser(null);
                }}
                className="rounded-lg border border-slate-300 px-4 py-2 text-xs font-semibold text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                type="button"
                disabled={actionLoading}
                onClick={handleConfirmAction}
                className={`rounded-lg px-4 py-2 text-xs font-semibold text-white transition-colors ${
                  actionType === "reject" || actionType === "suspend"
                    ? "bg-red-600 hover:bg-red-700"
                    : "bg-primary hover:bg-primary-hover"
                }`}
              >
                {actionLoading ? "Processing..." : "Confirm"}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
