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

//! Configuration required for specified interpreter instance

const std = @import("std");
const builtin = @import("builtin");

const Self = @This();

allocator: std.mem.Allocator,

implementation: Implementation,
version: Version,
shared: bool,
abi3: bool,

python_exe: []const u8,
hexversion: []const u8,
framework_prefix: ?[]const u8,
libname: PyLibName,
libdir: ?[]const u8,
include_dir: []const u8,

pydust_root_zig: []const u8,
pydust_ffi_h: []const u8,

sysconfigEnv: std.json.Parsed(SysconfigEnv),

pub const Implementation = enum {
    CPython,
    PyPy,
    GraalPy,

    pub fn parse(s: []const u8) !Implementation {
        if (std.mem.eql(u8, s, "CPython")) {
            return Implementation.CPython;
        } else if (std.mem.eql(u8, s, "PyPy")) {
            return Implementation.PyPy;
        } else if (std.mem.eql(u8, s, "GraalVM")) {
            return Implementation.GraalPy;
        } else {
            return error.InvalidInterpreterImplementation;
        }
    }
};

pub const Version = struct {
    major: u8,
    minor: u8,

    const PY37 = Version{ .major = 3, .minor = 7 };
    const PY313 = Version{ .major = 3, .minor = 13 };
    const PY310 = Version{ .major = 3, .minor = 10 };

    const MINIMUM_SUPPORTED_VERSION_GRAALPY = Version{
        .major = 24,
        .minor = 0,
    };
    const MINIMUM_SUPPORTED_VERSION_PYTHON = Version{
        .major = 3,
        .minor = 11,
    };

    pub fn parse(s: []const u8) !Version {
        const parts = std.mem.splitScalar(u8, s, '.');
        if (parts.len != 2) return error.InvalidVersionFormat;

        const major = std.fmt.parseInt(u8, parts[0], 10) catch unreachable;
        const minor = std.fmt.parseInt(u8, parts[1], 10) catch unreachable;

        return Version{ .major = major, .minor = minor };
    }

    pub fn cmp(self: Version, other: Version) i2 {
        if (self.major < other.major) return -1;
        if (self.major > other.major) return 1;
        if (self.minor < other.minor) return -1;
        if (self.minor > other.minor) return 1;
        return 0;
    }

    pub fn isSupportedPython(self: Version) bool {
        return self.cmp(MINIMUM_SUPPORTED_VERSION_PYTHON) >= 0;
    }

    pub fn isSupportedGraalPy(self: Version) bool {
        return self.cmp(MINIMUM_SUPPORTED_VERSION_GRAALPY) >= 0;
    }
};

const sysconfigRevealScript = @embedFile("reveal_sysconfig.py");

const SysconfigEnv = struct {
    implementation: []const u8,
    version_major: u8,
    version_minor: u8,
    hexversion: []const u8,
    graalpy_major: ?u8,
    graalpy_minor: ?u8,
    shared: bool,
    python_framework_prefix: ?[]const u8,
    ld_version: ?[]const u8,
    libdir: ?[]const u8,
    base_prefix: ?[]const u8,
    executable: []const u8,
    calcsize_pointer: u8,
    mingw: bool,
    ext_suffix: ?[]const u8,
    gil_disabled: bool,
    include_dir: []const u8,

    /// Relative path to pydust/src/pydust.zig
    pydust_root_zig: []const u8,

    /// Relative path to pydust/src/ffi.h
    pydust_ffi_h: []const u8,
};

