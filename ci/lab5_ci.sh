#!/usr/bin/env bash
# =============================================================================
# lab5_ci.sh —— LAB5（特征检测 / 描述 / 匹配 / LK 光流）的无头 CI 主脚本
#
# 为什么要有它
# ------------
# LAB5 交付物里有两样东西只能在「ROS1 + OpenCV 3.4.2（含 nonfree）」里跑出来：
#   ① D3/D5 的统计表（平均 keypoints / matches / inliers / inlier ratio）
#   ② D4/D6/D7 的可视化图（keypoints、good matches、内点/外点、LK 轨迹）
# 本机 macOS 装不了这套环境（原因见 docs/环境与踩坑.md），所以搬到 GitHub
# Actions 的 x86_64 runner + `ros:melodic` 容器里跑，和 lab3/lab4 同一套思路。
#
# 设计要点（每条都是踩过或预判过的坑，别随手改回去）
# ---------------------------------------------------------------
#  1. ROS1 的 apt 仓库 key 在 2025-06-01 过期 → 先重装 key 再 apt update，
#     否则 `apt-get update` 直接 GPG error，后面一步都跑不了。
#  2. OpenCV 3.4.2 从源码编 ≈ 20 分钟 → 用 actions/cache 缓存 ws_deps/install，
#     脚本靠「install/setup.bash 存在」判断命中，命中就整段跳过。
#  3. 系统的 cv_bridge 是链接 OpenCV 3.2 编出来的。让 lab_5 用 3.4.2 而 cv_bridge
#     用 3.2 是 ODR 违规（同一进程里两份 cv::Mat）。ethz-asl 的 opencv3_catkin
#     README 明确要求重编下游 → 从 vision_opencv 源码编 cv_bridge。
#  4. 官方 6b 数据集已从 GitHub 消失（LFS 404）→ 用 ci_tools/mp4_to_bag 把仓库里
#     自带的 mp4 打成同话题同类型的 bag，官方 video_tracking.launch 原样能跑。
#  5. runner 没有显示器 → 全部 interactive:=false，图由 saveImage /
#     lk_tracks_*.png 落盘，不靠窗口截图。
#  6. `bash x.sh | tee log` 的退出码来自 tee → workflow 里必须 set -o pipefail。
# =============================================================================
set -uo pipefail

ROOT="${GITHUB_WORKSPACE:-$PWD}"
BUNDLE="$ROOT/bundle"
OUT="$ROOT/out"
WS_DEPS="$ROOT/ws_deps"
WS_MAIN="$ROOT/ws_main"

mkdir -p "$OUT" "$OUT/fig"

PASS=()
FAIL=()

hr() { printf '\n%s\n' "------------------------------------------------------------------------"; }
banner() { hr; printf '## %s\n' "$*"; hr; }
say()  { printf '\033[1;36m[ci]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ci]\033[0m %s\n' "$*"; }

# 跑一个 stage：日志同时进 out/stage_<name>.log 与 out/console.log。
# 失败只记账，不中断 —— 一趟 25 分钟的机器时间不该因为最后一个测试挂掉就白跑。
stage() {
  local name="$1"; shift
  banner "STAGE $name : $*"
  local log="$OUT/stage_${name}.log"
  local t0=$SECONDS rc=0
  # 退出码必须取 PIPESTATUS[0]（= 子 shell），不能取整条管道的状态：
  # 管道最后一个是 `tee`，它永远成功。Run #2 里 lab_5 的 cmake 明明失败、
  # track_features 根本没编出来，四个 stage 却全报 PASS，就栽在这里。
  set +e
  ( set -euo pipefail; "$@" ) 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -eq 0 ]; then
    say "PASS $name ($((SECONDS - t0))s)"
    PASS+=("$name")
  else
    warn "FAIL $name ($((SECONDS - t0))s, rc=$rc) —— 见 out/stage_${name}.log"
    FAIL+=("$name")
  fi
  cat "$log" >> "$OUT/console.log" || true
  return 0
}

