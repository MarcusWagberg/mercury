const std = @import("std");

const Self = @This();

exe: *std.Build.Step.Compile,
run: *std.Build.Step.Run,

pub fn add(b: *std.Build, comptime server_root: []const u8, target: std.zig.CrossTarget, optimize: std.builtin.Mode) Self {
    const zap = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
    });
    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "mercury-server",
        .root_source_file = .{ .path = server_root ++ "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.addModule("zap", zap.module("zap"));
    exe.linkLibrary(zap.artifact("facil.io"));
    exe.addModule("clap", clap.module("clap"));

    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }

    return Self{
        .exe = exe,
        .run = run,
    };
}
