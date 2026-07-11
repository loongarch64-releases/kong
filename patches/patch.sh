#!/bin/bash
set -euo pipefail

src="$1"
version="$2"
patches="$3"
major_ver=$(echo "$version" | cut -d. -f1)
minor_ver=$(echo "$version" | cut -d. -f2)
patch_ver=$(echo "$version" | cut -d. -f3)
ver_num=$(( 10#$major_ver * 1000000 + 10#$minor_ver * 1000 + 10#$patch_ver ))

# 源码补丁(多版本通用)
src_universal_adaptation()
{
    ###################################
    # 增加 loongarch platform 和 config
    ###################################
    cat << 'EOF' >> "${src}/BUILD.bazel"
platform(
    name = "generic-loongarch64",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:loongarch64",
        "//build/platforms/distro:generic",
    ],
)

config_setting(
    name = "loongarch64-linux",
    constraint_values = [
        "@platforms//os:linux",
        "@platforms//cpu:loongarch64",
    ],
    visibility = ["//visibility:public"],
)
EOF

    ###################################
    # 使用 loongarch 的 luajit2
    ###################################
    sed -i '/KONG_PACKAGE_NAME/a \
LOONGARCH_LUAJIT2=/tmp/luajit2' "${src}/.requirements"
    sed -i '/lib_source = ":luajit_srcs"/a \
    lib_source = select({ \
        "@kong//:loongarch64-linux": "@loongarch_luajit2//:all_srcs", \
        "//conditions:default": ":luajit_srcs", \
    }),' "${src}/build/openresty/BUILD.openresty.bazel"
    sed -i '/lib_source = ":luajit_srcs"/d' "${src}/build/openresty/BUILD.openresty.bazel"
    sed -i '/openresty_version = KONG_VAR\["OPENRESTY"\]/i \
    maybe( \
        git_or_local_repository, \
        name = "loongarch_luajit2", \
        branch = KONG_VAR["LOONGARCH_LUAJIT2"], \
        remote = "https://github.com/loongson/luajit2", \
        build_file_content = _NGINX_MODULE_DUMMY_FILE, \
    )' "${src}/build/openresty/repositories.bzl"

    ###################################
    # 处理新编译器编译旧源码时的警告升级问题
    ###################################
    sed -i '/name = "libxcrypt"/,/conditions:default": \[/ {/conditions:default": \[/a \
    }) + select({ \
        "@kong//:loongarch64-linux": [ \
            "--disable-werror", \
        ], \
        "//conditions:default": [],
}' "${src}/build/cross_deps/libxcrypt/BUILD.libxcrypt.bazel"

    ###################################
    # 添加 Kong Lua 运行时架构白名单 
    ###################################
    sed -i 's/arch == "arm64"/& or arch == "loongarch64"/' "${src}/kong/pdk/nginx.lua"

    ###################################
    # 允许使用本地 nfpm
    ###################################
    sed -i '/os_arch = ctx.os.arch/a \
    nfpm_bin = ctx.os.environ.get("NFPM_BIN", "") \
    if nfpm_bin: \
        ctx.symlink(ctx.path(nfpm_bin), "nfpm") \
        return' "${src}/build/nfpm/repositories.bzl"
    sed -i '/implementation = _nfpm_release_select_impl/a \
    environ = ["NFPM_BIN"],' "${src}/build/nfpm/repositories.bzl"
    sed -i '/target_arch = "arm64"/a \
    elif target_cpu == "loongarch64" or target_cpu == "loong64": \
        target_arch = "loong64"' "${src}/build/nfpm/rules.bzl"

}

