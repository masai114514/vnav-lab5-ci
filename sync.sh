#!/usr/bin/env bash
# =============================================================================
# sync.sh —— 把 lab5 里 CI 需要的那部分拷进本仓的 bundle/
#
# 为什么要有这一步
# ----------------
# 本仓是**独立仓**（跑在 GitHub Actions 上），而源码的正本在 `../`（也就是 lab5/）。
# 改完任何一个 .cpp / .h / launch 之后，先 sync 再 push，两边才一致 ——
# 忘了 sync 就推，CI 编的是旧代码，你会在 Actions 里看到一个「明明改过却没过」的结果。
#
# 只同步构建与运行真正要用的两个目录：
#   feature_tracking/  —— 要提交的 ROS 包（含 images/box.png 两张图）
#   dependencies/      —— opencv3_catkin（已打 nonfree 补丁）+ gflags_catkin
# glog_catkin / catkin_simple 不镜像：CI 里直接 git clone（省本仓体积）。
#
# 刻意**不**同步的：individual/（个人题 LaTeX + 图）、offline/（离线复算 venv）、
#   docs/、fig/ —— 这些是交付物与文档，CI 用不到，放进来只会让推送变慢，
#   而且 individual/ 里有一个 200 MB 的 .venv。
#
# 用法：
#   bash sync.sh              # 默认从 ../ 同步
#   SRC=<lab5 路径> bash sync.sh
#   bash sync.sh --dry-run    # 只看会动哪些文件
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$(cd "$HERE/.." && pwd)}"
DEST="$HERE/bundle"
PKGS=(feature_tracking dependencies)

DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="--dry-run"

say() { printf '\033[1;36m[sync]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[sync] %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "$SRC/feature_tracking" ] || die "SRC=$SRC 下没有 feature_tracking/ —— 指向 lab5/ 了吗？"
[ -d "$SRC/dependencies" ]     || die "SRC=$SRC 下没有 dependencies/"

command -v rsync >/dev/null 2>&1 || die "没有 rsync"

mkdir -p "$DEST"
for p in "${PKGS[@]}"; do
  [ -d "$SRC/$p" ] || { printf '\033[1;33m[sync]\033[0m 跳过（不存在）：%s\n' "$p"; continue; }
  say "同步 $p/"
  # --delete：源里删掉的文件在镜像里也消失，避免 CI 编到已经不存在的头文件
  # 排除 __pycache__ / .pyc：否则带本机绝对路径的 .pyc 会被推上去
  rsync -a --delete $DRY \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    --exclude '.DS_Store' \
    "$SRC/$p/" "$DEST/$p/"
done

# 提交前自检：占了位却没实现，CI 一定挂；在这里提前喊一声
say "检查 FILL IN HERE 残留："
if grep -rn "FILL IN HERE" "$DEST/feature_tracking" 2>/dev/null | head -10; then
  printf '\033[1;31m[sync] 上面这些还没实现，CI 会挂（或算不对）\033[0m\n'
else
  say "  无残留"
fi

say "镜像现状："
for p in "${PKGS[@]}"; do
  [ -d "$DEST/$p" ] || continue
  n=$(find "$DEST/$p" -type f | wc -l | tr -d ' ')
  s=$(du -sh "$DEST/$p" | cut -f1)
  printf '    %-22s %4s 文件  %6s\n' "$p" "$n" "$s"
done
printf '    %-22s %4s 文件  %6s\n' "合计" \
  "$(find "$DEST" -type f | wc -l | tr -d ' ')" "$(du -sh "$DEST" | cut -f1)"
say "完成。下一步：python3 push_via_api.py"
