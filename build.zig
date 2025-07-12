// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const builtin = @import("builtin");

const LazyPath = std.Build.LazyPath;

pub const pybuild = @import("pydust/src/build/root.zig");
const InterpreterConfig = pybuild.InterpreterConfig;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const python_exe = b.option([]const u8, "python-exe", "Python executable to use") orelse "python3";
    const abi3 = b.option(bool, "abi3", "Build with limited API (ABI3) support") orelse false;

    const check_step = b.step("check", "Check errors");
    const test_step = b.step("test", "Run library tests");
    const docs_step = b.step("docs", "Generate docs");

    const interpreter_config = InterpreterConfig.fromInterpreter(b.allocator, python_exe, abi3) catch |err| {
        std.debug.print("Failed to get interpreter config: {}", .{err});
        return;
    };
    defer interpreter_config.deinit();

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("pydust/src/ffi.h"),
        .target = target,
        .optimize = optimize,
    });
    if (abi3) {
        translate_c.defineCMacro("Py_LIMITED_API", "0x030D0000");
    }
    translate_c.addIncludePath(LazyPath { .cwd_relative = interpreter_config.include_dir });

    const pyconf = b.addOptions();
    pyconf.addOption([:0]const u8, "module_name", "test");
    pyconf.addOption(bool, "limited_api", abi3);
    pyconf.addOption([]const u8, "hexversion", interpreter_config.hexversion);

    // We never build this lib, but we use it to generate docs.
    const pydust_lib = b.addSharedLibrary(.{
        .name = "pydust",
        .root_source_file = b.path("pydust/src/pydust.zig"),
        .target = target,
        .optimize = optimize,
    });
    pydust_lib.root_module.addImport("ffi", translate_c.createModule());
    pydust_lib.root_module.addImport("pyconf", pyconf.createModule());

    check_step.dependOn(&pydust_lib.step);

    const pydust_docs = b.addInstallDirectory(.{
        .source_dir = pydust_lib.getEmittedDocs(),
        // Emit the Zig docs into zig-out/../docs/zig
        .install_dir = .{ .custom = "../docs" },
        .install_subdir = "zig",
    });
    docs_step.dependOn(&pydust_docs.step);

    const main_tests = b.addTest(.{
        .root_source_file = b.path("pydust/src/pydust.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_tests.linkLibC();
    main_tests.linkSystemLibrary(interpreter_config.libname.str());
    main_tests.addIncludePath(LazyPath { .cwd_relative = interpreter_config.include_dir });
    main_tests.addLibraryPath(LazyPath { .cwd_relative = interpreter_config.libdir.? });
    main_tests.addRPath(LazyPath { .cwd_relative = interpreter_config.libdir.? });
    // const main_tests_mod = b.createModule(.{ .root_source_file = b.path("./pyconf.dummy.zig") });
    // main_tests_mod.addIncludePath(b.path(interpreter_config.include_dir));
    main_tests.root_module.addImport("ffi", translate_c.createModule());
    main_tests.root_module.addImport("pyconf", pyconf.createModule());
    // main_tests.root_module.addImport("pydust", pydust_lib.root_module);

    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Setup a library target to trick the Zig Language Server into providing completions for @import("pydust")
    const example_lib = b.addSharedLibrary(.{
        .name = "example",
        .root_source_file = b.path("example/hello.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_lib.linkLibC();
    example_lib.addIncludePath(LazyPath { .cwd_relative = interpreter_config.include_dir });
    example_lib.linkSystemLibrary(interpreter_config.libname.str());
    example_lib.addRPath(LazyPath { .cwd_relative = interpreter_config.libdir.? });

    const example_lib_mod = b.createModule(.{ .root_source_file = b.path("pydust/src/pydust.zig") });
    example_lib_mod.addIncludePath(LazyPath { .cwd_relative = interpreter_config.include_dir });
    example_lib.root_module.addImport("ffi", translate_c.createModule());
    example_lib.root_module.addImport("pydust", example_lib_mod);
    example_lib.root_module.addImport("pyconf", pyconf.createModule());

    // Option for emitting test binary based on the given root source.
    // This is used for debugging as in .vscode/tasks.json
    const test_debug_root = b.option([]const u8, "test-debug-root", "The root path of a file emitted as a binary for use with the debugger");
    if (test_debug_root) |root| {
        main_tests.root_module.root_source_file = b.path(root);
        const test_bin_install = b.addInstallBinFile(main_tests.getEmittedBin(), "test.bin");
        b.getInstallStep().dependOn(&test_bin_install.step);
    }
}
