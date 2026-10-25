#!/bin/sh
# SACDPlayer release preflight hook.
#
# The generic `release` Action runs this file (see action-template/release/)
# with `sh .forgejo/release/preflight.sh`, inside the checkout of the pushed tag,
# with these variables in the environment:
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
#   1. VERSION (the single source of truth) matches the tag version;
#   2. install.xml.in / repo.xml.in still contain their build placeholders
#      (the real XML is rendered only by `make bundle`);
#   3. HEAD is the commit the tag points at (the Action checked the tag out).
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
version_file=$(cat VERSION 2>/dev/null | head -n 1 || true)
version_file=$(printf '%s' "$version_file" | tr -d '[:space:]')
if [ "$version_file" = "$version" ]; then
  ok "VERSION = $version"
else
  err "VERSION 是 '${version_file:-<未找到>}'，应把 VERSION 更新为 $version"
fi

# The manifests are templates; no concrete version should be committed.
if grep -q '<version>@VERSION@</version>' install.xml.in 2>/dev/null; then
  ok "install.xml.in 使用 @VERSION@ 占位符"
else
  err "install.xml.in 缺少 <version>@VERSION@</version> 占位符"
fi
if grep -q 'version="@VERSION@"' repo.xml.in 2>/dev/null \
   && grep -q '<url>@RELEASE_URL@</url>' repo.xml.in 2>/dev/null; then
  ok "repo.xml.in 使用版本/URL 占位符"
else
  err "repo.xml.in 缺少 @VERSION@ 或 @RELEASE_URL@ 占位符"
fi


# --- 2. HEAD is the tagged commit -------------------------------------------
head_sha=$(git rev-parse HEAD 2>/dev/null || true)
if [ -z "$expected_sha" ]; then
  warn "RELEASE_SHA 未设置，跳过 HEAD 校验"
elif [ "$head_sha" = "$expected_sha" ]; then
  ok "HEAD = $head_sha（tag $tag 指向的提交）"
else
  err "HEAD ($head_sha) 与 tag $tag 指向的提交 ($expected_sha) 不一致"
fi

# --- summary -----------------------------------------------------------------
echo
if [ "$errors" -ne 0 ]; then
  echo "[ERROR] preflight 失败：$errors 项检查未通过（可设 RELEASE_PRECHECK_OVERRIDE=pass 临时放行）"
  exit 1
fi
echo "[OK] preflight 通过"
