const std = @import("std");

const Server = @import("server/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const dev_server = Server.add(
        b,
        "server/",
        target,
        .Debug,
    );

    const dev = b.step("dev", "Run the dev server");
    dev.dependOn(&dev_server.run.step);

    const release_server = Server.add(
        b,
        "server/",
        target,
        .ReleaseSafe,
    );

    const run = b.step("run", "Run the release server");
    run.dependOn(&release_server.run.step);
    b.installArtifact(release_server.exe);

    b.install_tls.description = "Build and install the release server";
    b.uninstall_tls.description = "Uninstall the release server";
}
