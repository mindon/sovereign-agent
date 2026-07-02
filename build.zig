const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "sovereign-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the Sovereign-Agent demo");
    run_step.dependOn(&run_cmd.step);

    // 复用的库模块：examples/ 下的演示与黑盒测试均以 `@import("sovereign")` 引用，
    // 只消费 root.zig 的公共导出（不触碰内核内部实现）。
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // —— Ollama / OpenAI 兼容 端到端 demo（需网络/LLM，独立入口，不进 CI 聚合）——
    const ollama_exe = b.addExecutable(.{
        .name = "sovereign-agent-ollama",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/agent_ollama.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sovereign", .module = lib_mod }},
        }),
    });
    b.installArtifact(ollama_exe);
    const run_ollama = b.addRunArtifact(ollama_exe);
    run_ollama.step.dependOn(b.getInstallStep());
    const run_ollama_step = b.step("run-ollama", "Run the Sovereign-Agent × LLM (Ollama/OpenAI-compatible) demo");
    run_ollama_step.dependOn(&run_ollama.step);

    // —— 对抗性实际场景压力测试（DevOps 部署助理 + 防御评分卡，需网络/LLM）——
    const scenario_exe = b.addExecutable(.{
        .name = "sovereign-agent-scenario",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/scenario_ollama.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sovereign", .module = lib_mod }},
        }),
    });
    b.installArtifact(scenario_exe);
    const run_scenario = b.addRunArtifact(scenario_exe);
    run_scenario.step.dependOn(b.getInstallStep());
    const run_scenario_step = b.step("run-scenario", "Run the adversarial real-world zero-trust scenario test");
    run_scenario_step.dependOn(&run_scenario.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // —— examples/：离线、确定性的黑盒测试（把内核当黑盒，只走公共接口）——
    // 复用上文定义的 lib_mod，供 examples 以 `@import("sovereign")` 引用。
    const Example = struct { name: []const u8, path: []const u8, desc: []const u8 };
    const examples = [_]Example{
        .{ .name = "example-sabotage", .path = "examples/sabotage_test.zig", .desc = "黑盒测试一：幻觉拦截与惩罚 (The Sabotage Test)" },
        .{ .name = "example-cognitive-shift", .path = "examples/cognitive_shift_test.zig", .desc = "黑盒测试二：元认知行为改变 (The Cognitive Shift Test)" },
        .{ .name = "example-ledger-replay", .path = "examples/ledger_replay_test.zig", .desc = "黑盒测试三：金融级确定性重放 (Ledger Replay Test)" },
        .{ .name = "example-subsumption", .path = "examples/subsumption_test.zig", .desc = "黑盒测试四：包容式行为栈 (The Subsumption Test)" },
        .{ .name = "example-instinct", .path = "examples/instinct_test.zig", .desc = "黑盒测试五：持续学习与本能烧录 (The Instinct Test)" },
        .{ .name = "example-stigmergy", .path = "examples/stigmergy_test.zig", .desc = "黑盒测试六：环境计算与去中心化协同 (The Stigmergy Test)" },
        .{ .name = "example-routing", .path = "examples/routing_test.zig", .desc = "黑盒测试七：无状态路由拓扑 (The Stateless Routing Test)" },
        .{ .name = "example-persona", .path = "examples/persona_test.zig", .desc = "黑盒测试八：专家模式切换 (The Persona Test)" },
    };

    const examples_step = b.step("examples", "Run all black-box example tests (offline, deterministic)");
    inline for (examples) |ex| {
        const exe_ex = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "sovereign", .module = lib_mod }},
            }),
        });
        const run_ex = b.addRunArtifact(exe_ex);
        const single = b.step(ex.name, ex.desc);
        single.dependOn(&run_ex.step);
        examples_step.dependOn(&run_ex.step);
    }
}
