#!/usr/bin/env bash
set -euo pipefail

# 记录原始分支和工作区状态
ORIGINAL_BRANCH=$(git branch --show-current)
STASH_CREATED=false

# 保存未提交的修改（包括未跟踪文件）
if [[ -n "$(git status --porcelain)" ]]; then
    git stash push --include-untracked -m "temporary-release-stash"
    STASH_CREATED=true
fi

# 无论发布成功与否，都恢复原始分支和工作区
cleanup() {
    local exit_code=$?

    trap - EXIT

    if [[ -n "$ORIGINAL_BRANCH" ]]; then
        git switch "$ORIGINAL_BRANCH" || {
            echo "错误：无法恢复原始分支 $ORIGINAL_BRANCH" >&2
            exit 1
        }
    fi

    if [[ "$STASH_CREATED" == true ]]; then
        git stash pop || {
            echo "错误：无法自动恢复工作区修改，请手动执行 git stash list" >&2
            exit 1
        }
    fi

    exit "$exit_code"
}
trap cleanup EXIT

# 切换到 main 分支并更新
git switch main
git pull --ff-only origin main

# 获取远程 tag
git fetch --tags origin

# 确定版本号
if [[ $# -ge 1 ]]; then
    VERSION="$1"
else
    LATEST_TAG=$(git tag -l 'v[0-9]*' --sort=-v:refname | head -n 1)

    if [[ -z "$LATEST_TAG" ]]; then
        VERSION="v0.0.1"
    else
        if [[ ! "$LATEST_TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
            echo "错误：最新 tag 格式不正确：$LATEST_TAG" >&2
            exit 1
        fi

        VERSION="v${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
    fi
fi

# 检查 tag 是否已存在
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
    echo "错误：tag $VERSION 已存在" >&2
    exit 1
fi

echo "准备发布版本：$VERSION"

# 创建并推送 tag
git tag -a "$VERSION" -m "Release $VERSION"
git push origin "$VERSION"

echo "发布成功：$VERSION"
