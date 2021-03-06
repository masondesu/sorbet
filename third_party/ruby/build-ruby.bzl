load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "C_COMPILE_ACTION_NAME")
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")

_HERMETIC_TAR = """
# If we have gtar installed (darwin), use that instead
if hash gtar 2>/dev/null; then
    alias tar=gtar
fi
hermetic_tar() {
    SRC="$1"
    OUT="$2"
    FLAGS="${3:-}"
    # Check if our tar supports --sort (we assume --sort support implies --mtime support)
    if [[ $(tar --sort 2>&1) =~ 'requires an argument' ]]; then
        tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='UTC 1970-01-01 00:00' -h -C "$SRC" $FLAGS -rf "$OUT" .
    elif [[ $(tar --mtime 2>&1) =~ 'requires an argument' ]]; then
        (cd "$SRC" && find . -print0) | LC_ALL=C sort -z | tar -h -C "$SRC" --no-recursion --null -T - --owner=0 --group=0 --numeric-owner --mtime='UTC 1970-01-01 00:00' $FLAGS -rf "$OUT" .
    else
        # Oh well, no hermetic tar for you
        tar -h -C "$SRC" $FLAGS -rf "$OUT" .
    fi
}
"""

_RUNFILES_BASH = """
# --- begin runfiles.bash initialization v2 ---
# Copy-pasted from the Bazel Bash runfiles library v2.
set -uo pipefail; f=bazel_tools/tools/bash/runfiles/runfiles.bash
source "${RUNFILES_DIR:-/dev/null}/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "${RUNFILES_MANIFEST_FILE:-/dev/null}" | cut -f2- -d' ')" 2>/dev/null || \
  source "$0.runfiles/$f" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  source "$(grep -sm1 "^$f " "$0.exe.runfiles_manifest" | cut -f2- -d' ')" 2>/dev/null || \
  { echo>&2 "ERROR: cannot find $f"; exit 1; }; f=; set -e
# --- end runfiles.bash initialization v2 ---
"""

_BUILD_RUBY = """#!/bin/bash

set -euo pipefail

base="$PWD"
out_dir="$base/{toolchain}"

declare -a inc_path=()
for path in {hdrs}; do
  inc_path=("${{inc_path[@]:-}}" "-isystem" "$base/$path")
done

declare -a lib_path=()
for path in {libs}; do
  lib_path=("${{lib_path[@]:-}}" "-L$base/$path")
done

build_dir="$(mktemp -d)"

# Add the compiler's directory the PATH, as this fixes builds with gcc
export PATH="$(dirname "{cc}"):$PATH"

# Copy everything to a separate directory to get rid of symlinks:
# tool/rbinstall.rb will explicitly ignore symlinks when installing files,
# and this feels more maintainable than patching it.
cp -aL "{src_dir}"/* "$build_dir"

pushd "$build_dir" > /dev/null

run_cmd() {{
    if ! "$@" >> build.log 2>&1; then
        echo "command $@ failed!"
        cat build.log
        echo "build dir: $build_dir"
        exit 1
    fi
}}

run_cmd ./configure \
        CC="{cc}" \
        CFLAGS="${{inc_path[*]}} {copts}" \
        CPPFLAGS="${{inc_path[*]}} {copts}" \
        LDFLAGS="${{lib_path[*]}} {linkopts}" \
        OUTFLAG="-fvisibility=default -o" \
        --enable-load-relative \
        --with-destdir="$out_dir" \
        --with-rubyhdrdir='${{includedir}}' \
        --with-rubyarchhdrdir='${{includedir}}/ruby-arch' \
        --disable-install-doc \
        --prefix=/

run_cmd make V=1 -j8
run_cmd make V=1 install

internal_incdir="$base/{internal_incdir}"

mkdir -p "$internal_incdir"

cp *.h "$internal_incdir"

find ccan -type d | while read dir; do
  mkdir -p "$internal_incdir/$dir"
done

find ccan -type f -name \*.h | while read file; do
  cp $file "$internal_incdir/$file"
done

# install bundler
cp "$base/{bundler}" bundler.gem

# --local to avoid going to rubygmes for the gem
# --env-shebang to not hardcode the path to ruby in the sandbox
# --force because bundler is packaged with ruby starting with 2.6
run_cmd "$out_dir/bin/gem" install --local --env-shebang --force bundler.gem

popd > /dev/null

rm -rf "$build_dir"

"""