# 运行时前置检查：没有 track_features 就什么都跑不了。
# 别让 roslaunch 在那儿干等 120 s 再被 timeout 杀掉 —— Run #2 里四个描述子
# 白烧了 20 分钟，日志里全是 "cannot launch node of type [lab_5/track_features]"。
need_bin() {
  local bin="$1"
  if [ ! -x "$bin" ]; then
    echo "✗ 缺少可执行文件：$bin" >&2
    echo "  lab_5 没编过 —— 先看 out/stage_build_main.log 里的 cmake 报错" >&2
    return 1
  fi
  return 0
}

# =============================================================================
# S1 环境信息
# =============================================================================
s_env() {
  echo "vCPU     = $(nproc)"
  free -m | awk '/Mem:/{printf "内存     = %s MB\n", $2}'
  grep -E '^(PRETTY_NAME|VERSION_CODENAME)' /etc/os-release || true
  echo "ROOT     = $ROOT"
  echo "catkin   = $(command -v catkin || echo '(没有 catkin_tools)')"
  echo "cmake    = $(cmake --version | head -1)"
  echo "gcc      = $(gcc -dumpversion)"
  echo "--- 已装的 ROS 包数: $(ls /opt/ros/melodic/share 2>/dev/null | wc -l)"
}

# =============================================================================
# S2 apt：修 key + 装依赖
# =============================================================================
s_apt() {
  export DEBIAN_FRONTEND=noninteractive
  local codename
  codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-bionic}}")"
  say "发行版代号 = $codename"

  # 第 1 步：ROS 仓库 key（2025-06-01 过期）
  if ! apt-get update -qq >/dev/null 2>&1; then
    warn "apt-get update 失败 —— 重装 ROS key 并重写源"
    mkdir -p /usr/share/keyrings
    curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
      -o /usr/share/keyrings/ros-archive-keyring.gpg
    rm -f /etc/apt/sources.list.d/ros1-latest.list \
          /etc/apt/sources.list.d/ros-latest.list
    echo "deb [signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros/ubuntu ${codename} main" \
      > /etc/apt/sources.list.d/ros1-latest.list
    if ! apt-get update -qq; then
      warn "仍失败 —— 把 Ubuntu 源切到 old-releases 再试"
      sed -i -e 's|http://archive.ubuntu.com|http://old-releases.ubuntu.com|g' \
             -e 's|http://security.ubuntu.com|http://old-releases.ubuntu.com|g' \
             /etc/apt/sources.list
      apt-get update -qq
    fi
  fi
  say "apt update OK"

  apt-get install -y -qq --no-install-recommends \
    build-essential cmake git curl patch pkg-config \
    autoconf automake libtool m4 \
    python-dev python-numpy python-catkin-pkg python-empy python-nose \
    python-catkin-tools \
    libboost-python-dev libboost-system-dev libboost-thread-dev libboost-filesystem-dev \
    libtbb-dev libgtk2.0-dev \
    libjpeg-dev libpng-dev libtiff-dev \
    libavcodec-dev libavformat-dev libswscale-dev libv4l-dev \
    ros-melodic-cv-bridge ros-melodic-image-transport ros-melodic-rosbag \
    xvfb x11-utils imagemagick ffmpeg 2>&1 | tail -20

  say "---------- 关键依赖版本 ----------"
  python --version 2>&1 || true
  catkin --version 2>&1 | head -2 || true
  if [ -f /opt/ros/melodic/include/cv_bridge/cv_bridge.h ]; then
    echo "cv_bridge 头文件: 有"
  fi
}

# =============================================================================
# S3 构建依赖工作区（OpenCV 3.4.2 + glog/gflags/catkin_simple）
# =============================================================================

# 某个依赖有没有真的产出 CMake config。
# 不用 `find | grep -q`：grep 提前退出会给 find 送 SIGPIPE，pipefail 下变成 141。
dep_ok() {
  local f
  f="$(find "$WS_DEPS/install" -name "$1Config.cmake" -print -quit 2>/dev/null)"
  [ -n "$f" ]
}

