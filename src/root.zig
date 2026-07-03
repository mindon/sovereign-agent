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
pub const persona_config = @import("persona_config.zig");

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
// —— 在线自蒸馏（LLM 蒸馏知识 → 零信任注入 memory）——
pub const DistilledSeed = memory.DistilledSeed;
pub const distillSystemPrompt = llm.DISTILL_SYSTEM_PROMPT;
pub const parseDistilled = llm.parseDistilled;
pub const ExpertProfile = persona.ExpertProfile;
pub const Session = persona.Session;
pub const Registry = persona.Registry;
pub const SeedSpec = persona.SeedSpec;
pub const Sensitivity = persona.Sensitivity;
pub const LlmOverride = persona.LlmOverride;
// —— 配置驱动的可插拔专家（从 ZON 配置运行时加载）——
pub const ProfileConfig = persona_config.ProfileConfig;
pub const SeedConfig = persona_config.SeedConfig;
pub const LlmConfig = persona_config.LlmConfig;
pub const ConfigRegistry = persona_config.ConfigRegistry;
pub const loadPersonaBytes = persona_config.loadBytes;
pub const loadPersonaFile = persona_config.loadFile;
pub const loadPersonaDir = persona_config.loadDir;
// —— 能力③：memory → .zon 回写（config ↔ memory 往返闭环）——
pub const exportProfile = persona_config.exportProfile;
pub const metaFromProfile = persona_config.metaFromProfile;
pub const SeedDump = memory.SeedDump;

test {
    std.testing.refAllDecls(@This());
}
