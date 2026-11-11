#!/usr/bin/env bash
#
# 方案 B 构建脚本（无 UPX）。
# 用法: ./build.sh <输入payload> [输出stub]
#
set -euo pipefail

PAYLOAD_SRC="${1:-}"
OUTPUT="${2:-installer}"
PAYLOAD_FILE="payload.gz"
STUB_PKG="${STUB_PKG:-.}"

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

    # 检测 gzip 魔数 1f 8b
    MAGIC="$(head -c 2 "${PAYLOAD_SRC}" | od -An -tx1 | tr -d ' \n')"
    if [[ "${MAGIC}" == "1f8b" ]]; then
        echo "==> 输入已是 gzip: ${PAYLOAD_SRC} → ${PAYLOAD_FILE}"
        cp -f "${PAYLOAD_SRC}" "${PAYLOAD_FILE}"
    else
        # 非 gzip：必须用外部 gzip 程序压缩；不存在则报错
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
HASH=""
if [[ -d tools/hash ]]; then
    HASH="$(go run ./tools/hash -decompress -file "${PAYLOAD_FILE}" | tr -d '[:space:]')"
elif command -v xxhsum >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
    HASH="$(gzip -dc "${PAYLOAD_FILE}" | xxhsum -H1 | awk '{print $1}')"
else
    echo "错误: 需要 tools/hash 或 (xxhsum + gzip) 来计算哈希" >&2
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

echo "==> 构建 stub -> ${OUTPUT}"
go build -ldflags="-X main.realAppXXH64Hex=${HASH}" -o "${OUTPUT}" "${STUB_PKG}"

echo "==> 完成: ${OUTPUT}"