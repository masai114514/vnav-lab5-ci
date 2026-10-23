#!/usr/bin/env bash
# =============================================================================
# unsync.sh —— 把 bundle/ 里的改动**反向**同步回正本（../feature_tracking）
#
# 为什么需要它
# ------------
# 队友（Windows）clone 的是这个 CI 仓，他们能改的路径只有 `bundle/feature_tracking/`
# —— 因为 `../feature_tracking/`（正本）不在这个仓里。于是合并完他们的 PR 之后，
# 正本反而是旧的。这个脚本把仓里的镜像回灌到正本，方向与 sync.sh 相反。
#
# ⚠️ 它会**覆盖**正本里同名的文件。默认先列出差异并要你确认；`--yes` 跳过确认。
#
# 用法：
#   bash unsync.sh              # 看差异 + 确认后覆盖
#   bash unsync.sh --dry-run    # 只看差异
#   bash unsync.sh --yes        # 不确认（脚本里用）
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/bundle"
DEST="${DEST:-$(cd "$HERE/.." && pwd)}"
PKGS=(feature_tracking dependencies)

DRY=""
ASSUME_YES=""
for a in "${@:-}"; do
  case "$a" in
    --dry-run) DRY="--dry-run" ;;
    --yes|-y)  ASSUME_YES=1 ;;
  esac
done

say()  { printf '\033[1;36m[unsync]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[unsync]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[unsync] %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "$SRC" ] || die "没有 $SRC —— 先跑一次 sync.sh 生成镜像"
[ -d "$DEST" ] || die "正本目录不存在：$DEST"
[ "$SRC" != "$DEST" ] || die "SRC 和 DEST 是同一个目录，拒绝执行"

say "镜像 = $SRC"
say "正本 = $DEST"

# ---- 1) 先给差异，别闷头覆盖 ------------------------------------------------
changed=0
for p in "${PKGS[@]}"; do
  [ -d "$SRC/$p" ] || continue
  [ -d "$DEST/$p" ] || { warn "正本缺 $p/，将整体拷过去"; continue; }
  d="$(rsync -ain --delete \
        --exclude '__pycache__/' --exclude '*.pyc' --exclude '.DS_Store' \
        "$SRC/$p/" "$DEST/$p/" || true)"
  if [ -n "$d" ]; then
    printf '\n\033[1m%s/\033[0m\n' "$p"
    printf '%s\n' "$d" | sed 's/^/    /'
    changed=$((changed + $(printf '%s\n' "$d" | wc -l | tr -d ' ')))
  fi
done

if [ "$changed" -eq 0 ]; then
  say "两边完全一致，没什么要回灌的。"
  exit 0
fi

say "共 $changed 处差异"
[ -n "$DRY" ] && { say "--dry-run，不动文件。"; exit 0; }

if [ -z "$ASSUME_YES" ]; then
  printf '\033[1;33m[unsync] 这会覆盖正本里上面列出的文件。继续？[y/N] \033[0m'
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) say "已取消。"; exit 0 ;; esac
fi

# ---- 2) 回灌 ----------------------------------------------------------------
for p in "${PKGS[@]}"; do
  [ -d "$SRC/$p" ] || continue
  mkdir -p "$DEST/$p"
  rsync -a --delete \
    --exclude '__pycache__/' --exclude '*.pyc' --exclude '.DS_Store' \
    "$SRC/$p/" "$DEST/$p/"
  say "回灌 $p/"
done

say "完成。别忘了正本里还有别人正在改的东西 —— 用 git diff / 编辑器看一眼再提交。"
