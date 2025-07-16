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
const Step = std.Build.Step;

pub const InterpreterConfig = @import("pydust/src/build/InterpreterConfig.zig");

const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // const python_exe = b.option([]const u8, "python-exe", "Python executable to use") orelse "python3";
    // const abi3 = b.option(bool, "abi3", "Build with limited API (ABI3) support") orelse false;

    const check_step = b.step("check", "Check errors");
    const test_step = b.step("test", "Run library tests");
    const docs_step = b.step("docs", "Generate docs");

    // const interpreter_config = InterpreterConfig.fromInterpreter(b.allocator, python_exe, abi3) catch |err| {
    //     std.debug.print("Failed to get interpreter config: {}", .{err});
    //     return;
    // };
    // defer interpreter_config.deinit();
    const py = PydustStep.add(b, .{
        .test_step = test_step,
    });
    defer py.deinit();

    const interpreter_config = py.interpreter_config;

    // const translate_c = b.addTranslateC(.{
    //     .root_source_file = b.path("pydust/src/ffi.h"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // if (abi3) {
    //     translate_c.defineCMacro("Py_LIMITED_API", "0x030D0000");
    // }
    // translate_c.addIncludePath(LazyPath { .cwd_relative = interpreter_config.include_dir });

    const options: PydustStep.PyModuleOptions = .{
        .name = "pydust",
        // .root_source_file = b.path("pydust/src/pydust.zig"),
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = LazyPath{ .cwd_relative = interpreter_config.pydust_root_zig },
        }),
        .target = target,
        .optimize = optimize,
        .main_pkg_path = null,
        .abi3 = interpreter_config.abi3,
    };
    const ffi = py.addFfiModule(options);
    const pyconf = py.addPyconf(options);

    // We never build this lib, but we use it to generate docs.
    const pydust_lib = b.addLibrary(.{
        .name = "pydust",
        // .root_source_file = b.path("pydust/src/pydust.zig"),
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = LazyPath{ .cwd_relative = interpreter_config.pydust_root_zig },
            .imports = &.{
                .{ .name = "pyconf", .module = pyconf.createModule() },
                .{ .name = "ffi", .module = ffi },
            },
        }),
        .linkage = .dynamic,
    });

    const pydust_docs = b.addInstallDirectory(.{
        .source_dir = pydust_lib.getEmittedDocs(),
        // Emit the Zig docs into zig-out/../docs/zig
        .install_dir = .{ .custom = "../docs" },
        .install_subdir = "zig",
    });
    docs_step.dependOn(&pydust_docs.step);

    const test_filters = b.option([]const u8, "test-filter", "Skip tests that do not match any filter");
    const main_tests = b.addTest(.{
        .root_source_file = b.path("pydust/src/pydust.zig"),
        .target = target,
        .optimize = optimize,
        .filter = test_filters,
    });
    main_tests.linkLibC();
    main_tests.linkSystemLibrary(interpreter_config.libname.str());
    main_tests.addIncludePath(LazyPath{ .cwd_relative = interpreter_config.include_dir });
    main_tests.addLibraryPath(LazyPath{ .cwd_relative = interpreter_config.libdir.? });
    main_tests.addRPath(LazyPath{ .cwd_relative = interpreter_config.libdir.? });
    // main_tests.root_module.addImport("ffi", translate_c.createModule());
    main_tests.root_module.addImport("ffi", ffi);
    main_tests.root_module.addImport("pyconf", pyconf.createModule());

    check_step.dependOn(&main_tests.step);

    const run_main_tests = b.addRunArtifact(main_tests);
    test_step.dependOn(&run_main_tests.step);

    // Setup a library target to trick the Zig Language Server into providing completions for @import("pydust")
    const example_lib = b.addLibrary(.{
        .name = "example",
        // .root_source_file = b.path("example/hello.zig"),
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("pydust/src/pydust.zig"),
            .imports = &.{
                .{ .name = "pyconf", .module = pyconf.createModule() },
                .{ .name = "ffi", .module = ffi },
            },
        }),
        .linkage = .dynamic,
    });
    example_lib.linkLibC();
    example_lib.addIncludePath(LazyPath{ .cwd_relative = interpreter_config.include_dir });
    example_lib.linkSystemLibrary(interpreter_config.libname.str());
    example_lib.addRPath(LazyPath{ .cwd_relative = interpreter_config.libdir.? });

    const example_lib_mod = b.createModule(.{ .root_source_file = b.path("pydust/src/pydust.zig") });
    example_lib_mod.addIncludePath(LazyPath{ .cwd_relative = interpreter_config.include_dir });
    // example_lib.root_module.addImport("ffi", translate_c.createModule());
    example_lib.root_module.addImport("ffi", ffi);
    example_lib.root_module.addImport("pydust", example_lib_mod);
    example_lib.root_module.addImport("pyconf", pyconf.createModule());

    // Option for emitting test binary based on the given root source.
    // This is used for debugging as in .vscode/tasks.json
    const test_debug_root = b.option([]const u8, "test-debug-root", "The root path of a file emitted as a binary for use with the debugger");
    if (test_debug_root) |root| {
        main_tests.root_module.root_source_file = LazyPath{ .cwd_relative = root };
        const test_bin_install = b.addInstallBinFile(main_tests.getEmittedBin(), "test.bin");
        b.getInstallStep().dependOn(&test_bin_install.step);
    }
}

