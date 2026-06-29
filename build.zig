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

    // —— Ollama(gemma4) 端到端 demo ——
    const ollama_exe = b.addExecutable(.{
        .name = "sovereign-agent-ollama",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent_ollama.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(ollama_exe);
    const run_ollama = b.addRunArtifact(ollama_exe);
    run_ollama.step.dependOn(b.getInstallStep());
    const run_ollama_step = b.step("run-ollama", "Run the Sovereign-Agent × Ollama(gemma4) demo");
    run_ollama_step.dependOn(&run_ollama.step);

    // —— 对抗性实际场景压力测试（DevOps 部署助理 + 防御评分卡）——
    const scenario_exe = b.addExecutable(.{
        .name = "sovereign-agent-scenario",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scenario_ollama.zig"),
            .target = target,
            .optimize = optimize,
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
}
