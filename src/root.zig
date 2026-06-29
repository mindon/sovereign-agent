//! Sovereign-Agent 库根模块：统一对外导出核心类型，并聚合各模块单元测试。

const std = @import("std");

pub const event = @import("event.zig");
pub const journal = @import("journal.zig");
pub const memory = @import("memory.zig");
pub const arbiter = @import("arbiter.zig");
pub const agent = @import("agent.zig");
pub const replay = @import("replay.zig");
pub const llm = @import("llm.zig");

// 常用类型再导出
pub const ActionType = event.ActionType;
pub const EventStatus = event.EventStatus;
pub const Action = event.Action;
pub const Event = event.Event;
pub const Journal = journal.Journal;
pub const MemoryManager = memory.MemoryManager;
pub const Seed = memory.Seed;
pub const Outcome = memory.Outcome;
pub const Arbiter = arbiter.Arbiter;
pub const Probe = arbiter.Probe;
pub const AgentContext = agent.AgentContext;
pub const Executor = agent.Executor;
pub const transact = agent.transact;
pub const rebuildState = replay.rebuildState;
pub const OllamaClient = llm.OllamaClient;
pub const LlmClient = llm.LlmClient;
pub const Provider = llm.Provider;
pub const EnvConfig = llm.EnvConfig;
pub const Decision = llm.Decision;

test {
    std.testing.refAllDecls(@This());
}
