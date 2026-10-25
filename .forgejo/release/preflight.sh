#!/bin/sh
# SACDPlayer release preflight hook.
#
# The generic `release` Action runs this file (see action-template/release/)
# with `sh .forgejo/release/preflight.sh`, inside the checkout of the pushed
# tag, with these variables in the environment:
#
#   RELEASE_VERSION   version without the leading "v" (e.g. 0.2.7)
#   RELEASE_TAG       tag as pushed (e.g. v0.2.7)
#   RELEASE_SHA       commit the tag points at
#   GITHUB_WORKSPACE  repository checkout (the current directory)
#   FORGEJO_DIR       `<repo>/.forgejo`
#
# This file belongs to the target repository: it checks the rules of THIS
# project only. Exit code 0 = pass, anything else = fail. The Action can bypass
# it with RELEASE_PRECHECK_OVERRIDE=pass (or not run it at all with `skip`).
#
# Rules checked here:
#   1. install.xml / Makefile / repo.xml all carry the tag version;
#   2. HEAD is the commit the tag points at (the Action checked the tag out);
#   3. repo.xml download URL points at this version (warning only — fix it
#      before releasing, but it lives outside `.forgejo`).
set -eu

cd "${GITHUB_WORKSPACE:-$(pwd)}"

errors=0
ok()   { echo "[OK] $*"; }
err()  { echo "[ERROR] $*"; errors=$((errors + 1)); }
warn() { echo "[WARN] $*"; }

version="${RELEASE_VERSION:-}"
tag="${RELEASE_TAG:-v$version}"
expected_sha="${RELEASE_SHA:-}"

if [ -z "$version" ]; then
  echo "[ERROR] RELEASE_VERSION 未设置（本 hook 需由 release Action 运行）"
  exit 1
fi

echo "[preflight] version=$version tag=$tag"

# --- 1. version consistency -------------------------------------------------
# A Lyrion plugin is distributed through install.xml (LMS), repo.xml (plugin
# catalog) and packaged by the Makefile. All three must agree with the tag,
# otherwise the release would ship mixed metadata.
install_version=$(sed -n 's:.*<version>[[:space:]]*\([^<]*\)[[:space:]]*</version>.*:\1:p' install.xml | head -n 1)
makefile_version=$(sed -n 's:^VERSION[[:space:]]*?=[[:space:]]*\([^[:space:]]*\).*:\1:p' Makefile | head -n 1)
repo_version=$(sed -n 's:.*<plugin[^>]*[[:space:]]version="\([^"]*\)".*:\1:p' repo.xml | head -n 1)

check_version() {
  file=$1
  actual=$2
  if [ "$actual" = "$version" ]; then
    ok "$file 版本 = $actual"
  else
    err "$file 版本是 '${actual:-<未找到>}'，应与 tag 一致（$version）"
  fi
}

check_version install.xml "$install_version"
check_version Makefile "$makefile_version"
check_version repo.xml "$repo_version"

# --- 2. HEAD is the tagged commit -------------------------------------------
head_sha=$(git rev-parse HEAD 2>/dev/null || true)
if [ -z "$expected_sha" ]; then
  warn "RELEASE_SHA 未设置，跳过 HEAD 校验"
elif [ "$head_sha" = "$expected_sha" ]; then
  ok "HEAD = $head_sha（tag $tag 指向的提交）"
else
  err "HEAD ($head_sha) 与 tag $tag 指向的提交 ($expected_sha) 不一致"
fi

# --- 3. repo.xml download URL (warning only) --------------------------------
# The catalog points at the ZIP we upload; a stale tag here means LMS would
# download an old (or missing) file. It is a warning, not an error: this URL is
# fixed outside `.forgejo` and must not block the workflow.
download_url=$(sed -n 's:.*<url>[[:space:]]*\([^<]*\)[[:space:]]*</url>.*:\1:p' repo.xml | head -n 1)
case "$download_url" in
  *"/download/v$version/"*)
    ok "repo.xml 下载地址指向 v$version"
    ;;
  *)
    warn "repo.xml 下载地址未指向 /download/v$version/：${download_url:-<未找到>}"
    warn "发布前请把 repo.xml 的 <url> 更新为 .../releases/download/v$version/SACDPlayer-$version.zip"
    ;;
esac

# --- summary -----------------------------------------------------------------
echo
if [ "$errors" -ne 0 ]; then
  echo "[ERROR] preflight 失败：$errors 项检查未通过（可设 RELEASE_PRECHECK_OVERRIDE=pass 临时放行）"
  exit 1
fi
echo "[OK] preflight 通过"
