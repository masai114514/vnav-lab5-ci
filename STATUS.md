# CI 当前状态 / 回来先看这里

**更新时间**：2026-10-23 20:05（本地） / 12:05 UTC

## ✅ 已全绿：Run #11（`39949517530`，commit `2cfbc4c5`）

7 个 stage 全部 PASS，46 张图、4 个描述子的图像对与视频统计全部产出。
结果整理见 `../docs/结果汇总.md`，原始产物在 `ci_runs/39949517530/lab5-results/`。

| stage | 结果 | 说明 |
|---|---|---|
| env / apt | ✅ | melodic + autotools |
| build_deps | ✅ | OpenCV 3.4.2 缓存命中（109 MB、75 个 so），跳过重编 |
| build_main | ✅ | lab_5 + cv_bridge 从源码编译 |
| pair | ✅ | SIFT 603/969/98/76、SURF 997/1822/138/91、ORB 500/500/13/7、FAST 2266/3653/41/17 |
| video | ✅ | LK / SIFT / ORB 各 115–118 样本 |
| self_flow | ✅ | 12 张稠密光流图 |
| summary | ✅ | report.md |

从 75 分钟跑到失败 → 7 分钟跑完全绿，共 11 次运行。下面保留排错全过程，供报告「遇到的问题」引用。

## Run #2 结论：没跑成，但把 4 个真问题全暴露出来了

| Run | 结果 | 说明 |
|---|---|---|
| #1 `39894039688` | 35 s 失败 | job 级 `container:` 在 melodic 上必挂（glibc 2.27 < Node24 要的 2.28） |
| #2 `39894286741` | **75 min 超时被取消** | 见下，四个坑连环 |
| #3 / #4 | 修复后重跑 | `39940527178` |

Run #2 的时间线（很有信息量）：

```
03:18 开始
03:31 build_deps 结束   ← OpenCV 3.4.2 + contrib 只用 13 分钟，不是瓶颈
03:31 build_main 失败   ← ✗ Could not find glog_catkin
03:31→03:51 pair        ← 4 个描述子 × 300 s 干等，全是 "cannot launch node"
03:51→03:56 video       ← mp4_to_bag 抛异常，bag unindexed
03:56→04:33 self_flow   ← 挂了 37 分钟，直到 job 75 分钟上限被杀
```

## 四个根因 & 修法

### 1. `glog_catkin` 编不出来 → lab_5 的 cmake 直接失败 → 没有 `track_features`

```
/bin/sh: 1: autoreconf: not found
make[2]: *** [glog_src-prefix/.../glog_src-configure] Error 127
```

ethz-asl 的 `glog_catkin` 会 `autoreconf` 一遍 glog 0.3.5 源码，而 `ros:melodic-ros-base`
镜像里没有 autotools。**修**：apt 加 `autoconf automake libtool m4`；万一还不行，
脚本会自动退到「用系统 `libgoogle-glog-dev`（bionic 也是 0.3.5）生成一个同名 shim 包」。
—— lab_5 的源码里一行 glog 都没用（`grep -rn "glog\|LOG("` 无结果），只是 CMakeLists
里 `find_package` 它，所以 shim 在语义上等价。

### 2. `mp4_to_bag` 第一帧的时间戳是 0 → rosbag 抛异常 → 留下 unindexed 坏包

```
terminate called after throwing an instance of 'rosbag::BagException'
  what():  Tried to insert a message with time less than ros::TIME_MIN
```

`rosbag::Bag::write` 要求 `time >= ros::TIME_MIN`（= 1 ns），我原来从 0 起算。
异常又让 `bag.close()` 没执行 → 没写索引 → 下游 `rosbag play` 直接拒开。
**修**：起点挪到 1 s（`ros::Time(1,0) + Duration(count*period)`），并 `try/catch` 保证
异常路径也 `close()`。

### 3. `stage()` 的退出码被 `tee` 吞掉 → 全线误报 PASS

```bash
if ( set -euo pipefail; "$@" ) 2>&1 | tee "$log"; then   # ← 取的是 tee 的状态
```

所以 `build_main` 明明 cmake 失败、`pair` 四个描述子一个都没跑成，日志里却写着
`PASS build_main (20s)` / `PASS pair (1203s)`。**修**：`rc=${PIPESTATUS[0]}`。

另外每个 stage 现在有自己的**成功判据**，不只是退出码：

- `build_deps`：四个依赖的 `*Config.cmake` 都必须存在
- `build_main`：`devel/lib/lab_5/track_features` 必须是可执行文件
- `pair` / `video`：必须从日志里 grep 到 `Avg.` 统计行
- `self_flow`：必须产出 `*flow*.png`

### 4. 缺节点 + 坏 bag = 无限期干等

`roslaunch` 找不到 node 不会退出，它把 master 挂着等，只能被 `timeout` 砍。
Run #2 因此白烧 20 分钟（pair）+ 37 分钟（self_flow）。
**修**：
- 所有运行时 stage 开头 `need_bin`：没有可执行文件就立刻 `return 1`（毫秒级）
- `rosbag info` 先校验 `messages: N`，坏包在 `s_video` 就拦住
- `self_flow` 的每个外部进程都有硬超时（node 120 s / play 150 s / 收尾最多 20 s 后 KILL）

顺带：`actions/cache` 的保存钩子是 `post-if: success()`，job 一失败 **25 分钟编译白烧**。
已改成 `actions/cache/restore` + 独立的 `actions/cache/save`（`if: always()`），
所以这趟无论成败，OpenCV 都会进缓存。

## 下一趟怎么验

```bash
gh run list --repo masai114514/vnav-lab5-ci --limit 3
./fetch_artifacts.sh            # 落到 ci_runs/<run_id>/
```

期望看到：

| stage | 判据 |
|---|---|
| `build_deps` | `✓ opencv3_catkin ✓ glog_catkin ✓ gflags_catkin ✓ catkin_simple` |
| `build_main` | `devel/lib/lab_5/` 下有 `track_features` 和 `self_flow` |
| `pair` | 四段 `Avg. Keypoints 1 Size: 604` / `969` / `94` / `80` / `0.851`（SIFT，与官方 603/969/93/78/83.9% 差 ≤2） |
| `video` | `Avg.` 累计统计 + `fig/lk_tracks_*.png` |
| `self_flow` | `fig/*flow*.png` |

## 时间账（用来判断卡没卡死）

| 阶段 | 首次（无缓存） | 命中缓存 |
|---|---|---|
| apt | 2–3 min | 2–3 min |
| **OpenCV 3.4.2 + contrib(nonfree)** | **13 min**（实测） | 0 |
| cv_bridge + lab_5 + ci_tools | 1 min | 1 min |
| pair ×4 | 1 min | 1 min |
| video ×3 | 6 min | 6 min |
| self_flow | 3 min | 3 min |
| 合计 | **26 min 左右** | **13 min 左右** |

## 已知还没做的

1. `report.md` 里 **SURF 行**要等真编出 nonfree 版才有数。
2. 团队报告 PDF 等 `report.md` + `fig/` 出来再排。
3. `docs/协作指南_Windows.md` 已写好，可直接发给两个队友。
