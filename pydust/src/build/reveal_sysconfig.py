"""
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""

# Originally from pyo3-build-config

import json
import os.path
import platform
import struct
import sys
from sysconfig import get_config_var, get_path, get_platform

import pydust

PYPY = platform.python_implementation() == "PyPy"
GRAALPY = platform.python_implementation() == "GraalVM"

GRAALPY_MAJOR = None
GRAALPY_MINOR = None

if GRAALPY:
    graalpy_ver = map(int, __graalpython__.get_graalvm_version().split("."))  # type: ignore  # noqa: F821
    GRAALPY_MAJOR = next(graalpy_ver)
    GRAALPY_MINOR = next(graalpy_ver)

# sys.base_prefix is missing on Python versions older than 3.3; this allows the script to continue
# so that the version mismatch can be reported in a nicer way later.
base_prefix = getattr(sys, "base_prefix", None)

if base_prefix:
    # Anaconda based python distributions have a static python executable, but include
    # the shared library. Use the shared library for embedding to avoid rust trying to
    # LTO the static library (and failing with newer gcc's, because it is old).
    ANACONDA = os.path.exists(os.path.join(base_prefix, "conda-meta"))
else:
    ANACONDA = False

# Windows always uses shared linking
WINDOWS = platform.system() == "Windows"

LIBDIR = get_config_var("LIBDIR")


def safe_relpath(path):
    """Safely compute relative path, handling Windows cross-drive issues."""
    if path is None:
        return None

    try:
        return os.path.relpath(path)
    except ValueError:
        # On Windows, this can happen when paths are on different drives
        # Return the absolute path and a flag indicating it needs special handling
        return path


if LIBDIR is not None:
    LIBDIR = safe_relpath(get_config_var("LIBDIR"))

# macOS framework packages use shared linking
FRAMEWORK = bool(get_config_var("PYTHONFRAMEWORK"))
FRAMEWORK_PREFIX = get_config_var("PYTHONFRAMEWORKPREFIX")

# unix-style shared library enabled
SHARED = bool(get_config_var("Py_ENABLE_SHARED"))

# Include directory for <Python.h>
INCLUDE_DIR = get_path("include")
include_dir_relpath = safe_relpath(INCLUDE_DIR)

# Pydust python module location
pydust_module_path = os.path.dirname(pydust.__file__)

# Pydust root.zig
pydust_root_zig_path = os.path.join(pydust_module_path, "src", "pydust.zig")
pydust_root_zig = safe_relpath(pydust_root_zig_path)

# Pydust ffi.h
pydust_ffi_h_path = os.path.join(pydust_module_path, "src", "ffi.h")
pydust_ffi_h = safe_relpath(pydust_ffi_h_path)

# GIL_DISABLED = get_config_var("Py_GIL_DISABLED") == 1 if get_config_var("Py_GIL_DISABLED") is not None else False
GIL_DISABLED_DEF = get_config_var("Py_GIL_DISABLED")
if GIL_DISABLED_DEF == 1:
    GIL_DISABLED = True
elif GIL_DISABLED_DEF == 0:
    GIL_DISABLED = False
elif GIL_DISABLED_DEF is None:
    # If Py_GIL_DISABLED is not defined, assume GIL is enabled
    GIL_DISABLED = False
else:
    print(f"Error: Py_GIL_DISABLED is not a valid value (expected 0 or 1), got {GIL_DISABLED_DEF}", file=sys.stderr)
    sys.exit(-1)

print(
    json.dumps(
        {
            "implementation": platform.python_implementation(),
            "version_major": sys.version_info[0],
            "version_minor": sys.version_info[1],
            "hexversion": f"{sys.hexversion:#010x}",
            "graalpy_major": GRAALPY_MAJOR,
            "graalpy_minor": GRAALPY_MINOR,
            "shared": PYPY or GRAALPY or ANACONDA or WINDOWS or FRAMEWORK or SHARED,
            "python_framework_prefix": FRAMEWORK_PREFIX,
            "ld_version": get_config_var("LDVERSION"),
            "libdir": LIBDIR,
            "include_dir": include_dir_relpath,
            "pydust_root_zig": pydust_root_zig,
            "pydust_ffi_h": pydust_ffi_h,
            "base_prefix": base_prefix,
            "executable": sys.executable,
            "calcsize_pointer": struct.calcsize("P"),
            "mingw": get_platform().startswith("mingw"),
            "ext_suffix": get_config_var("EXT_SUFFIX"),
            "gil_disabled": GIL_DISABLED,
        }
    ),
    end="",
)
