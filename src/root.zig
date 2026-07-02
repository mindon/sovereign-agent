//! Sovereign-Agent 库根模块：统一对外导出核心类型，并聚合各模块单元测试。

const std = @import("std");

pub const event = @import("event.zig");
pub const journal = @import("journal.zig");
pub const memory = @import("memory.zig");
pub const arbiter = @import("arbiter.zig");
pub const agent = @import("agent.zig");
pub const replay = @import("replay.zig");
pub const llm = @import("llm.zig");
pub const stigmergy = @import("stigmergy.zig");
pub const router = @import("router.zig");
pub const persona = @import("persona.zig");

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
pub const Verdict = arbiter.Verdict;
pub const BehaviorStack = arbiter.BehaviorStack;
pub const Layer = arbiter.Layer;
pub const AgentContext = agent.AgentContext;
pub const Executor = agent.Executor;
pub const transact = agent.transact;
pub const rebuildState = replay.rebuildState;
pub const Stigmergy = stigmergy.Stigmergy;
pub const Route = router.Route;
pub const RouteResult = router.RouteResult;
pub const dispatch = router.dispatch;
pub const OllamaClient = llm.OllamaClient;
pub const LlmClient = llm.LlmClient;
pub const Provider = llm.Provider;
pub const EnvConfig = llm.EnvConfig;
pub const Decision = llm.Decision;
pub const ExpertProfile = persona.ExpertProfile;
pub const Session = persona.Session;
pub const Registry = persona.Registry;
pub const SeedSpec = persona.SeedSpec;
pub const Sensitivity = persona.Sensitivity;
pub const LlmOverride = persona.LlmOverride;

test {
    std.testing.refAllDecls(@This());
}
