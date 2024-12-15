const std = @import("std");
const Build = std.Build;
const Allocator = std.mem.Allocator;

const fetcher = @import("tools/fetch_queries.zig");

const Options = std.Build.Step.Options;

const Dependency = struct {
    name: []const u8,
    module: *std.Build.Module,
};

const ExeConfig = struct {
    version: ?std.SemanticVersion = null, // The version of the executable
    name: []const u8, // The name for the generated executable
    build_cmd: []const u8, // The build step name ('zig build <cmd>')
    build_description: []const u8, // The description for the build step ('zig build -l')
    run_cmd: []const u8, // The run step name ('zig build <cmd>')
    run_description: []const u8, //  The description for the run step ('zig build -l')
    root_path: []const u8, // The zig file containing main()
};

const BuildOpts = struct {
    optimize: std.builtin.OptimizeMode,
    target: ?std.Build.ResolvedTarget = null,
    dependencies: ?[]Dependency = null,
    options: *Options,
};

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimize options allows the user to choose the optimization mode
    // when running 'zig build'.  This applies to downstream consumers of this package
    // as well, e.g. when added as a dependency in build.zig.zon.
    // Default to Debug, but allow the user to specify ReleaseSafe or ReleaseFast builds
    var optimize: std.builtin.OptimizeMode = b.standardOptimizeOption(.{});
    if (b.option(bool, "safe", "Build ReleaseSafe mode") != null) {
        optimize = .ReleaseSafe;
    } else if (b.option(bool, "small", "Build ReleaseSmall mode") != null) {
        optimize = .ReleaseSmall;
    } else if (b.option(bool, "fast", "Build ReleaseFast mode") != null) {
        optimize = .ReleaseFast;
    }

    // const wasm_optimize = b.option(std.builtin.OptimizeMode, "wasm-optimize", "Optimization mode for WASM targets") orelse .ReleaseSmall;

    const build_lua = b.option(bool, "lua", "Build Zigdown as a Lua module") orelse false;
    const build_query_fetcher = b.option(bool, "build-query-fetcher", "Build the TreeSitter query fetcher") orelse false;
    const build_test_exes = b.option(bool, "build-test-exes", "Build the custom test executables") orelse false;

    // Add an option to list the set of TreeSitter parsers to statically link into the build
    // This should match the list of parsers defined below and added to the 'queries' module
    const builtin_ts_option = "builtin_ts_parsers";
    const builtin_ts_option_desc = "List of TreeSitter parsers to bake into the build";
    const ts_parser_list = b.option([]const u8, builtin_ts_option, builtin_ts_option_desc) orelse "bash,c,cpp,json,python,rust,zig";

    const options: *Options = b.addOptions();
    options.addOption([]const u8, builtin_ts_option, ts_parser_list);

    // Export the zigdown module to downstream consumers
    const mod = b.addModule("zigdown", .{
        .root_source_file = b.path("src/zigdown.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mod_dep = Dependency{ .name = "zigdown", .module = mod };

    mod.addOptions("config", options);

    // Get all of our dependencies, both from build.zig.zon and our TreeSitter module
    var deps: std.ArrayList(Dependency) = try getDependencies(b, target, optimize);

    // Add all dependencies to our "root" Zigdown module, then add that to the dependencies list
    for (deps.items) |dep| {
        mod.addImport(dep.name, dep.module);
    }
    try deps.append(mod_dep);

    const exe_opts = BuildOpts{
        .target = target,
        .optimize = optimize,
        .dependencies = deps.items,
        .options = options,
    };

    // Compile the main executable
    const exe_config = ExeConfig{
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
        .name = "zigdown",
        .build_cmd = "zigdown",
        .build_description = "Build the Zigdown executable",
        .run_cmd = "run",
        .run_description = "Run the Zigdown executable (use `-- <args>` to supply arguments)",
        .root_path = "src/main.zig",
    };
    addExecutable(b, exe_config, exe_opts);

    if (build_lua) {
        // TODO
        // const luajit = b.dependency("luajit", .{ .optimize = optimize, .target = target });
        // const luajit_dep = Dependency{ .name = "luajit", .module = luajit.module("luajit") };
        // const lua51 = b.dependency("lua51", .{ .optimize = optimize, .target = target });
        // const lua51_dep = Dependency{ .name = "lua51", .module = lua51.module("lua51") };
        // var lua_deps_array = [_]Dependency{ luajit_dep, lua51_dep };
        // const lua_deps: []Dependency = &lua_deps_array;

        // Compile Zigdown as a Lua module compatible with Neovim / LuaJIT 5.1
        // Requires LuaJIT 2.1 headers & Lua 5.1 library
        const lua_mod = b.addSharedLibrary(.{
            .name = "zigdown_lua",
            .root_source_file = b.path("src/lua_api.zig"),
            .target = target,
            .optimize = optimize,
        });
        if (exe_opts.dependencies) |deplist| {
            for (deplist) |dep| {
                lua_mod.root_module.addImport(dep.name, dep.module);
            }
        }

        // Point the compiler to the location of the Lua headers (lua.h and friends)
        // Note that we require Lua 5.1, specifically
        // This is compatible with the version of LuaJIT built into NeoVim
        lua_mod.addIncludePath(b.path("/usr/include/luajit-2.1"));
        lua_mod.linkSystemLibrary("lua5.1");

        // "Install" to the output dir using the correct naming convention to load with lua
        const copy_step = b.addInstallFileWithDir(lua_mod.getEmittedBin(), .{ .custom = "../lua/" }, "zigdown_lua.so");
        copy_step.step.dependOn(&lua_mod.step);
        b.getInstallStep().dependOn(&copy_step.step);
        const step = b.step("zigdown-lua", "Build Zigdown as a Lua module");
        step.dependOn(&copy_step.step);
    }

    if (build_query_fetcher) {
        // Compile the TreeSitter query-fetcher executable
        const query_fetcher = ExeConfig{
            .version = .{ .major = 0, .minor = 1, .patch = 0 },
            .name = "fetch_ts_queries",
            .build_cmd = "query-fetcher",
            .build_description = "TODO",
            .run_cmd = "fetch-queries",
            .run_description = "Fetch a list of TreeSitter highlights queries",
            .root_path = "tools/fetch_queries.zig",
        };
        addExecutable(b, query_fetcher, exe_opts);
    }

    // Build HTML library documentation
    // TODO: how to enable docs??
    const lib = b.addSharedLibrary(.{
        .name = "libzigdown",
        .root_source_file = b.path("src/zigdown.zig"),
        .optimize = optimize,
        .target = target,
    });
    b.installArtifact(lib);
    const lib_step = b.step("lib", "Build Zigdown as a shared library (and also build HTML docs)");
    lib_step.dependOn(&lib.step);
    b.getInstallStep().dependOn(lib_step);

    // Generate and install documentation
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Copy documentation artifacts to prefix path");
    docs_step.dependOn(&install_docs.step);

    ////////////////////////////////////////////////////////////////////////////
    // Add WASM Target
    // Requires a 'wasm32-freestanding' copy of all necessary dependencies
    // TODO: Still requires some implementation of most of libC to link
    // See: https://github.com/floooh/pacman.zig/blob/main/build.zig for an
    // example of using Emscripten as the linker
    ////////////////////////////////////////////////////////////////////////////
    // const wasm_target = b.resolveTargetQuery(.{
    //     .cpu_arch = .wasm32,
    //     .os_tag = .freestanding,
    //     // .abi = .none,
    // });

    // var wasm_deps: std.ArrayList(Dependency) = try getDependencies(b, wasm_target, wasm_optimize);

    // const wasm_mod = b.addModule("zigdown_wasm", .{
    //     .root_source_file = b.path("src/zigdown.zig"),
    //     .target = wasm_target,
    //     .optimize = wasm_optimize,
    // });
    // const wasm_mod_dep = Dependency{ .name = "zigdown", .module = wasm_mod };

    // wasm_mod.addOptions("config", options);

    // for (wasm_deps.items) |dep| {
    //     wasm_mod.addImport(dep.name, dep.module);
    // }
    // try wasm_deps.append(wasm_mod_dep);

    // const wasm = b.addExecutable(.{
    //     .name = "zigdown-wasm",
    //     .root_source_file = b.path("src/wasm_main.zig"),
    //     .optimize = .ReleaseSmall,
    //     .target = b.resolveTargetQuery(.{
    //         .cpu_arch = .wasm32,
    //         .os_tag = .freestanding,
    //         // .abi = .gnu,
    //     }),
    //     .link_libc = true,
    // });
    // wasm.entry = .disabled;
    // wasm.rdynamic = true;

    // const wasm_libc = b.addStaticLibrary(.{
    //     .name = "wasm-libc",
    //     .root_source_file = b.path("src/wasm/stdlib.zig"),
    //     .target = wasm_target,
    //     .optimize = wasm_optimize,
    //     .link_libc = true,
    // });
    // wasm_libc.addCSourceFile(.{ .file = b.path("src/wasm/stdlib.c") });
    // wasm.linkLibrary(wasm_libc);

    // wasm.root_module.addOptions("config", options);
    // for (wasm_deps.items) |dep| {
    //     wasm.root_module.addImport(dep.name, dep.module);
    // }

    // b.installArtifact(wasm);
    // const wasm_step = b.step("wasm", "Build Zigdown as a WASM library");
    // wasm_step.dependOn(&wasm.step);
    // b.getInstallStep().dependOn(wasm_step);

    ////////////////////////////////////////////////////////////////////////////
    // Add unit tests
    ////////////////////////////////////////////////////////////////////////////

    const test_opts = BuildOpts{ .optimize = optimize, .dependencies = deps.items, .options = options };

    addTest(b, "test-lexer", "Run Lexer unit tests", "src/lexer.zig", test_opts);
    addTest(b, "test-parser", "Run the new paresr tests", "src/parser.zig", test_opts);
    addTest(b, "test-render", "Run renderer unit tests", "src/render.zig", test_opts);
    addTest(b, "test-image", "Run the image rendering tests", "src/image.zig", test_opts);
    addTest(b, "test-all", "Run all unit tests", "src/test.zig", test_opts);

    // Add custom test executables
    if (build_test_exes) {
        const parser_test_config = ExeConfig{
            .name = "parser_test",
            .build_cmd = "build-parser-test",
            .build_description = "Build (don't run) the parser test executable",
            .run_cmd = "parser-test",
            .run_description = "Run the standalone parser test",
            .root_path = "src/test_parser.zig",
        };
        addExecutable(b, parser_test_config, exe_opts);

        const image_test_config = ExeConfig{
            .name = "image_test",
            .build_cmd = "build-image-test",
            .build_description = "Build (don't run) the image test executable",
            .run_cmd = "image-test",
            .run_description = "Run the standalone image test",
            .root_path = "src/image.zig",
        };
        addExecutable(b, image_test_config, exe_opts);
    }
}

/// Add an executable (build & run) step using the given file
///
/// @param[inout] b: Mutable pointer to the Build object
/// @param[in] optimize: Build optimization settings
fn addExecutable(b: *std.Build, config: ExeConfig, opts: BuildOpts) void {
    // Compile the executable
    const exe = b.addExecutable(.{
        .name = config.name,
        .root_source_file = b.path(config.root_path),
        .version = config.version,
        .optimize = opts.optimize,
        .target = opts.target orelse b.host,
    });

    // Add the executable to the default 'zig build' command
    b.installArtifact(exe);
    const install_step = b.addInstallArtifact(exe, .{});

    // Add dependencies
    if (opts.dependencies) |deps| {
        for (deps) |dep| {
            exe.root_module.addImport(dep.name, dep.module);
        }
    }
    exe.root_module.addOptions("config", opts.options);

    // Add a build-only step
    const build_step = b.step(config.build_cmd, config.build_description);
    build_step.dependOn(&exe.step);
    build_step.dependOn(&install_step.step);

    // Configure how the main executable should be run
    const run_exe = b.addRunArtifact(exe);
    const exe_install = b.addInstallArtifact(exe, .{});
    run_exe.step.dependOn(&exe_install.step);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const step = b.step(config.run_cmd, config.run_description);
    step.dependOn(&run_exe.step);
}

/// Add a unit test step using the given file
///
/// @param[inout] b: Mutable pointer to the Build object
/// @param[in] cmd: The build step name ('zig build cmd')
/// @param[in] description: The description for 'zig build -l'
/// @param[in] path: The zig file to test
/// @param[in] opts: Build target and optimization settings, along with any dependencies needed
fn addTest(b: *std.Build, cmd: []const u8, description: []const u8, path: []const u8, opts: BuildOpts) void {
    const test_exe = b.addTest(.{
        .root_source_file = b.path(path),
        .optimize = opts.optimize,
        .target = opts.target,
        .test_runner = b.path("tools/test_runner.zig"),
    });

    if (opts.dependencies) |deps| {
        for (deps) |dep| {
            test_exe.root_module.addImport(dep.name, dep.module);
        }
    }
    test_exe.root_module.addOptions("config", opts.options);

    const run_step = b.addRunArtifact(test_exe);
    run_step.has_side_effects = true; // Force the test to always be run on command
    const step = b.step(cmd, description);
    step.dependOn(&run_step.step);
}

fn isWasm(target: std.Build.ResolvedTarget) bool {
    if (target.query.cpu_arch) |arch| {
        return switch (arch) {
            .wasm32, .wasm64 => true,
            else => false,
        };
    }
    return false;
}

fn getDependencies(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) !std.ArrayList(Dependency) {
    var dependencies = std.ArrayList(Dependency).init(b.allocator);

    ///////////////////////////////////////////////////////////////////////////
    // Module for our built-in TreeSitter queries
    // ------------------------------------------------------------------------
    const query_mod = b.addModule("queries", .{
        .root_source_file = b.path("data/queries.zig"),
        .target = target,
        .optimize = optimize,
    });
    query_mod.addIncludePath(b.path("data"));
    const query_dep = Dependency{ .name = "queries", .module = query_mod };

    // Baked-In TreeSitter Parser Libraries
    const TsParserConfig = struct {
        name: []const u8,
        scanner: ?[]const u8 = null,
    };
    const parsers: []const TsParserConfig = &[_]TsParserConfig{
        .{ .name = "bash", .scanner = "src/scanner.c" },
        .{ .name = "c" },
        .{ .name = "cpp", .scanner = "src/scanner.c" },
        .{ .name = "json" },
        .{ .name = "python", .scanner = "src/scanner.c" },
        .{ .name = "rust", .scanner = "src/scanner.c" },
        .{ .name = "zig" },
    };
    for (parsers) |parser| {
        const dep_name = try std.fmt.allocPrint(b.allocator, "tree_sitter_{s}", .{parser.name});
        const ts = b.dependency(dep_name, .{ .optimize = optimize, .target = target });
        query_mod.addCSourceFile(.{ .file = ts.path("src/parser.c") });
        if (parser.scanner) |scanner| {
            query_mod.addCSourceFile(.{ .file = ts.path(scanner) });
        }
        query_mod.addIncludePath(ts.path("src"));
    }

    try dependencies.append(query_dep);

    ///////////////////////////////////////////////////////////////////////////
    // Dependencies from build.zig.zon
    // ------------------------------------------------------------------------
    if (!isWasm(target)) {
        // STB-Image
        const stbi = b.dependency("stbi", .{ .optimize = optimize, .target = target });
        const stbi_dep = Dependency{ .name = "stb_image", .module = stbi.module("stb_image") };
        try dependencies.append(stbi_dep);

        // Flags
        const flags = b.dependency("flags", .{ .optimize = optimize, .target = target });
        const flags_dep = Dependency{ .name = "flags", .module = flags.module("flags") };
        try dependencies.append(flags_dep);
    }

    // Treez (TreeSitter wrapper library)
    const treez = b.dependency("treez", .{ .optimize = optimize, .target = target });
    const treez_dep = Dependency{ .name = "treez", .module = treez.module("treez") };
    try dependencies.append(treez_dep);
    query_mod.addImport(treez_dep.name, treez_dep.module);

    return dependencies;
}