RubyInfo = provider()

def _is_sanitizer_flag(flag):
    return flag.startswith("-fsanitize") or \
           flag.startswith("-fno-sanitize") or \
           flag == "-DHAS_SANITIZER" or \
           flag == "-DADDRESS_SANITIZER" or \
           flag.endswith("asan_cxx-x86_64.a") or \
           flag.endswith("ubsan_standalone_cxx-x86_64.a") or \
           flag.endswith("ubsan_standalone-x86_64.a")

def _build_ruby_impl(ctx):
    src_dir = ctx.label.workspace_root

    # Setup toolchains
    cc_toolchain = find_cpp_toolchain(ctx)

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    cc = cc_common.get_tool_for_action(
        feature_configuration = feature_configuration,
        action_name = C_COMPILE_ACTION_NAME,
    )

    cmdline = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = C_COMPILE_ACTION_NAME,
        variables = cc_common.create_compile_variables(
            cc_toolchain = cc_toolchain,
            feature_configuration = feature_configuration,
        ),
    )

    # -Werror breaks configure, so we strip out all flags with a leading -W
    # ruby doesn't work with asan or ubsan
    flags = []
    for flag in ctx.fragments.cpp.copts + ctx.fragments.cpp.conlyopts:
        if flag.startswith("-W") or \
           flag == "-DHAS_SANITIZER" or \
           flag == "-DADDRESS_SANITIZER" or \
           _is_sanitizer_flag(flag):
            continue

        flags.append(flag)

    ldflags = []
    for flag in ctx.fragments.cpp.linkopts:
        if _is_sanitizer_flag(flag):
            continue

        ldflags.append(flag)

    # process deps into include and linker paths
    hdrs = {}
    libs = {}
    deps = {}

    for dep in ctx.attr.deps:
        cc_info = dep[CcInfo]
        if None == cc_info:
            fail("Dependency {} is missing a CcInfo".format(dep))

        for hdr in cc_info.compilation_context.headers.to_list():
            deps[hdr] = True

        for path in cc_info.compilation_context.system_includes.to_list():
            hdrs[path] = True

        for lib in cc_info.linking_context.libraries_to_link.to_list():
            libs[lib.dynamic_library.dirname] = True
            deps[lib.dynamic_library] = True

    hdrs = hdrs.keys()
    libs = libs.keys()
    deps = deps.keys()

    # Outputs
    binaries = [
        ctx.actions.declare_file("toolchain/bin/{}".format(binary))
        for binary in ["ruby", "erb", "gem", "irb", "rdoc", "ri", "bundle", "bundler"]
    ]

    libdir = ctx.actions.declare_directory("toolchain/lib")
    incdir = ctx.actions.declare_directory("toolchain/include")
    sharedir = ctx.actions.declare_directory("toolchain/share")

    internal_incdir = ctx.actions.declare_directory("toolchain/internal_include")

    outputs = binaries + [libdir, incdir, sharedir, internal_incdir]

    # Build
    ctx.actions.run_shell(
        mnemonic = "BuildRuby",
        inputs = deps + ctx.files.src + ctx.files.bundler,
        outputs = outputs,
        command = ctx.expand_location(_BUILD_RUBY.format(
            cc = cc,
            copts = " ".join(cmdline + flags + ctx.attr.copts),
            linkopts = " ".join(ldflags + ctx.attr.linkopts),
            toolchain = libdir.dirname,
            src_dir = src_dir,
            internal_incdir = internal_incdir.path,
            hdrs = " ".join(hdrs),
            libs = " ".join(libs),
            bundler = ctx.files.bundler[0].path,
        )),
    )

    return [
        RubyInfo(
            toolchain = libdir.dirname,
            binaries = binaries,
            includes = incdir,
            internal_includes = internal_incdir,
            runtime = binaries + [libdir, incdir, sharedir],
        ),
        DefaultInfo(
            files = depset(outputs),
        ),
    ]