# 缓存里的依赖工作区是否「真的」可用 —— 必须是四项 Config + libopencv 全在。
#
# 只看 install/setup.bash 会误判。实际踩到的：Run #3 在 10:37 起、10:38:59 被
# concurrency 取消，它的 `actions/cache/save`（当时挂在 always() 上）把刚建了一半的
# ws_deps/install（只有 catkin_simple，**120 KB**）存成了正式 key。Run #4 于是
# restore 报 cache-hit=true —— 但那份东西连 OpenCV 都没有，脚本只好重编 12 分钟，
# 而 save 又因为 cache-hit=true 被跳过，等于永远修不好。所以命中判定必须够严。
deps_ready() {
  [ -f "$WS_DEPS/install/setup.bash" ] || return 1
  ls "$WS_DEPS/install/lib"/libopencv_core.so* >/dev/null 2>&1 || return 1
  local d
  for d in opencv3_catkin glog_catkin gflags_catkin catkin_simple; do
    dep_ok "$d" || return 1
  done
  return 0
}

s_build_deps() {
  if deps_ready; then
    say "deps 缓存命中（$WS_DEPS/install 已就绪），跳过 OpenCV 编译"
    du -sh "$WS_DEPS/install"
    # catkin_tools 的 --extend 要找这个标记文件，cache 没存到就补一个
    touch "$WS_DEPS/install/.catkin"
    ls "$WS_DEPS/install/lib" 2>/dev/null | grep -c '^libopencv' \
      | awk '{print "  已缓存 libopencv*.so : "$1" 个"}' || true
    return 0
  fi

  if [ -f "$WS_DEPS/install/setup.bash" ]; then
    warn "缓存里的 install 不完整（半成品，见 deps_ready 注释）—— 丢掉重建"
  fi
  say "deps 缓存未命中 —— 开始编译（首次约 20 分钟）"
  rm -rf "$WS_DEPS"
  mkdir -p "$WS_DEPS/src"

  # 课程给的依赖（opencv3_catkin 已打 OPENCV_ENABLE_NONFREE=ON 的补丁）
  cp -r "$BUNDLE/dependencies/." "$WS_DEPS/src/"

  # rosinstall 里另外三个：catkin_simple / glog_catkin / gflags_catkin
  try_clone() {
    local url="$1" dest="$2" branch="${3:-master}"
    for i in 1 2 3; do
      if git clone --depth 1 --branch "$branch" "$url" "$dest" 2>/dev/null \
         || git clone --depth 1 "$url" "$dest" 2>/dev/null; then
        return 0
      fi
      warn "clone 失败（第 $i 次）：$url"
      rm -rf "$dest"
      sleep 5
    done
    return 1
  }
  try_clone https://github.com/catkin/catkin_simple.git   "$WS_DEPS/src/catkin_simple"
  try_clone https://github.com/ethz-asl/glog_catkin.git   "$WS_DEPS/src/glog_catkin"
  try_clone https://github.com/ethz-asl/gflags_catkin.git "$WS_DEPS/src/gflags_catkin"

  # 2 vCPU 上 `make -j8` 会把内存打爆（imgproc 的单个 TU 就要 1 GB+）
  sed -i 's/make -j8/make -j$(nproc)/g' "$WS_DEPS/src/opencv3_catkin/CMakeLists.txt"
  grep -n 'OPENCV_ENABLE_NONFREE\|make -j' "$WS_DEPS/src/opencv3_catkin/CMakeLists.txt"

  cd "$WS_DEPS"
  catkin config --install --extend /opt/ros/melodic \
    --cmake-args -DCMAKE_BUILD_TYPE=Release
  # catkin_simple 是 CMake 宏包，必须单独先建好
  catkin build catkin_simple -j1
  # OpenCV 的 ExternalProject 要下 ~120 MB 源码，超时设大一点。
  # 不用 `set -e` 直接中断：glog 挂了也要把 OpenCV 编完（它是 20 分钟的大头），
  # 后面再用 shim 兜 glog，这样下一趟缓存还能命中。
  local rc_deps=0
  catkin build -j"$(nproc)" --no-status --summarize || rc_deps=$?
  cd "$ROOT"

  # ---------- 校验四个依赖真的产出了 CMake config ----------
  # 只看 install/setup.bash 是否存在是不够的：Run #2 里 glog_catkin 编译失败
  # （bionic 缺 autoreconf），setup.bash 照样生成，于是 deps 被误判为成功，
  # 一路拖到 s_build_main 才炸在 `Could not find glog_catkin`。
  local missing=() d
  for d in opencv3_catkin glog_catkin gflags_catkin catkin_simple; do
    if dep_ok "$d"; then
      echo "  ✓ $d"
    else
      echo "  ✗ $d  （没有 $dConfig.cmake）"
      missing+=("$d")
    fi
  done

  # ---------- glog 兜底 ----------
  # lab_5 的源码里其实一行 glog 都没用（grep 过），只是 CMakeLists 里
  # find_package(glog_catkin) + 链接 ${catkin_LIBRARIES}。所以 glog_catkin
  # 用官方源码编不出来时，用系统 glog（bionic 正好也是 0.3.5）做一个同名
  # shim 包，接口等价、3 秒建好，完全不碰课程给的源。
  if printf '%s\n' "${missing[@]:-}" | grep -qx glog_catkin; then
    warn "glog_catkin 没编出来 —— 改用系统 libgoogle-glog-dev 的同名 shim"
    apt-get install -y -qq --no-install-recommends libgoogle-glog-dev 2>&1 | tail -3
    # 源目录、build/、logs/ 三处都要清，否则 catkin 会沿用上次失败的缓存
    rm -rf "$WS_DEPS/src/glog_catkin" \
           "$WS_DEPS/build/glog_catkin" \
           "$WS_DEPS/logs/glog_catkin"
    mkdir -p "$WS_DEPS/src/glog_catkin_shim"
    cat > "$WS_DEPS/src/glog_catkin_shim/package.xml" <<'XML'
<?xml version="1.0"?>
<package format="2">
  <name>glog_catkin</name>
  <version>0.3.5</version>
  <description>CI shim: 用系统 libgoogle-glog 冒充 ethz-asl/glog_catkin</description>
  <maintainer email="ci@example.com">ci</maintainer>
  <license>BSD</license>
  <buildtool_depend>catkin</buildtool_depend>
</package>
XML
    cat > "$WS_DEPS/src/glog_catkin_shim/CMakeLists.txt" <<'CMK'
cmake_minimum_required(VERSION 3.0.2)
project(glog_catkin)
find_package(catkin REQUIRED)
find_library(GLOG_LIBRARY NAMES glog REQUIRED)
catkin_package(INCLUDE_DIRS /usr/include LIBRARIES ${GLOG_LIBRARY})
CMK
    cd "$WS_DEPS"
    catkin build glog_catkin -j1 --no-status --force-cmake || true
    cd "$ROOT"
    if dep_ok glog_catkin; then
      say "glog shim 生效"
      missing=("${missing[@]/glog_catkin/}")
    fi
  fi

  # 剩下还缺的就是真问题（尤其 opencv3_catkin），如实报错
  local still=()
  for d in "${missing[@]:-}"; do
    [ -n "$d" ] && still+=("$d")
  done
  if [ "${#still[@]}" -gt 0 ]; then
    echo "✗ 依赖缺失：${still[*]}（catkin build 退出码 $rc_deps）" >&2
    return 1
  fi

  # catkin_tools 的 --extend 会验证目标是个 catkin 空间（找 .catkin 标记文件）；
  # 缺了它 s_build_main 会直接报 "Unable to find catkin config file"。
  touch "$WS_DEPS/install/.catkin"
  test -f "$WS_DEPS/install/setup.bash" || {
    echo "install/setup.bash 没生成 —— catkin --install 没生效" >&2
    return 1
  }

  du -sh "$WS_DEPS/install"
  ls "$WS_DEPS/install/lib" 2>/dev/null | grep -c '^libopencv' \
    | awk '{print "  libopencv*.so : "$1" 个"}' || true
  # SURF 能不能用，取决于这两个宏；编完立刻验一次
  grep -i "OPENCV_ENABLE_NONFREE" "$WS_DEPS/install/include/opencv2/opencv_modules.hpp" 2>/dev/null || true
  if ls "$WS_DEPS/install/include/opencv2/xfeatures2d" >/dev/null 2>&1; then
    say "xfeatures2d 头文件存在（SIFT/SURF 可用）"
  else
    warn "找不到 xfeatures2d 头文件 —— SURF 行会缺"
  fi

  # 给 workflow 用的「可缓存」标记：只有这一趟**真的从源码编出来、且四项都验过**
  # 才写。半成品（比如被 concurrency 取消的 run）没有这个文件，cache/save 那步
  # 就不会执行，避免再出现「命中的是 120 KB 半成品」那种事。
  : > "$OUT/.deps_fresh"
  say "已标记 deps 可缓存（out/.deps_fresh）"
  return 0
}

