#!/bin/bash
set -euo pipefail

UPSTREAM_OWNER=Kong
UPSTREAM_REPO=kong
VERSION="${1}"
echo "   🏢 Org:   ${UPSTREAM_OWNER}"
echo "   📦 Proj:  ${UPSTREAM_REPO}"
echo "   🏷️  Ver:   ${VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
DISTS="${ROOT_DIR}/dists"
SRCS="${ROOT_DIR}/srcs"
PATCHES="${ROOT_DIR}/patches"

mkdir -p "${DISTS}/${VERSION}" "${SRCS}"

echo "🔧 Compiling ${UPSTREAM_OWNER}/${UPSTREAM_REPO} ${VERSION}..."

# 1. 准备阶段：安装依赖、下载代码、应用补丁等
prepare()
{
    echo "📦 [Prepare] Setting up build environment..."

    local RULES_RUST_VER=0.42.1
    # 源码
    git clone -b "${VERSION}" --depth 1 "https://github.com/${UPSTREAM_OWNER}/${UPSTREAM_REPO}.git" "${SRCS}/${VERSION}"
    # cargo-bazel
    wget -O "${CARGO_BAZEL_BIN}" "https://github.com/Loongson-Cloud-Community/rules_rust/releases/download/${RULES_RUST_VER}/cargo-bazel-loongarch64-unknown-linux-gnu"
    # 补丁
    "${PATCHES}/patch.sh" "${SRCS}/${VERSION}" "${VERSION}" "${PATCHES}"
    
    echo "✅ [Prepare] Environment ready."
}

# 2. 编译阶段：核心构建命令
build()
{
    local MAJOR_VER=$(echo ${VERSION} | cut -d. -f1)
    local MINOR_VER=$(echo ${VERSION} | cut -d. -f1)
    local VER_NUM=$(( 10#$MAJOR_VER * 1000 + 10#$MINOR_VER ))

    echo "🔨 [Build] Compiling source code..."
    
    pushd "${SRCS}/${VERSION}"

    export CARGO_BAZEL_GENERATOR_URL="file://${CARGO_BAZEL_BIN}"
    
    if [ "${VER_NUM}" -ge 3009000 ]; then
        # 更新 crate_locks/atc_router.lock
        CARGO_BAZEL_REPIN=true \
        CARGO_BAZEL_REPIN_ONLY=atc_router_crate_index \
            bazel sync --noenable_bzlmod --only=atc_router_crate_index
    fi

   local BUILD_PARAM=(
            --noenable_bzlmod
            --config=release
            --platforms=//:generic-loongarch64
            --//:wasmx=false
            --//:skip_webui=true
            --verbose_failures
	 )
    # 构建 kong
    if [ "${VER_NUM}" -ge 3009000 ]; then
        bazel build "${BUILD_PARAM[@]}" //build:kong
    else
        bazel build "${BUILD_PARAM[@]}" //build:kong || bazel build "${BUILD_PARAM[@]}" //build:kong
    fi

    # 构建 deb 包
    export NFPM_BIN=/tmp/go/bin/nfpm
    bazel build "${BUILD_PARAM}" //:kong_deb

    popd

    echo "✅ [Build] Compilation finished."
}

# 3. 后处理阶段：整理产物、清理临时文件、验证版本
post_build()
{
    echo "📦 [Post-Build] Organizing artifacts..."
    
    local PRODUCT="${DISTS}/${VERSION}//kong_${VERSION}_loongarch64.deb"
    # 输出目录是链接
    local BUILD_OUTPUT="$(find -L ${SRCS}/${VERSION} -name "*".deb -print -quit)"

    cp "${BUILD_OUTPUT}" "${PRODUCT}"
    chown -R "${HOST_UID}:${HOST_GID}" "${DISTS}" "${SRCS}"
    
    echo "✅ [Post-Build] Artifacts ready in ./dists/${VERSION}."
}

# 主入口
main()
{
    local CARGO_BAZEL_BIN="/tmp/cargo-bazel"

    prepare
    build
    post_build
}

main


cat > "${DISTS}/${VERSION}/release.txt" <<EOF
Project: ${UPSTREAM_REPO}
Organization: ${UPSTREAM_OWNER}
Version: ${VERSION}
Build Time: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

echo "✅ Compilation finished."
ls -lh "${DISTS}/${VERSION}"