pub const PydustStep = struct {
    pub const Options = struct {
        test_step: ?*Step = null,
    };

    pub const PyModuleOptions = struct {
        name: [:0]const u8,
        // root_source_file: LazyPath,
        root_module: *std.Build.Module,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.Mode,
        main_pkg_path: ?LazyPath = null,

        abi3: bool = false,

        pub fn short_name(self: *const PyModuleOptions) [:0]const u8 {
            if (std.mem.lastIndexOfScalar(u8, self.name, '.')) |short_name_idx| {
                return self.name[short_name_idx + 1 .. :0];
            }
            return self.name;
        }
    };

    pub const PyModule = struct {
        root_module: *std.Build.Module,
        library: *Step.Compile,
        test_step: *Step.Compile,
    };

    owner: *std.Build,
    allocator: std.mem.Allocator,
    options: Options,

    test_build_step: *Step,
    generate_stubs: *Step,

    check_stubs: bool,

    interpreter_config: InterpreterConfig,

    pub fn deinit(self: *PydustStep) void {
        self.interpreter_config.deinit();
        self.allocator.destroy(self);
    }

    pub fn add(b: *std.Build, options: Options) *PydustStep {
        const self = b.allocator.create(PydustStep) catch @panic("Out of memory");

        const check_step = b.step("check-pydust", "Check Pydust build");
        const generate_stubs = b.step("generate-stubs", "Generate Pydust stubs");

        const check_stubs = b.option(bool, "check-stubs", "Check Pydust stubs") orelse false;
        const python_exe = b.option([]const u8, "python-exe", "Python executable to use") orelse "python3";
        const abi3 = b.option(bool, "abi3", "Enable limited api / abi3") orelse false;

        const interpreter_config = InterpreterConfig.fromInterpreter(
            b.allocator,
            python_exe,
            abi3,
        ) catch @panic("Failed to get interpreter config");

        self.* = .{
            .owner = b,
            .allocator = b.allocator,
            .options = options,
            .test_build_step = check_step,
            .generate_stubs = generate_stubs,
            .check_stubs = check_stubs,
            .interpreter_config = interpreter_config,
        };

        return self;
    }

    fn addPyconf(self: *PydustStep, options: PyModuleOptions) *std.Build.Step.Options {
        const b = self.owner;
        const pyconf = b.addOptions();
        pyconf.addOption([:0]const u8, "module_name", options.name);
        pyconf.addOption(bool, "limited_api", options.abi3);
        pyconf.addOption([]const u8, "hexversion", self.interpreter_config.hexversion);
        pyconf.addOption(InterpreterConfig.Version, "runtime_version", self.interpreter_config.version);
        return pyconf;
    }

    pub fn addPythonModule(self: *PydustStep, options: PyModuleOptions) PyModule {
        const b = self.owner;

        const short_name = options.short_name();

        const pyconf = self.addPyconf(options);
        const ffi = self.addFfiModule(options);

        const pydust = b.createModule(.{
            .root_source_file = LazyPath{ .cwd_relative = self.interpreter_config.pydust_root_zig },
            .imports = &.{
                .{ .name = "pyconf", .module = pyconf.createModule() },
                .{ .name = "ffi", .module = ffi },
            },
        });
        pydust.addIncludePath(LazyPath{ .cwd_relative = self.interpreter_config.include_dir });

        options.root_module.addImport("pyconf", pyconf.createModule());
        options.root_module.addImport("pydust", pydust);

        const library = b.addLibrary(.{
            .name = short_name,
            .root_module = options.root_module,
            .linkage = .dynamic,
        });
        library.linkLibC();
        library.linker_allow_shlib_undefined = true;

        const install = b.addInstallFileWithDir(
            library.getEmittedBin(),
            .{ .custom = ".." }, // Project root, zig-out/../
            self.pyModuleDestRelPath(b.allocator, options) catch @panic("Out of memory"),
        );
        b.getInstallStep().dependOn(&install.step);

        // Test step
        const libtest_mod = b.createModule(.{
            .root_source_file = LazyPath{ .cwd_relative = self.interpreter_config.pydust_root_zig },
            .imports = &.{
                .{ .name = "pyconf", .module = pyconf.createModule() },
                .{ .name = "ffi", .module = ffi },
            },
        });
        libtest_mod.addIncludePath(LazyPath{ .cwd_relative = self.interpreter_config.include_dir });

        const libtest = b.addTest(.{ .root_module = options.root_module });
        libtest.linkLibC();
        libtest.linkSystemLibrary(self.interpreter_config.libname.str());
        libtest.addLibraryPath(LazyPath{ .cwd_relative = self.interpreter_config.libdir.? });
        libtest.addRPath(LazyPath{ .cwd_relative = self.interpreter_config.libdir.? }); // Anaconda compat

        const install_libtest = b.addInstallBinFile(
            libtest.getEmittedBin(),
            libtestDestRelPath(b.allocator, options) catch @panic("Out of memory"),
        );
        self.test_build_step.dependOn(&install_libtest.step);

        if (self.options.test_step) |test_step| {
            const run_test = b.addRunArtifact(libtest);
            test_step.dependOn(&run_test.step);
        }

        return .{
            .root_module = options.root_module,
            .library = library,
            .test_step = libtest,
        };
    }

    fn addFfiModule(self: PydustStep, options: PyModuleOptions) *std.Build.Module {
        const b = self.owner;

        // const translate_c = b.addTranslateC(.{
        //     .root_source_file = LazyPath{ .cwd_relative = self.interpreter_config.pydust_ffi_h },
        //     .target = options.target,
        //     .optimize = options.optimize,
        // });
        // if (options.abi3)
        //     translate_c.defineCMacro("Py_LIMITED_API", self.interpreter_config.hexversion);
        // translate_c.addIncludePath(LazyPath{ .cwd_relative = self.interpreter_config.include_dir });

        // return translate_c.createModule();

        const translate_c_dep = b.dependency("translate_c", .{});
        var wf: LazyPath = undefined;
        if (options.abi3) {
            wf = b.addWriteFiles().add("ffi.h", std.mem.concat(b.allocator, u8, &.{
                \\#define PY_SSIZE_T_CLEAN
                \\#include <Python.h>
                \\#include <structmember.h>
                \\#define Py_LIMITED_API 
                ,
                self.interpreter_config.hexversion,
                "\n",
            }) catch @panic("Out of memory"));
        } else {
            wf = b.addWriteFiles().add("ffi.h",
                \\#define PY_SSIZE_T_CLEAN
                \\#include <Python.h>
                \\#include <structmember.h>
            );
        }

        const t: Translator = .init(translate_c_dep, .{
            .c_source_file = wf,
            .target = options.target,
            .optimize = options.optimize,
        });
        t.addIncludePath(LazyPath{ .cwd_relative = self.interpreter_config.include_dir });
        return t.mod;
    }

    fn pyModuleDestRelPath(self: PydustStep, allocator: std.mem.Allocator, options: PyModuleOptions) ![]const u8 {
        const name = options.name;
        const suffix = if (options.abi3)
            if (builtin.os.tag == .windows) ".abi3.pyd" else ".abi3.so"
        else if (self.interpreter_config.sysconfigEnv.value.ext_suffix) |ext_suffix|
            ext_suffix
        else {
            @panic("Cannot determine library suffix");
        };

        const destPath = try allocator.alloc(u8, name.len + suffix.len);

        // Take the module name, replace dots for slashes.
        @memcpy(destPath[0..name.len], name);
        std.mem.replaceScalar(u8, destPath[0..name.len], '.', '/');

        // Append the suffix
        @memcpy(destPath[name.len..], suffix);

        return destPath;
    }

    fn libtestDestRelPath(allocator: std.mem.Allocator, options: PyModuleOptions) ![]const u8 {
        return try std.mem.concat(allocator, u8, &.{
            options.name,
            ".test.bin",
        });
    }
};