# =============================================================================
# S4 构建主工作区（cv_bridge 重编 + lab_5 + ci_tools）
# =============================================================================
s_build_main() {
  rm -rf "$WS_MAIN"
  mkdir -p "$WS_MAIN/src"

  cp -r "$BUNDLE/feature_tracking" "$WS_MAIN/src/lab_5"
  cp -r "$ROOT/ci/ci_tools"        "$WS_MAIN/src/ci_tools"

  # cv_bridge 必须跟着 OpenCV 3.4.2 重编（见文件头第 3 条）
  rm -rf /tmp/vision_opencv
  git clone --depth 1 --branch melodic \
    https://github.com/ros-perception/vision_opencv.git /tmp/vision_opencv \
    || git clone --depth 1 https://github.com/ros-perception/vision_opencv.git /tmp/vision_opencv
  cp -r /tmp/vision_opencv/cv_bridge "$WS_MAIN/src/cv_bridge"

  cd "$WS_MAIN"
  catkin config --extend "$WS_DEPS/install" \
    --cmake-args -DCMAKE_BUILD_TYPE=Release
  # 先编 cv_bridge，让后面的包链接到我们自己这份
  catkin build cv_bridge -j"$(nproc)" --no-status
  local rc_build=0
  catkin build lab_5 ci_tools -j"$(nproc)" --no-status --summarize || rc_build=$?
  cd "$ROOT"

  say "---------- 编出来的可执行文件 ----------"
  ls -la "$WS_MAIN/devel/lib/lab_5/" || true
  ls -la "$WS_MAIN/devel/lib/ci_tools/" || true

  # 真编过就留证据给报告
  {
    echo "# catkin build 证据"
    echo
    echo "## 编译环境"
    echo "- ROS: $(. /opt/ros/melodic/setup.bash && echo "$ROS_DISTRO")"
    echo "- gcc: $(gcc -dumpversion)"
    echo "- OpenCV: $(grep -h 'define CV_VERSION' "$WS_DEPS/install/include/opencv2/core/version.hpp" 2>/dev/null | sed 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/' | head -1)"
    echo
    echo "## lab_5 产物"
    ls -la "$WS_MAIN/devel/lib/lab_5/"
    echo
    echo "## OpenCV 版本（运行时实际链接到的那一份）"
    LD_LIBRARY_PATH="$WS_DEPS/install/lib:$WS_MAIN/devel/lib" \
      ldd "$WS_MAIN/devel/lib/lab_5/track_features" | grep -i opencv | head -8
    echo
    echo "## cv_bridge 链接到的 OpenCV"
    ldd "$WS_MAIN/devel/lib/libcv_bridge.so" 2>/dev/null | grep -i opencv | head -4 || true
  } > "$OUT/build_evidence.txt" 2>&1
  cat "$OUT/build_evidence.txt"

  # 编译是否真的成功，只认这个文件在不在 —— 不认 catkin 的退出码，
  # 也不认 devel/lib 里有没有别的包（ci_tools 编过不代表 lab_5 编过）。
  if [ ! -x "$WS_MAIN/devel/lib/lab_5/track_features" ]; then
    echo "✗ lab_5/track_features 没编出来（catkin 退出码 $rc_build）" >&2
    echo "  完整 cmake/make 日志：ws_main/logs/lab_5/" >&2
    return 1
  fi
  return "$rc_build"
}