# 源码补丁(不同版本适配)
src_multi_version_adaptation()
{
    if [ "${ver_num}" -lt 3007000 ]; then
	echo "Versions below 3.7.0 are not currently supported or have not been tested"
	exit 1
    fi

    ###################################
    # 剔除 deb 包依赖列表中的 pcre1 包: libpcre3（kong 3.7+ 都用的 pcre2）
    ###################################
    if [ "${ver_num}" -ge 3007000 ]; then
        sed -i '/libpcre3/d' "${src}/build/package/nfpm.yaml"
    fi

    ##################################
    # pcre 10.43 的 JIT/sljit 对 loongarch 支持不完整
    ##################################
    if [ "${ver_num}" -eq 3007000 ] || [ "${ver_num}" -eq 3007001 ]; then
        sed -i 's/PCRE=.*/PCRE=10.44/' "${src}/.requirements"
        sed -i 's/sha256 =.*/sha256 = "86b9cb0aa3bcb7994faa88018292bc704cdbb708e785f7c74352ff6ea7d3175b",/' "${src}/build/openresty/pcre/pcre_repositories.bzl"
    fi

    ##################################
    # 处理 LuaJIT 加载巨大 manifest 时的 65536 constants 问题 
    ##################################
    if [ "${ver_num}" -le 3009001 ]; then
        sed -i 's/LUAROCKS=.*/LUAROCKS=3.12.2/' "${src}/.requirements"
        if [ "${ver_num}" -lt 3008000 ]; then
            sed -i 's/sha256 = .*/sha256 = "b0e0c85205841ddd7be485f53d6125766d18a81d226588d2366931e9a1484492",/' "${src}/build/luarocks/luarocks_repositories.bzl"
        else
            sed -i 's/LUAROCKS_SHA256=.*/LUAROCKS_SHA256=b0e0c85205841ddd7be485f53d6125766d18a81d226588d2366931e9a1484492/' "${src}/.requirements"
        fi
    fi

    ###################################
    # 处理将目录输出误声明成文件的问题(参考3.9.0+)
    ###################################
    if [ "${ver_num}" -lt 3009000 ]; then
        sed -i '/"etc\/luarocks"/i \
    ], \
    out_dirs = [' "${src}/build/BUILD.bazel"
        sed -i '/outputs.append(ctx.actions.declare_file/a\
    for f in ctx.attr.out_dirs: \
        outputs.append(ctx.actions.declare_directory(KONG_VAR["BUILD_NAME"] + "/" + f))' "${src}/build/build_system.bzl"
        sed -i '/"outs": attr.string_list()/a \
        "out_dirs": attr.string_list(),' "${src}/build/build_system.bzl"
        sed -i 's/output = ctx.actions.declare_file(full_path)/__ANCHOR__/' "${src}/build/build_system.bzl"
        sed -i '/__ANCHOR__/a \
        if file.is_directory: \
            output = ctx.actions.declare_directory(full_path) \
            src = file.path + "/." \
        else: \
            output = ctx.actions.declare_file(full_path) \
            src = file.path' "${src}/build/build_system.bzl"
        sed -i '/__ANCHOR__/d' "${src}/build/build_system.bzl"
        sed -i 's/command = "cp -r %s %s" % (file.path, output.path)/command = "cp -r %s %s" % (src, output.path)/' "${src}/build/build_system.bzl"
	
    fi

    ###################################
    # 处理 Bazel label 模板变量未展开的问题
    ###################################
    if [ "${ver_num}" -ge 3009000 ]; then
        sed -i '/substitutions\["{{%s}}" % l.label\] = p/a \
        label = str(l.label) \
        substitutions["{{%s}}" % label] = p \
        if label.startswith("@@"): \
            substitutions["{{%s}}" % label[1:]] = p \
        elif label.startswith("@"): \
            substitutions["{{@%s}}" % label] = p' "${src}/build/build_system.bzl"
        sed -i '/substitutions\["{{%s}}" % l.label\] = p/d' "${src}/build/build_system.bzl"
    fi

    ##################################
    # libxcrypt 4.4.27 补丁
    ##################################
    if [ "${ver_num}" -ge 3009000 ]; then
        sed -i '/name = "cross_deps_libxcrypt"/,/patches =/ s/patches = \[/patches = \["\/\/build\/cross_deps\/libxcrypt:libxcrypt_4.4.27_loongarch64.patch", /' "${src}/build/cross_deps/libxcrypt/repositories.bzl"
    else
        sed -i '/name = "cross_deps_libxcrypt"/a \
        patches = ["//build/cross_deps/libxcrypt:libxcrypt_4.4.27_loongarch64.patch", "//build/cross_deps/libxcrypt:001-4.4.27-enable-hash-all.patch"], \
        patch_args = ["-p1"],' "${src}/build/cross_deps/libxcrypt/repositories.bzl"
    fi

    ##################################
    # Rust/ATC 处理
    # 3.9.0 之前，Rust Bazel 构建逻辑在外部仓库: Kong/atc-router
    # 3.9.0 时 Rust Bazel 构建逻辑由 kong 主仓库接管
    ##################################
    if [ "${ver_num}" -ge 3009000 ]; then
        src_rust_adaption
    else
        sed -i '/name = "atc_router",/a \
        patches = ["//third_party:atc_router_1.6.2_loongarch64.patch"], \
        patch_args = ["-p1"],' "${src}/build/openresty/atc_router/atc_router_repositories.bzl"
    fi
}

