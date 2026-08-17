const std = @import("std");
const Build = std.Build;
const Optimize = std.lang.Optimize;
const ResolvedTarget = std.Build.ResolvedTarget;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const steps = .{
        .install = b.getInstallStep(),
        .@"test" = b.step("test", "Run the unit tests"),
        .@"run-sdk-server" = b.step("run-sdk-server", "Run the sdk server (HeSDK emulator)"),
        .@"run-dir-server" = b.step("run-dir-server", "Run the dir server (game configuration)"),
        .@"run-scene-server" = b.step("run-scene-server", "Run the scene server (game logic)"),
    };

    const roze = configureRoze(
        b,
        .{ .@"test" = steps.@"test" },
        .{
            .target = target,
            .optimize = optimize,
        },
    );

    configureProto(
        b,
        .{ .@"test" = steps.@"test" },
        .{
            .roze = roze,
            .optimize = optimize,
        },
    );

    configureAssets(
        b,
        .{ .roze = roze },
    );

    configureSdkServer(
        b,
        .{
            .install = steps.install,
            .@"test" = steps.@"test",
            .@"run-sdk-server" = steps.@"run-sdk-server",
        },
        .{
            .roze = roze,
            .target = target,
            .optimize = optimize,
        },
    );

    configureDirServer(
        b,
        .{
            .install = steps.install,
            .@"test" = steps.@"test",
            .@"run-dir-server" = steps.@"run-dir-server",
        },
        .{
            .roze = roze,
            .target = target,
            .optimize = optimize,
        },
    );

    configureSceneServer(
        b,
        .{
            .install = steps.install,
            .@"test" = steps.@"test",
            .@"run-scene-server" = steps.@"run-scene-server",
        },
        .{
            .roze = roze,
            .target = target,
            .optimize = optimize,
        },
    );
}

/// Configures the shared module and associated tests.
fn configureRoze(
    b: *Build,
    steps: struct { @"test": *Build.Step },
    options: struct {
        target: ResolvedTarget,
        optimize: Optimize,
    },
) *Build.Module {
    const roze = b.addModule("roze", .{
        .root_source_file = b.path("src/roze.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    const @"test-roze" = b.addRunArtifact(b.addTest(.{
        .name = "test-roze",
        .root_module = roze,
    }));
    steps.@"test".dependOn(&@"test-roze".step);

    return roze;
}

/// Configures the protobuf compilation.
fn configureProto(
    b: *Build,
    steps: struct { @"test": *Build.Step },
    options: struct {
        roze: *Build.Module,
        optimize: Optimize,
    },
) void {
    const @"roze-compile-proto" = b.createModule(.{
        .root_source_file = b.path("lib/build/compile-proto.zig"),
        .target = b.graph.host,
        .optimize = options.optimize,
    });

    const @"test-protobuf-compiler" = b.addTest(.{
        .name = "test-protobuf-compiler",
        .root_module = @"roze-compile-proto",
    });
    steps.@"test".dependOn(&b.addRunArtifact(@"test-protobuf-compiler").step);

    const executable = b.addExecutable(.{
        .name = "roze-compile-proto",
        .root_module = @"roze-compile-proto",
    });
    const compile = b.addRunArtifact(executable);

    const proto_dir = b.root.openDir(b.graph.io, "lib/proto", .{ .iterate = true }) catch |err|
        std.debug.panic("failed to open proto dir: {t}", .{err});
    defer proto_dir.close(b.graph.io);

    var it = proto_dir.iterateAssumeFirstIteration();
    while (it.next(b.graph.io) catch @panic("failed to read dir")) |entry| {
        if (entry.kind != .file) continue;
        compile.addFileArg(b.path(b.fmt("lib/proto/{s}", .{entry.name})));
    }

    compile.expectExitCode(0);
    const generated = compile.captureStdOut(.{ .basename = "gen.zig" });
    options.roze.addAnonymousImport("roze-proto", .{ .root_source_file = generated });
}