# =============================================================================
# S5 图像对（D3 / D4 / D5）：4 个描述子各跑一次官方 launch
# =============================================================================
s_pair() {
  . /opt/ros/melodic/setup.bash
  . "$WS_DEPS/install/setup.bash"
  . "$WS_MAIN/devel/setup.bash"

  need_bin "$WS_MAIN/devel/lib/lab_5/track_features" || return 1

  local desc rc bad=0
  for desc in ${PAIR_DESCRIPTORS:-SIFT SURF ORB FAST}; do
    banner "图像对：descriptor:=$desc"
    # mode 0 跑完自己退出（interactive:=false 不阻塞）；120 s 只是兜底
    rc=0
    timeout -s INT 120 roslaunch lab_5 two_frames_tracking.launch \
      descriptor:="$desc" \
      output_dir:="$OUT/fig" \
      interactive:=false \
      2>&1 | tee "$OUT/pair_${desc}.log" || rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 130 ]; then
      warn "$desc 超时（120 s）—— 多半是 interactive 没生效或 roslaunch 挂住了"
      bad=1
    fi
    echo "-------- 统计表（官方格式）--------"
    if grep -E 'Avg\.|Num\. of samples' "$OUT/pair_${desc}.log"; then
      :
    else
      warn "$desc 没有打出统计 —— 见 out/pair_${desc}.log"
      sed -n '$p' "$OUT/pair_${desc}.log" || true
      bad=1
    fi
    if grep -qi "patented\|nonfree" "$OUT/pair_${desc}.log"; then
      warn "$desc 报 nonfree 错误：OpenCV 没开 OPENCV_ENABLE_NONFREE"
    fi
  done
  ls -la "$OUT/fig" || true
  return "$bad"
}

