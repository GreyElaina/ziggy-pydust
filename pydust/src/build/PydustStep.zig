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

const builtins = @import("builtin");
const std = @import("std");

const Step = std.Build.Step;
const LazyPath = std.Build.LazyPath;
const GeneratedFile = std.Build.GeneratedFile;

const InterpreterConfig = @import("InterpreterConfig.zig");

const Self = @This();

pub const Options = struct {
    test_step: ?*Step = null,
};

pub const PyModuleOptions = struct {
    name: [:0]const u8,
    root_source_file: LazyPath,
    target: std.Target.Query,
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
    library_step: *Step.Compile,
    test_step: *Step.Compile,
};

owner: *std.Build,
allocator: std.mem.Allocator,
options: Options,

test_build_step: *Step,
generate_stubs: *Step,

check_stubs: bool,

interpreter_config: InterpreterConfig,

pub fn deinit(self: *Self) void {
    self.interpreter_config.deinit();
    self.allocator.destroy(self);
}

pub fn add(b: *std.Build, options: Options) *Self {
    const self = b.allocator.create(Self) catch @panic("Out of memory");

    const check_step = b.step("check", "Check Pydust build");
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

pub fn addPythonModule(self: *Self, options: PyModuleOptions) PyModule {
    const b = self.owner;

    const short_name = options.short_name();

    const pyconf = b.addOptions();
    pyconf.addOption([:0]const u8, "module_name", options.name);
    pyconf.addOption(bool, "limited_api", options.abi3);
    pyconf.addOption([]const u8, "hexversion", self.interpreter_config.hexversion);

    const translate_c = self.addTranslateC(options);
    translate_c.addIncludePath(LazyPath { .cwd_relative = self.interpreter_config.include_dir });

    const pydust = b.createModule(.{
        .root_source_file = LazyPath { .cwd_relative = self.interpreter_config.pydust_root_zig },
        .imports = &.{
            .{ .name = "pyconf", .module = pyconf.createModule() },
            .{ .name = "ffi", .module = translate_c.createModule() },
        },
    });
    pydust.addIncludePath(LazyPath { .cwd_relative = self.interpreter_config.include_dir });

    const py_module = b.addSharedLibrary(.{
        .name = short_name,
        .root_source_file = options.root_source_file,
        .target = b.resolveTargetQuery(options.target),
        .optimize = options.optimize,
    });
    py_module.root_module.addOptions("pyconf", pyconf);
    py_module.root_module.addImport("pydust", pydust);
    py_module.linkLibC();
    py_module.linker_allow_shlib_undefined = true;

    const install = b.addInstallFileWithDir(
        py_module.getEmittedBin(),
        .{ .custom = ".." }, // Project root, zig-out/../
        self.pyModuleDestRelPath(b.allocator, options) catch @panic("Out of memory"),
    );
    b.getInstallStep().dependOn(&install.step);

    // Test step
    const libtest_mod = b.createModule(.{
        .root_source_file = LazyPath { .cwd_relative = self.interpreter_config.pydust_root_zig },
        .imports = &.{
            .{ .name = "pyconf", .module = pyconf.createModule() },
            .{ .name = "ffi", .module = translate_c.createModule() },
        },
    });
    libtest_mod.addIncludePath(LazyPath { .cwd_relative = self.interpreter_config.include_dir });
    
    const libtest = b.addTest(.{
        .root_source_file = options.root_source_file,
        .target = b.resolveTargetQuery(options.target),
        .optimize = options.optimize,
    });
    libtest.root_module.addOptions("pyconf", pyconf);
    libtest.root_module.addImport("pydust", libtest_mod);
    libtest.linkLibC();
    libtest.linkSystemLibrary(self.interpreter_config.libname.str());
    libtest.addLibraryPath(LazyPath { .cwd_relative = self.interpreter_config.libdir.? });
    libtest.addRPath(LazyPath { .cwd_relative = self.interpreter_config.libdir.? }); // Anaconda compat

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
        .library_step = py_module,
        .test_step = libtest,
    };
}

fn addTranslateC(self: Self, options: PyModuleOptions) *std.Build.Step.TranslateC {
    const b = self.owner;
    const translate_c = b.addTranslateC(.{
        .root_source_file = LazyPath { .cwd_relative = self.interpreter_config.pydust_ffi_h },
        .target = b.resolveTargetQuery(options.target),
        .optimize = options.optimize,
    });
    if (options.abi3)
        translate_c.defineCMacro("Py_LIMITED_API", self.interpreter_config.hexversion);
    return translate_c;
}

fn pyModuleDestRelPath(self: Self, allocator: std.mem.Allocator, options: PyModuleOptions) ![]const u8 {
    const name = options.name;
    const suffix = if (options.abi3)
        if (builtins.os.tag == .windows) ".abi3.pyd" else ".abi3.so"
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
    return try std.mem.concat(allocator, u8, &[_][]const u8{
        options.name,
        ".test.bin",
    });
}