# 3.9.0 之后的 Rust/ATC 逻辑适配
src_rust_adaption()
{
    ###################################
    # 添加 loongarch 的 rust_toolchain
    ###################################
    local var_name value
    local rustc_sha256=""
    local clippy_sha256=""
    local cargo_sha256=""
    local llvm_tools_sha256=""
    local rust_std_sha256=""
    local rust_version=$(grep -m 1 -oE 'versions = \["[0-9]+\.[0-9]+\.[0-9]+"\],' "${src}/build/kong_crate/deps.bzl" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')

    while IFS=$'\t' read -r var_name value; do
        printf -v "$var_name" '%s' "$value"
    done < <(get_rust_sha256 "$rust_version")

    sed -i '/rust_register_toolchains(/,/extra_target_triples = \[/ s/extra_target_triples = \[/extra_target_triples = \["loongarch64-unknown-linux-gnu", /' "${src}/build/kong_crate/deps.bzl"
    sed -i "/rust_register_toolchains(/,/sha256s = {/ {/sha256s = {/a \\
            ${rustc_sha256}, \\
            ${clippy_sha256}, \\
            ${cargo_sha256}, \\
            ${llvm_tools_sha256}, \\
            ${rust_std_sha256},
}" "${src}/build/kong_crate/deps.bzl"

    ###################################
    # platforms 和 rules_rust 添加补丁
    ###################################
    sed -i '/load("@bazel_tools\/\/tools\/build_defs\/repo:http.bzl"/a \
http_archive( \
    name = "platforms", \
    patch_args = ["-p1"], \
    patches = ["//third_party:platforms_1.1.0_loongarch64.patch"], \
    sha256 = "dbad4a23abcca6171e47b79edc53bd6a41067a3b75f9e8b104656b459ff25046", \
    urls = [ \
        "https://mirror.bazel.build/github.com/bazelbuild/platforms/releases/download/1.1.0/platforms-1.1.0.tar.gz", \
        "https://github.com/bazelbuild/platforms/releases/download/1.1.0/platforms-1.1.0.tar.gz", \
    ], \
)' "${src}/WORKSPACE" 
    sed -i '/name = "rules_rust"/a \
    patch_args = ["-p1"], \
    patches = ["//third_party:rules_rust_0.42.1_loongarch64.patch"],' "${src}/WORKSPACE"

}

# 获取 rust 工具链的 sha256
get_rust_sha256()
{
    local rust_version="$1"
    local triple=loongarch64-unknown-linux-gnu
    local tools=("rustc" "clippy" "cargo" "llvm-tools" "rust-std")
    local tool url sha filename var_name

    for tool in "${tools[@]}"; do
        url="https://static.rust-lang.org/dist/${tool}-${rust_version}-${triple}.tar.xz.sha256"
        read -r sha filename < <(curl -fsSL "$url")
        var_name="${tool//-/_}_sha256"
        value="\"${filename}\": \"${sha}\""
        printf '%s\t%s\n' "$var_name" "$value"
    done
}

# 依赖补丁
dep_adaption()
{
    mkdir -p "${src}/third_party"
    touch "${src}/third_party/BUILD.bazel"

    cp "${patches}/for_deps/rules_rust_0.42.1_loongarch64.patch" "${src}/third_party/"
    cp "${patches}/for_deps/libxcrypt_4.4.27_loongarch64.patch" "${src}/build/cross_deps/libxcrypt/"
    if [ "${ver_num}" -ge 3009000 ]; then
        cp "${patches}/for_deps/platforms_1.1.0_loongarch64.patch" "${src}/third_party/"
    else
        cp "${patches}/for_deps/atc_router_1.6.2_loongarch64.patch" "${src}/third_party/"
        cp "${patches}/for_deps/001-4.4.27-enable-hash-all.patch" "${src}/build/cross_deps/libxcrypt/"
    fi
}

patch()
{
    echo "patching..."
    src_universal_adaptation
    src_multi_version_adaptation
    dep_adaption
    echo "done"
}

patch
