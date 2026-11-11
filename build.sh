#!/usr/bin/env bash
#
# 用法: ./build.sh <输入payload> [输出stub]
# 未指定输出时原地替换输入（先构建到临时文件再 mv）。
# 环境变量: STUB_PKG  stub 源码目录，默认 "."（脚本所在目录）
#
# 可从任意工作目录调用：
#   - 输入/输出参数按调用者 CWD 解析
#   - tools/hash、go build 包路径、payload.gz 以脚本目录为基准
#
set -euo pipefail

ORIG_PWD="$(pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PAYLOAD_SRC="${1:-}"
OUTPUT="${2:-}"
PAYLOAD_FILE="payload.gz"
STUB_PKG_ENV="${STUB_PKG:-}"

# 相对调用者 CWD 绝对化
abs_from_cwd() {
    local p="$1"
    if [[ -z "$p" ]]; then
        printf '%s' ""
    elif [[ "$p" == /* ]]; then
        printf '%s' "$p"
    else
        printf '%s/%s' "$ORIG_PWD" "$p"
    fi
}

# ===== 0. 未指定输出 → 原地替换 =====
INPLACE=0
if [[ -z "${OUTPUT}" ]]; then
    if [[ -n "${PAYLOAD_SRC}" ]]; then
        OUTPUT="${PAYLOAD_SRC}"
        INPLACE=1
    else
        OUTPUT="installer"
    fi
fi

# ===== 输出路径规范化（按调用者 CWD 判断目录语义） =====
if [[ "${OUTPUT}" == */ ]] || [[ -d "${OUTPUT}" ]]; then
    OUTPUT="${OUTPUT%/}/installer"
fi

# ===== 参数绝对化 =====
PAYLOAD_SRC="$(abs_from_cwd "${PAYLOAD_SRC}")"
OUTPUT="$(abs_from_cwd "${OUTPUT}")"

# STUB_PKG：默认 "."（= 脚本目录）；显式给出的相对路径按调用者 CWD 解析
if [[ -n "${STUB_PKG_ENV}" ]]; then
    STUB_PKG="$(abs_from_cwd "${STUB_PKG_ENV}")"
else
    STUB_PKG="."
fi

# ===== 切到脚本目录，后续相对路径均以脚本目录为基准 =====
cd "${SCRIPT_DIR}"

# ===== 1. 准备 payload.gz =====
if [[ -z "${PAYLOAD_SRC}" ]]; then
    if [[ -f "${PAYLOAD_FILE}" ]]; then
        echo "==> 未指定输入，复用已存在的 ${PAYLOAD_FILE}"
    else
        echo "用法: $0 <输入payload文件> [输出stub文件]" >&2
        echo "示例: $0 a/payload-linux.gz a/payload-linux" >&2
        exit 2
    fi
else
    if [[ ! -f "${PAYLOAD_SRC}" ]]; then
        echo "错误: 输入文件不存在: ${PAYLOAD_SRC}" >&2
        exit 1
    fi

    # 防御：源文件就是 payload.gz 自身时，复制/压缩都会破坏它
    SRC_ABS="$(cd "$(dirname "${PAYLOAD_SRC}")" && pwd)/$(basename "${PAYLOAD_SRC}")"
    DST_ABS="$(pwd)/${PAYLOAD_FILE}"
    if [[ "${SRC_ABS}" == "${DST_ABS}" ]]; then
        echo "错误: 输入文件与中间文件 ${PAYLOAD_FILE} 相同，无法原地处理" >&2
        echo "      请先把输入另存为其它文件名，或显式指定输出路径" >&2
        exit 1
    fi

    # 检测 gzip 魔数 1f 8b
    MAGIC="$(head -c 2 "${PAYLOAD_SRC}" | od -An -tx1 | tr -d ' \n')"
    if [[ "${MAGIC}" == "1f8b" ]]; then
        echo "==> 输入已是 gzip: ${PAYLOAD_SRC} → ${PAYLOAD_FILE}"
        cp -f "${PAYLOAD_SRC}" "${PAYLOAD_FILE}"
    else
        if ! command -v gzip >/dev/null 2>&1; then
            echo "错误: 输入 ${PAYLOAD_SRC} 不是 gzip 格式，但系统未找到 gzip 程序，无法压缩" >&2
            echo "      请安装 gzip（例如 apt/yum/brew install gzip）后重试" >&2
            exit 1
        fi
        echo "==> 输入非 gzip，使用 gzip 压缩: ${PAYLOAD_SRC} → ${PAYLOAD_FILE}"
        gzip -9 -c "${PAYLOAD_SRC}" > "${PAYLOAD_FILE}"
    fi
fi

# ===== 2. 计算 xxh64（解压后真实程序的哈希，与 stub 语义对齐） =====
echo "==> 计算 xxh64 哈希（-decompress）"
HASH_TOOL=""
if [[ -x "tools/hash/hash" ]]; then
    HASH_TOOL="tools/hash/hash"
elif [[ -f "tools/hash/main.go" ]]; then
    HASH_TOOL="go run ./tools/hash"
fi

HASH=""
if [[ -n "${HASH_TOOL}" ]]; then
    HASH="$(${HASH_TOOL} -decompress -file "${PAYLOAD_FILE}" | tr -d '[:space:]')"
elif command -v xxhsum >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
    HASH="$(gzip -dc "${PAYLOAD_FILE}" | xxhsum -H1 | awk '{print $1}')"
else
    echo "错误: 需要 tools/hash（已编译或源码）或 (xxhsum + gzip) 来计算哈希" >&2
    exit 1
fi
if [[ -z "${HASH}" ]]; then
    echo "错误: 计算的 xxh64 为空（请检查 tools/hash 是否编译成功）" >&2
    exit 1
fi
echo "    payload=${PAYLOAD_FILE}  xxh64=${HASH}"

# ===== 3. 构建 stub =====
OUT_DIR="$(dirname "${OUTPUT}")"
if [[ "${OUT_DIR}" != "." && ! -d "${OUT_DIR}" ]]; then
    mkdir -p "${OUT_DIR}"
fi

BUILD_OUT="${OUTPUT}"
if [[ "${INPLACE}" == "1" ]]; then
    BUILD_OUT="${OUTPUT}.vrun-stub.tmp"
fi

echo "==> 构建 stub -> ${OUTPUT}"
if [[ "${BUILD_OUT}" != "${OUTPUT}" ]]; then
    echo "    原地替换模式：先构建到临时文件 ${BUILD_OUT}"
fi

# 构建失败不破坏原文件：INPLACE 时清理临时文件，非 INPLACE 直接退出
if ! go build -trimpath -ldflags="-s -w -X main.realAppXXH64Hex=${HASH}" -o "${BUILD_OUT}" "${STUB_PKG}"; then
    if [[ "${INPLACE}" == "1" ]]; then
        rm -f "${BUILD_OUT}"
    fi
    echo "错误: 构建 stub 失败" >&2
    exit 1
fi

# 仅构建成功后才覆盖原文件
if [[ "${INPLACE}" == "1" ]]; then
    if ! mv -f "${BUILD_OUT}" "${OUTPUT}"; then
        echo "错误: 覆盖 ${OUTPUT} 失败（文件可能正被占用）" >&2
        echo "      新 stub 已保留在: ${BUILD_OUT}" >&2
        echo "      占用解除后可手动执行: mv -f '${BUILD_OUT}' '${OUTPUT}'" >&2
        echo "      注意：不要对已替换过的文件再次运行本脚本（会嵌套 stub）" >&2
        exit 1
    fi
fi

# ===== 4. 清理本次生成的 payload.gz =====
# 仅当本次通过 PAYLOAD_SRC 生成时删除；无参数复用的 payload.gz 保留。
# VRUN_KEEP_PAYLOAD=1 可强制保留。
if [[ -n "${PAYLOAD_SRC}" && "${VRUN_KEEP_PAYLOAD:-0}" != "1" ]]; then
    if [[ -f "${PAYLOAD_FILE}" ]]; then
        if rm -f "${PAYLOAD_FILE}" 2>/dev/null; then
            echo "==> 已清理中间文件 ${PAYLOAD_FILE}"
        else
            echo "==> 警告: 无法删除 ${PAYLOAD_FILE}（可能被占用），已保留" >&2
        fi
    fi
fi

echo "==> 完成: ${OUTPUT}"