# CI 当前状态 / 回来先看这里

**更新时间**：2026-10-23 11:58（本地） / 03:58 UTC

## 一句话

Run #2（`39894286741`）**还在跑**，卡在「主流程」这一步已经 **40 分钟**，正在编 OpenCV 3.4.2。
**关机不影响它** —— 跑在 GitHub 的机器上，和你的电脑无关。

## 回来第一件事

```bash
gh run list --repo masai114514/vnav-lab5-ci --limit 3
```

- 看到 `completed / success` → 直接下载产物：

  ```bash
  cd ~/Desktop/机器人实验/lab5/github-ci
  ./fetch_artifacts.sh          # 落到 ci_runs/<run_id>/
  ```

  然后看 `out/report.md`（两张表 + 图清单）和 `out/fig/*.png`。

- 看到 `completed / failure` → 先把失败的 stage 捞出来：

  ```bash
  gh run view <run_id> --repo masai114514/vnav-lab5-ci --log \
    | sed 's/\x1b\[[0-9;]*m//g' | grep -E "STAGE|FAIL|E: |error:" | tail -40
  ```

## ⚠️ 本地有 4 处改动没推上去（故意的）

为了**不取消正在跑的那一趟**（workflow 里有 `concurrency: cancel-in-progress: true`），
下面这些改动只存在本地，等 Run #2 结束后再推：

| 文件 | 改了什么 | 为什么必须改 |
|---|---|---|
| `.github/workflows/lab5-ci.yml` | `actions/cache` → `restore` + `save(if: always())` | 原来的 `actions/cache` 的保存钩子是 `post-if: success()`，**job 一失败就什么都不存**，25 分钟的 OpenCV 白编 |
| `ci/lab5_ci.sh` | `touch $WS_DEPS/install/.catkin` | `catkin build --extend` 要找这个标记文件，缺了报 `Unable to find catkin config file` |
| `ci/lab5_ci.sh` | `ls | grep -c` 加 `|| true` | `grep -c` 匹配 0 行时退出码是 1，`set -e` 下会把整个 stage 判失败 |
| `ci/lab5_ci.sh` | `local try_clone` 删掉；去掉 `-DCMAKE_CXX_FLAGS=-O2` | 函数名不能 `local`；和 Release 的 `-O3` 冲突 |

推送命令（等 Run #2 结束后）：

```bash
cd ~/Desktop/机器人实验/lab5/github-ci
PY=/Users/114514ma/.workbuddy/binaries/python/envs/default/bin/python
$PY push_via_api.py --message "fix(ci): 缓存失败也保存 + catkin .catkin 标记 + grep -c 的 set -e 陷阱"
```

这一趟会命中 OpenCV 缓存（key 没变），6–10 分钟出新结果。

## 时间账（判断有没有卡死）

| 阶段 | 首次（无缓存） | 命中缓存 |
|---|---|---|
| apt（含 ROS 源重签） | 2–3 min | 2–3 min |
| **OpenCV 3.4.2 + contrib(nonfree)** | **25–40 min** | 0 |
| cv_bridge 重编 | 2 min | 2 min |
| lab_5 + ci_tools | 1–2 min | 1–2 min |
| 图像对 ×4 / 视频 ×3 / 光流 | 3–5 min | 3–5 min |
| 合计 | **35–50 min** | **8–12 min** |

job 的 `timeout-minutes` 是 75，所以 40 分钟还在编 OpenCV 属于正常区间（4 vCPU、`-j4`）。
如果超过 60 分钟还在同一步，基本可以怀疑 OOM 或 `ExternalProject` 下载卡住。

## 已知还没做的

1. `report.md` 里的 **SURF 行**要等这一趟真编出 nonfree 版才有数（离线 Python 表缺这一行）。
2. 团队报告 PDF 等 `report.md` + `fig/` 出来再排版。
3. `docs/协作指南_Windows.md` 已经写好，可以直接发给两个队友。