# =============================================================================
# S6 视频序列（D6 / D7）：mp4 -> bag -> 官方 video_tracking.launch
# =============================================================================
s_video() {
  . /opt/ros/melodic/setup.bash
  . "$WS_DEPS/install/setup.bash"
  . "$WS_MAIN/devel/setup.bash"

  need_bin "$WS_MAIN/devel/lib/lab_5/track_features" || return 1

  banner "mp4 -> rosbag"
  local rc=0
  rosrun ci_tools mp4_to_bag "$ROOT/data/seq20s.mp4" "$OUT/seq20s.bag" \
    2>&1 | tee "$OUT/mp4_to_bag.log" || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$OUT/seq20s.bag" ]; then
    echo "✗ mp4_to_bag 失败（rc=$rc）—— 后面三个描述子都跑不了" >&2
    return 1
  fi
  # 坏包在这里就拦住：unindexed 的 bag 会让 rosbag play 报 ERROR 后行为不可预期，
  # Run #2 里 s_flow 就是被一个坏包拖了 37 分钟。
  # 先落盘再 grep：`... | tee f | grep -q` 里 grep 提前退出会让 tee 吃 SIGPIPE，
  # pipefail 下整条管道变成 141，误判成 bag 坏了。
  rc=0
  timeout -s INT 60 rosbag info "$OUT/seq20s.bag" > "$OUT/bag_info.txt" 2>&1 || rc=$?
  cat "$OUT/bag_info.txt"
  if [ "$rc" -ne 0 ] || ! grep -qE 'messages:[[:space:]]*[0-9]+' "$OUT/bag_info.txt"; then
    echo "✗ bag 打不开或没有消息（rc=$rc，可能是 unindexed）" >&2
    return 1
  fi

  local desc bad=0
  for desc in ${VIDEO_DESCRIPTORS:-LK SIFT ORB}; do
    banner "视频序列：descriptor:=$desc"
    # 20 s 的 bag，留足余量；到时用 SIGINT 结束，好让节点跑到 printStats
    rc=0
    timeout -s INT 120 roslaunch lab_5 video_tracking.launch \
      path_to_dataset:="$OUT/seq20s.bag" \
      descriptor:="$desc" \
      output_dir:="$OUT/fig" \
      interactive:=false \
      lk_save_every:=10 \
      2>&1 | tee "$OUT/video_${desc}.log" || rc=$?
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 130 ]; then
      warn "$desc 超时（120 s）"
    fi
    echo "-------- 视频累计统计 --------"
    if grep -E 'Avg\.|Num\. of samples' "$OUT/video_${desc}.log"; then
      :
    else
      warn "$desc 视频模式没有打出统计"
      bad=1
    fi
  done
  ls -la "$OUT/fig" | head -40 || true
  return "$bad"
}