pub fn fromInterpreter(
    allocator: std.mem.Allocator,
    python_exe: []const u8,
    abi3: bool,
) !Self {
    const interpreterEnvRun = runPythonScript(allocator, python_exe, sysconfigRevealScript) catch |e| {
        std.debug.print("Failed to run sysconfig reveal script: {s}, using python_exe={s}\n", .{ @errorName(e), python_exe });
        @panic("Failed to run sysconfig reveal script");
    };
    if (interpreterEnvRun.term.Exited != 0) {
        std.debug.print("Sysconfig reveal script failed with exit code {}\n", .{interpreterEnvRun.term.Exited});
        std.debug.print("Stdout: {s}\n", .{interpreterEnvRun.stdout});
        std.debug.print("Stderr: {s}\n", .{interpreterEnvRun.stderr});
        @panic("Sysconfig reveal script returned non-zero exit code");
    }
    allocator.free(interpreterEnvRun.stderr);

    const sysconfigEnvParsed = std.json.parseFromSlice(SysconfigEnv, allocator, interpreterEnvRun.stdout, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        allocator.free(interpreterEnvRun.stdout);
        std.debug.print("Failed to parse sysconfig env: {}\n", .{err});
        @panic("Failed to parse sysconfig env");
    };
    allocator.free(interpreterEnvRun.stdout);

    const sysconfigEnv = sysconfigEnvParsed.value;
    if (sysconfigEnv.graalpy_major) |graalpy_major| {
        const graalpy_minor = sysconfigEnv.graalpy_minor orelse unreachable;
        const graalpy_version = Version{
            .major = graalpy_major,
            .minor = graalpy_minor,
        };
        if (!graalpy_version.isSupportedGraalPy()) {
            std.debug.print("Unsupported GraalPy version: {}.{}. Minimum supported version is {}.{}\n", .{ graalpy_major, graalpy_minor, Version.MINIMUM_SUPPORTED_VERSION_GRAALPY.major, Version.MINIMUM_SUPPORTED_VERSION_GRAALPY.minor });
            @panic("Unsupported GraalPy version");
        }
    }

    const python_version = Version{
        .major = sysconfigEnv.version_major,
        .minor = sysconfigEnv.version_minor,
    };
    const implementation = try Implementation.parse(sysconfigEnv.implementation);

    if (!python_version.isSupportedPython()) {
        std.debug.print("Unsupported Python version: {}.{}. Minimum supported version is {}.{}\n", .{ sysconfigEnv.version_major, sysconfigEnv.version_minor, Version.MINIMUM_SUPPORTED_VERSION_PYTHON.major, Version.MINIMUM_SUPPORTED_VERSION_PYTHON.minor });
        @panic("Unsupported Python version");
    }

    const libname = if (builtin.os.tag == .windows) try PyLibName.getWindows(
        allocator,
        python_version,
        implementation,
        abi3,
        sysconfigEnv.mingw,
        if (sysconfigEnv.ext_suffix) |ext_suffix| std.mem.startsWith(u8, ext_suffix, "_d.") else false,
        sysconfigEnv.gil_disabled,
    ) else if (builtin.os.tag == .linux or builtin.os.tag == .macos)
        try PyLibName.getUnix(
            allocator,
            python_version,
            implementation,
            sysconfigEnv.ld_version,
            sysconfigEnv.gil_disabled,
        )
    else
        @panic("Unsupported OS for Python interpreter configuration");

    const libdir = if (builtin.os.tag == .windows) blk: {
        if (sysconfigEnv.base_prefix) |base_prefix| {
            const name = std.mem.concat(allocator, u8, &.{ base_prefix, "\\libs" }) catch @panic("OOM");
            break :blk name;
        } else {
            break :blk null;
        }
    } else if (builtin.os.tag == .linux or builtin.os.tag == .macos) blk: {
        break :blk sysconfigEnv.libdir;
    } else @panic("Unsupported OS for Python interpreter configuration");

    // const calcsize_pointer = sysconfigEnv.calcsize_pointer;

    return .{
        .allocator = allocator,
        .implementation = implementation,
        .version = python_version,
        .shared = sysconfigEnv.shared,
        .abi3 = abi3,
        .python_exe = python_exe,
        .libname = libname,
        .libdir = libdir,
        .include_dir = sysconfigEnv.include_dir,
        .pydust_root_zig = sysconfigEnv.pydust_root_zig,
        .pydust_ffi_h = sysconfigEnv.pydust_ffi_h,
        .hexversion = sysconfigEnv.hexversion,
        // .calcsize_pointer = calcsize_pointer,
        .framework_prefix = sysconfigEnv.python_framework_prefix,
        .sysconfigEnv = sysconfigEnvParsed,
    };
}

pub fn deinit(self: Self) void {
    self.libname.deinit(self.allocator);
    self.sysconfigEnv.deinit();
}

const runProcess = if (builtin.zig_version.minor >= 12) std.process.Child.run else std.process.Child.exec;

fn runPythonScript(allocator: std.mem.Allocator, python_exe: []const u8, code: []const u8) !std.process.Child.RunResult {
    return try runProcess(.{
        .allocator = allocator,
        .argv = &.{ python_exe, "-c", code },
    });
}

const WINDOWS_ABI3_LIB_NAME = "python3";
const WINDOWS_ABI3_DEBUG_LIB_NAME = "python3_d";

/// Represents a library name that can be either static or dynamically allocated
pub const PyLibName = union(enum) {
    static: []const u8,
    dynamic: []const u8,

    /// Get the string value regardless of whether it's static or dynamic
    pub fn str(self: PyLibName) []const u8 {
        return switch (self) {
            .static => |s| s,
            .dynamic => |s| s,
        };
    }

    /// Create a LibName from a static string
    pub fn fromStatic(s: []const u8) PyLibName {
        return PyLibName{ .static = s };
    }

    /// Create a LibName from a dynamically allocated string
    pub fn fromDynamic(s: []const u8) PyLibName {
        return PyLibName{ .dynamic = s };
    }

    pub fn deinit(self: PyLibName, allocator: std.mem.Allocator) void {
        switch (self) {
            .static => {},
            .dynamic => |s| allocator.free(s),
        }
    }

    pub fn getWindows(
        allocator: std.mem.Allocator,
        version: Version,
        implementation: Implementation,
        abi3: bool,
        mingw: bool,
        debug: bool,
        gil_disabled: bool,
    ) !PyLibName {
        return getLibnameWindows(allocator, version, implementation, abi3, mingw, debug, gil_disabled);
    }

    pub fn getUnix(
        allocator: std.mem.Allocator,
        version: Version,
        implementation: Implementation,
        ld_version: ?[]const u8,
        gil_disabled: bool,
    ) !PyLibName {
        return getLibnameUnix(allocator, version, implementation, ld_version, gil_disabled);
    }
};