/// Configures the asset embedding
fn configureAssets(
    b: *Build,
    options: struct { roze: *Build.Module },
) void {
    // https://codeberg.org/ziglang/zig/src/commit/6716bf52e70791104caf057af3fece674f0ac3dd/lib/compiler/Maker.zig#L1514
    // b.dependOnDirectory(b.path("assets/tables/"));
    b.graph.poisonCache();

    const tables_dir = b.root.openDir(b.graph.io, "assets/tables/", .{ .iterate = true }) catch |err|
        std.debug.panic("failed to open tables directory: {t}", .{err});
    defer tables_dir.close(b.graph.io);

    var it = tables_dir.iterateAssumeFirstIteration();
    while (it.next(b.graph.io) catch @panic("failed to read directory")) |entry| {
        if (entry.kind != .file) continue;
        options.roze.addAnonymousImport(
            std.Io.Dir.path.stem(entry.name),
            .{ .root_source_file = b.path(b.fmt("assets/tables/{s}", .{entry.name})) },
        );
    }
}

/// Configures the roze-sdk-server and associated tests.
fn configureSdkServer(
    b: *Build,
    steps: struct {
        install: *Build.Step,
        @"test": *Build.Step,
        @"run-sdk-server": *Build.Step,
    },
    options: struct {
        roze: *Build.Module,
        target: ResolvedTarget,
        optimize: Optimize,
    },
) void {
    const module = b.createModule(.{
        .root_source_file = b.path("lib/server/roze-sdk-server.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "roze", .module = options.roze }},
    });

    const @"test-sdk-server" = b.addRunArtifact(b.addTest(.{
        .name = "test-sdk-server",
        .root_module = module,
    }));
    steps.@"test".dependOn(&@"test-sdk-server".step);

    const @"roze-sdk-server" = b.addExecutable(.{
        .name = "roze-sdk-server",
        .root_module = module,
    });
    const install = b.addInstallArtifact(@"roze-sdk-server", .{});
    steps.install.dependOn(&install.step);

    const @"run-sdk-server" = b.addRunArtifact(@"roze-sdk-server");
    @"run-sdk-server".addPassthruArgs();
    steps.@"run-sdk-server".dependOn(&@"run-sdk-server".step);
}

/// Configures the roze-dir-server and associated tests.
fn configureDirServer(
    b: *Build,
    steps: struct {
        install: *Build.Step,
        @"test": *Build.Step,
        @"run-dir-server": *Build.Step,
    },
    options: struct {
        roze: *Build.Module,
        target: ResolvedTarget,
        optimize: Optimize,
    },
) void {
    const module = b.createModule(.{
        .root_source_file = b.path("lib/server/roze-dir-server.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "roze", .module = options.roze }},
    });

    const @"test-dir-server" = b.addRunArtifact(b.addTest(.{
        .name = "test-dir-server",
        .root_module = module,
    }));
    steps.@"test".dependOn(&@"test-dir-server".step);

    const @"roze-dir-server" = b.addExecutable(.{
        .name = "roze-dir-server",
        .root_module = module,
    });
    const install = b.addInstallArtifact(@"roze-dir-server", .{});
    steps.install.dependOn(&install.step);

    const @"run-dir-server" = b.addRunArtifact(@"roze-dir-server");
    @"run-dir-server".addPassthruArgs();
    steps.@"run-dir-server".dependOn(&@"run-dir-server".step);
}

/// Configures the roze-scene-server and associated tests.
fn configureSceneServer(
    b: *Build,
    steps: struct {
        install: *Build.Step,
        @"test": *Build.Step,
        @"run-scene-server": *Build.Step,
    },
    options: struct {
        roze: *Build.Module,
        target: ResolvedTarget,
        optimize: Optimize,
    },
) void {
    const module = b.createModule(.{
        .root_source_file = b.path("lib/server/roze-scene-server.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "roze", .module = options.roze }},
    });

    const @"test-scene-server" = b.addRunArtifact(b.addTest(.{
        .name = "test-scene-server",
        .root_module = module,
    }));
    steps.@"test".dependOn(&@"test-scene-server".step);

    const @"roze-scene-server" = b.addExecutable(.{
        .name = "roze-scene-server",
        .root_module = module,
    });
    const install = b.addInstallArtifact(@"roze-scene-server", .{});
    steps.install.dependOn(&install.step);

    const @"run-scene-server" = b.addRunArtifact(@"roze-scene-server");
    @"run-scene-server".addPassthruArgs();
    steps.@"run-scene-server".dependOn(&@"run-scene-server".step);
}
