#!/bin/sh
# SACDPlayer release prepare hook.
#
# The generic `release` Action runs this file (see action-template/release/)
# with `sh .forgejo/release/prepare.sh`, inside the checkout of the pushed tag,
# with these variables in the environment:
#
#   RELEASE_VERSION       version without the leading "v" (e.g. 0.2.7)
#   RELEASE_TAG           tag as pushed (e.g. v0.2.7)
#   GITHUB_WORKSPACE      repository checkout (the current directory)
#   FORGEJO_DIR           `<repo>/.forgejo` (holds the installed Action programs)
#   RELEASE_ASSETS_FILE   manifest file the Action reads afterwards
#
# Must write the ABSOLUTE path of every file to publish, one per line, to
# $RELEASE_ASSETS_FILE. The Action uploads those files to the Forgejo and/or
# GitHub release (depending on the RELEASE_* switches).
#
# This hook is optional in general; for this repository it produces the two
# artifacts the release ships:
#   dist/SACDPlayer-<version>-all.tar.gz       (installable folder, all binaries)
#   dist/SACDPlayer-<version>.zip              (what repo.xml downloads)
set -eu

: "${GITHUB_WORKSPACE:?prepare.sh: GITHUB_WORKSPACE 未设置（本 hook 需由 release Action 运行）}"
: "${RELEASE_VERSION:?prepare.sh: RELEASE_VERSION 未设置}"
: "${RELEASE_ASSETS_FILE:?prepare.sh: RELEASE_ASSETS_FILE 未设置（由 release Action 提供）}"
FORGEJO_DIR="${FORGEJO_DIR:-$GITHUB_WORKSPACE/.forgejo}"

cd "$GITHUB_WORKSPACE"

version="$RELEASE_VERSION"

if ! command -v make >/dev/null 2>&1; then
  echo "[ERROR] 找不到 make：默认镜像 node:22-bookworm 自带 build-essential；" >&2
  echo "        换用精简镜像时请预装 make/gcc/tar，或用 RELEASE_JOB_PACKAGES 声明。" >&2
  exit 1
fi

# `bundle-all` needs the Debian cross toolchains.  The generic Action's
# ensure-tools helper honours APT_PROXY/mirrors; do not call apt-get directly.
missing_cross=""
for cc in aarch64-linux-gnu-gcc arm-linux-gnueabihf-gcc arm-linux-gnueabi-gcc i686-linux-gnu-gcc x86_64-w64-mingw32-gcc; do
  command -v "$cc" >/dev/null 2>&1 || missing_cross="$missing_cross $cc"
  # `gcc-aarch64-linux-gnu` only *recommends* the cross libc headers.  Some
  # CI images install without recommends, leaving the compiler present but
  # /usr/<triple>/include/bits missing.
  printf '#include <stdio.h>\nint main(void){return 0;}\n' | "$cc" -x c -fsyntax-only - >/dev/null 2>&1     || missing_cross="$missing_cross $cc(+libc)"
done
if [ -n "$missing_cross" ]; then
  echo "[prepare] 缺少交叉编译器或交叉 libc：$missing_cross；调用 ensure-tools 安装"
  if ! RELEASE_JOB_PACKAGES="gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf gcc-arm-linux-gnueabi gcc-i686-linux-gnu gcc-mingw-w64-x86-64 libc6-dev-arm64-cross libc6-dev-armhf-cross libc6-dev-armel-cross libc6-dev-i386-cross" \
       node "$FORGEJO_DIR/scripts/run.mjs" ensure-tools; then
    echo "[ERROR] 交叉编译器/交叉 libc 安装失败；请检查 RELEASE_JOB_PACKAGES 与 APT_PROXY" >&2
    exit 1
  fi
fi

# `zip` is not in node:22-bookworm (only `unzip` is). Install it through the
# Action's generic installer so APT_PROXY / APK_REPO / YUM_REPO and the proxy
# variables are honoured — do not call apt-get/yum directly here: APT_PROXY may
# be a mirror root, where a raw `apt-get update` would get 404/308.
if ! command -v zip >/dev/null 2>&1; then
  echo "[prepare] 缺少 zip，调用通用 ensure-tools 安装（RELEASE_JOB_PACKAGES=zip）"
  if ! RELEASE_JOB_PACKAGES=zip node "$FORGEJO_DIR/scripts/run.mjs" ensure-tools; then
    echo "[ERROR] ensure-tools 安装 zip 失败；请检查 APT_PROXY/APK_REPO/YUM_REPO 与代理变量" >&2
    exit 1
  fi
  if ! command -v zip >/dev/null 2>&1; then
    echo "[ERROR] zip 仍未安装：请在仓库变量设 RELEASE_JOB_PACKAGES=zip（并确认镜像/代理可达）" >&2
    exit 1
  fi
fi

case "${RELEASE_TAG:-v$version}" in
  v*) tag_prefix=v ;;
  *)  tag_prefix= ;;
esac

echo "[prepare] make bundle-all VERSION=$version RELEASE_TAG_PREFIX=$tag_prefix"
make bundle-all VERSION="$version" RELEASE_TAG_PREFIX="$tag_prefix"

tarball="dist/SACDPlayer-$version-all.tar.gz"
if [ ! -f "$tarball" ]; then
  echo "[ERROR] make bundle-all 没有产出 $tarball" >&2
  exit 1
fi

# Build the catalog ZIP from the same dist/SACDPlayer folder that went into the
# tarball, so both assets always contain identical files.
zip_name="SACDPlayer-$version.zip"
zip_path="dist/$zip_name"
rm -f "$zip_path"
(
  cd dist
  zip -qr "$zip_name" SACDPlayer
)

tarball_abs="$GITHUB_WORKSPACE/$tarball"
zip_abs="$GITHUB_WORKSPACE/$zip_path"

for asset in "$tarball_abs" "$zip_abs"; do
  if [ ! -s "$asset" ]; then
    echo "[ERROR] 产物不存在或为空：$asset" >&2
    exit 1
  fi
done

# Hand both absolute paths to the Action (one per line; blank lines are
# ignored, duplicates are de-duplicated).
mkdir -p "$(dirname "$RELEASE_ASSETS_FILE")" 2>/dev/null || true
: > "$RELEASE_ASSETS_FILE"
printf '%s\n' "$tarball_abs" >> "$RELEASE_ASSETS_FILE"
printf '%s\n' "$zip_abs" >> "$RELEASE_ASSETS_FILE"

echo "[prepare] 资产清单（$RELEASE_ASSETS_FILE）："
for asset in "$tarball_abs" "$zip_abs"; do
  bytes=$(wc -c < "$asset")
  echo "  - $(basename "$asset")  ${bytes} bytes"
done