fn getLibnameWindows(
    allocator: std.mem.Allocator,
    version: Version,
    implementation: Implementation,
    abi3: bool,
    mingw: bool,
    debug: bool,
    gil_disabled: bool,
) !PyLibName {
    if (debug and version.cmp(Version.PY310) < 0) {
        // CPython bug: linking against python3_d.dll raises error
        // https://github.com/python/cpython/issues/101614
        // return "python" ++ version.major ++ version.minor ++ "_d";  // => python{}{}_d
        const name = try std.fmt.allocPrint(
            allocator,
            "python{d}{d}_d",
            .{ version.major, version.minor },
        );
        return PyLibName.fromDynamic(name);
    }

    if (abi3 and (!gil_disabled and implementation != .PyPy and implementation != .GraalPy)) {
        return if (debug) PyLibName.fromStatic(WINDOWS_ABI3_DEBUG_LIB_NAME) else PyLibName.fromStatic(WINDOWS_ABI3_LIB_NAME);
    }

    if (mingw) {
        if (!gil_disabled) @panic("MinGW does not support GIL disabled builds");
        // return "python" ++ version.major ++ "." ++ version.minor;  // => python{}.{}
        const name = try std.fmt.allocPrint(
            allocator,
            "python{d}.{d}",
            .{ version.major, version.minor },
        );
        return PyLibName.fromDynamic(name);
    }
    if (gil_disabled) {
        if (version.cmp(Version.PY313) < 0) @panic("Cannot compile C extensions for the free-threaded build on Python versions earlier than 3.13");
        const name = if (debug)
            try std.fmt.allocPrint(
                allocator,
                "python{d}{d}t_d",
                .{ version.major, version.minor },
            )
        else
            try std.fmt.allocPrint(
                allocator,
                "python{d}{d}t",
                .{ version.major, version.minor },
            );
        return PyLibName.fromDynamic(name);
    }
    const name = if (debug)
        try std.fmt.allocPrint(
            allocator,
            "python{d}{d}_d",
            .{ version.major, version.minor },
        )
    else
        try std.fmt.allocPrint(
            allocator,
            "python{d}{d}",
            .{ version.major, version.minor },
        );
    return PyLibName.fromDynamic(name);
}

fn getLibnameUnix(
    allocator: std.mem.Allocator,
    version: Version,
    implementation: Implementation,
    ld_version: ?[]const u8,
    gil_disabled: bool,
) !PyLibName {
    switch (implementation) {
        .CPython => {
            if (ld_version) |ld| {
                const name = try std.mem.concat(allocator, u8, &.{ "python", ld });
                return PyLibName.fromDynamic(name);
            }

            // if (version.isHigherThan(Version.PY37)) {
            if (version.cmp(Version.PY37) > 0) {
                if (gil_disabled) {
                    if (version.cmp(Version.PY313) < 0) @panic("Cannot compile C extensions for the free-threaded build on Python versions earlier than 3.13");
                    const name = try std.fmt.allocPrint(
                        allocator,
                        "python{d}.{d}t",
                        .{ version.major, version.minor },
                    );
                    return PyLibName.fromDynamic(name);
                } else {
                    const name = try std.fmt.allocPrint(
                        allocator,
                        "python{d}.{d}",
                        .{ version.major, version.minor },
                    );
                    return PyLibName.fromDynamic(name);
                }
            } else {
                const name = try std.fmt.allocPrint(
                    allocator,
                    "python{d}.{d}m",
                    .{ version.major, version.minor },
                );
                return PyLibName.fromDynamic(name);
            }
        },
        .PyPy => {
            if (ld_version) |ld| {
                const name = try std.fmt.allocPrint(
                    allocator,
                    "pypy{d}-c",
                    .{ld},
                );
                return PyLibName.fromDynamic(name);
            }
            const name = try std.fmt.allocPrint(
                allocator,
                "pypy{d}.{d}-c",
                .{ version.major, version.minor },
            );
            return PyLibName.fromDynamic(name);
        },
        .GraalPy => {
            return PyLibName.fromStatic("python-native");
        },
    }
}