# =============================================================================
# S7 稠密光流（D8，可选加分）
# =============================================================================
s_flow() {
  . /opt/ros/melodic/setup.bash
  . "$WS_DEPS/install/setup.bash"
  . "$WS_MAIN/devel/setup.bash"

  need_bin "$WS_MAIN/devel/lib/lab_5/self_flow" || return 1
  if [ ! -s "$OUT/seq20s.bag" ]; then
    echo "✗ 没有 seq20s.bag（s_video 没跑成）—— 光流没有输入" >&2
    return 1
  fi

  banner "D8：Farneback 稠密光流"
  # self_flow 没有官方 launch，直接 rosrun + remap。
  # ⚠️ 这里每一步都必须有硬超时：Run #2 里这一步整整挂了 37 分钟，
  #    一直挂到 job 的 75 分钟上限被 GitHub 取消（连带 OpenCV 缓存也没存成）。
  rm -f "$OUT/self_flow.log"
  timeout -s INT 120 rosrun lab_5 self_flow \
      /images_topic:=/camera/color/image_raw \
      _interactive:=false \
      _output_dir:="$OUT/fig" \
      > "$OUT/self_flow.log" 2>&1 &
  local node_pid=$!

  local rc=0
  timeout -s INT 150 rosbag play --clock -r 2 "$OUT/seq20s.bag" \
    /tesse/left_cam/rgb/image_raw:=/camera/color/image_raw \
    > "$OUT/rosbag_play_flow.log" 2>&1 || rc=$?
  tail -5 "$OUT/rosbag_play_flow.log" || true

  # 给节点留 3 s 收尾（写最后一张图），然后最多等 20 s 让它自然退出，
  # 不退出就 KILL —— 绝不再出现「wait 等一个不响应的进程」。
  sleep 3
  local i
  for i in $(seq 1 20); do
    kill -0 "$node_pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$node_pid" 2>/dev/null; then
    warn "self_flow 20 s 内没退出，强制结束"
    kill -INT "$node_pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$node_pid" 2>/dev/null || true
  fi
  wait "$node_pid" 2>/dev/null || true

  grep -E 'Saved figure|ERROR|error' "$OUT/self_flow.log" | head -10 || true
  if ls "$OUT/fig" | grep -qi flow; then
    ls -la "$OUT/fig" | grep -i flow
    return 0
  fi
  warn "没有稠密光流图（rosbag play rc=$rc）"
  return 1
}

# =============================================================================
# S8 汇总
# =============================================================================
s_summary() {
  local py
  py="$(command -v python3 || command -v python)"
  "$py" "$ROOT/ci/summarize.py" \
    --out "$OUT" \
    --pass "$(IFS=,; echo "${PASS[*]:-}")" \
    --fail "$(IFS=,; echo "${FAIL[*]:-}")" 2>&1 | tee "$OUT/stage_summary.log"
}

# =============================================================================
main() {
  stage env          s_env
  stage apt          s_apt
  stage build_deps   s_build_deps
  stage build_main   s_build_main
  stage pair         s_pair
  stage video        s_video
  stage self_flow    s_flow
  stage summary      s_summary

  hr
  if [ "${#FAIL[@]}" -eq 0 ]; then
    say "全部 stage 通过：${PASS[*]}"
    return 0
  fi
  warn "有 stage 失败：${FAIL[*]}"
  warn "（产物与日志仍然全部上传，见 artifact）"
  # 让 workflow 变红，但不要因为「某个描述子挂了」就丢掉别的产物
  return 1
}

main
exit $?