build_ruby = rule(
    implementation = _build_ruby_impl,
    attrs = {
        "src": attr.label(),
        "deps": attr.label_list(),
        "bundler": attr.label(
            mandatory = True,
            doc = "The bundler gem to install",
        ),
        "copts": attr.string_list(
            doc = "Additional copts for the ruby build",
        ),
        "linkopts": attr.string_list(
            doc = "Additional linkopts for the ruby build",
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    provides = [RubyInfo, DefaultInfo],
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    fragments = ["cpp"],
)

_BUILD_ARCHIVE = """#!/bin/bash

{hermetic_tar_setup}

base=$PWD
toolchain="$base/{toolchain}"

hermetic_tar "$toolchain" "{output}"
"""

def _ruby_archive_impl(ctx):
    ruby_info = ctx.attr.ruby[RubyInfo]

    archive = ctx.actions.declare_file("ruby.tar.gz")

    ctx.actions.run_shell(
        outputs = [archive],
        inputs = ruby_info.runtime,
        command = ctx.expand_location(_BUILD_ARCHIVE.format(
            hermetic_tar_setup = _HERMETIC_TAR,
            toolchain = ruby_info.toolchain,
            output = archive.path,
        )),
    )

    archive = ctx.actions.declare_file("ruby.tar.gz")

    return [DefaultInfo(files = depset([archive]))]

ruby_archive = rule(
    implementation = _ruby_archive_impl,
    attrs = {
        "ruby": attr.label(),
    },
    provides = [DefaultInfo],
)

_BINARY_WRAPPER = """#!/bin/bash

{runfiles_setup}

exec "$(rlocation {workspace}/toolchain/bin/{binary})" "$@"
"""

def _ruby_binary_impl(ctx):
    ruby_info = ctx.attr.ruby[RubyInfo]

    wrapper = ctx.actions.declare_file(ctx.label.name)

    binary = None

    for candidate in ruby_info.binaries:
        if candidate.basename == ctx.label.name:
            binary = candidate
            break

    if binary == None:
        fail("Binary '{}' is missing from the ruby build".format(ctx.label.name))

    ctx.actions.write(
        output = wrapper,
        content = _BINARY_WRAPPER.format(
            runfiles_setup = _RUNFILES_BASH,
            workspace = ctx.label.workspace_name,
            binary = ctx.label.name,
        ),
        is_executable = True,
    )

    runfiles_bash = ctx.attr._runfiles_bash[DefaultInfo].files

    runfiles = ctx.runfiles(files = runfiles_bash.to_list() + ruby_info.runtime)

    return [DefaultInfo(executable = wrapper, runfiles = runfiles)]

ruby_binary = rule(
    implementation = _ruby_binary_impl,
    attrs = {
        "ruby": attr.label(),
        "_runfiles_bash": attr.label(
            default = Label("@bazel_tools//tools/bash/runfiles"),
        ),
    },
    provides = [DefaultInfo],
    executable = True,
)

def _uses_headers(ctx, paths, headers):
    ruby_info = ctx.attr.ruby[RubyInfo]

    cc_toolchain = find_cpp_toolchain(ctx)

    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    compilation_context = cc_common.create_compilation_context(
        includes = depset(paths),
        headers = headers,
    )

    return [
        DefaultInfo(files = headers),
        CcInfo(compilation_context = compilation_context),
    ]

def _ruby_headers_impl(ctx):
    ruby_info = ctx.attr.ruby[RubyInfo]

    paths = [
        ruby_info.includes.path,
        "{}/ruby-arch".format(ruby_info.includes.path),
    ]

    headers = depset([ruby_info.includes])

    return _uses_headers(ctx, paths, headers)

ruby_headers = rule(
    implementation = _ruby_headers_impl,
    attrs = {
        "ruby": attr.label(),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    provides = [DefaultInfo, CcInfo],
    fragments = ["cpp"],
)

def _ruby_internal_headers_impl(ctx):
    ruby_info = ctx.attr.ruby[RubyInfo]

    paths = [ruby_info.internal_includes.path]

    headers = depset([ruby_info.internal_includes])

    return _uses_headers(ctx, paths, headers)

ruby_internal_headers = rule(
    implementation = _ruby_internal_headers_impl,
    attrs = {
        "ruby": attr.label(),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    provides = [DefaultInfo, CcInfo],
    fragments = ["cpp"],
)
