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
  local t0=$SECONDS
  if ( set -euo pipefail; "$@" ) 2>&1 | tee "$log"; then
    say "PASS $name ($((SECONDS - t0))s)"
    PASS+=("$name")
  else
    warn "FAIL $name ($((SECONDS - t0))s) —— 见 out/stage_${name}.log"
    FAIL+=("$name")
  fi
  cat "$log" >> "$OUT/console.log" || true
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
  ls /opt/ros/melodic/include/cv_bridge/cv_bridge.h >/dev/null && echo "cv_bridge 头文件: 有"
}

# =============================================================================
# S3 构建依赖工作区（OpenCV 3.4.2 + glog/gflags/catkin_simple）
# =============================================================================
s_build_deps() {
  if [ -f "$WS_DEPS/install/setup.bash" ] && \
     grep -q "$WS_DEPS" "$WS_DEPS/install/setup.bash" 2>/dev/null; then
    say "deps 缓存命中（$WS_DEPS/install 已就绪），跳过 OpenCV 编译"
    du -sh "$WS_DEPS/install"
    ls "$WS_DEPS/install/lib" | grep -c '^libopencv' | awk '{print "  已缓存 libopencv*.so : "$1" 个"}'
    return 0
  fi

  say "deps 缓存未命中 —— 开始编译（首次约 20 分钟）"
  rm -rf "$WS_DEPS"
  mkdir -p "$WS_DEPS/src"

  # 课程给的依赖（opencv3_catkin 已打 OPENCV_ENABLE_NONFREE=ON 的补丁）
  cp -r "$BUNDLE/dependencies/." "$WS_DEPS/src/"

  # rosinstall 里另外两个：catkin_simple / glog_catkin / gflags_catkin
  local try_clone
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
    --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS=-O2
  # catkin_simple 是 CMake 宏包，必须单独先建好
  catkin build catkin_simple -j1
  # OpenCV 的 ExternalProject 要下 ~120 MB 源码，超时设大一点
  catkin build -j"$(nproc)" --no-status --summarize
  cd "$ROOT"

  du -sh "$WS_DEPS/install"
  ls "$WS_DEPS/install/lib" | grep -c '^libopencv' | awk '{print "  libopencv*.so : "$1" 个"}'
  # SURF 能不能用，取决于这两个宏；编完立刻验一次
  grep -i "OPENCV_ENABLE_NONFREE" "$WS_DEPS/install/include/opencv2/opencv_modules.hpp" 2>/dev/null || true
  if ls "$WS_DEPS/install/include/opencv2/xfeatures2d" >/dev/null 2>&1; then
    say "xfeatures2d 头文件存在（SIFT/SURF 可用）"
  else
    warn "找不到 xfeatures2d 头文件 —— SURF 行会缺"
  fi
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
    --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS=-O2
  # 先编 cv_bridge，让后面的包链接到我们自己这份
  catkin build cv_bridge -j"$(nproc)" --no-status
  catkin build lab_5 ci_tools -j"$(nproc)" --no-status --summarize
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
    echo "- OpenCV: $("$WS_MAIN/devel/lib/ci_tools/mp4_to_bag" --help 2>&1 | head -1 || true)"
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
}

# =============================================================================
# S5 图像对（D3 / D4 / D5）：4 个描述子各跑一次官方 launch
# =============================================================================
s_pair() {
  . /opt/ros/melodic/setup.bash
  . "$WS_DEPS/install/setup.bash"
  . "$WS_MAIN/devel/setup.bash"

  local desc
  for desc in ${PAIR_DESCRIPTORS:-SIFT SURF ORB FAST}; do
    banner "图像对：descriptor:=$desc"
    # mode 0 跑完自己退出（interactive:=false 不阻塞）；300 s 只是兜底
    timeout -s INT 300 roslaunch lab_5 two_frames_tracking.launch \
      descriptor:="$desc" \
      output_dir:="$OUT/fig" \
      interactive:=false \
      2>&1 | tee "$OUT/pair_${desc}.log" || true
    echo "-------- 统计表（官方格式）--------"
    grep -E 'Avg\.|Num\. of samples' "$OUT/pair_${desc}.log" || \
      warn "$desc 没有打出统计 —— 见 out/pair_${desc}.log"
    if grep -qi "patented\|nonfree\|NONFREE" "$OUT/pair_${desc}.log"; then
      warn "$desc 报 nonfree 错误：OpenCV 没开 OPENCV_ENABLE_NONFREE"
    fi
  done
  ls -la "$OUT/fig" || true
}

# =============================================================================
# S6 视频序列（D6 / D7）：mp4 -> bag -> 官方 video_tracking.launch
# =============================================================================
s_video() {
  . /opt/ros/melodic/setup.bash
  . "$WS_DEPS/install/setup.bash"
  . "$WS_MAIN/devel/setup.bash"

  banner "mp4 -> rosbag"
  rosrun ci_tools mp4_to_bag "$ROOT/data/seq20s.mp4" "$OUT/seq20s.bag" \
    2>&1 | tee "$OUT/mp4_to_bag.log"
  rosbag info "$OUT/seq20s.bag" | tee "$OUT/bag_info.txt"

  local desc
  for desc in ${VIDEO_DESCRIPTORS:-LK SIFT ORB}; do
    banner "视频序列：descriptor:=$desc"
    # 20 s 的 bag，留 40 s 余量；到时用 SIGINT 结束，好让节点跑到 printStats
    timeout -s INT 90 roslaunch lab_5 video_tracking.launch \
      path_to_dataset:="$OUT/seq20s.bag" \
      descriptor:="$desc" \
      output_dir:="$OUT/fig" \
      interactive:=false \
      lk_save_every:=10 \
      2>&1 | tee "$OUT/video_${desc}.log" || true
    echo "-------- 视频累计统计 --------"
    grep -E 'Avg\.|Num\. of samples' "$OUT/video_${desc}.log" || \
      warn "$desc 视频模式没有打出统计"
  done
  ls -la "$OUT/fig" | head -40 || true
}

# =============================================================================
# S7 稠密光流（D8，可选加分）
# =============================================================================
s_flow() {
  . /opt/ros/melodic/setup.bash
  . "$WS_DEPS/install/setup.bash"
  . "$WS_MAIN/devel/setup.bash"

  banner "D8：Farneback 稠密光流"
  # self_flow 没有官方 launch，直接 rosrun + remap
  timeout -s INT 90 rosrun lab_5 self_flow \
      /images_topic:=/camera/color/image_raw \
      _interactive:=false \
      _output_dir:="$OUT/fig" \
      > "$OUT/self_flow.log" 2>&1 &
  local node_pid=$!

  rosbag play --clock "$OUT/seq20s.bag" \
    /tesse/left_cam/rgb/image_raw:=/camera/color/image_raw \
    2>&1 | tail -5 || true

  sleep 2
  kill -INT "$node_pid" 2>/dev/null || true
  wait "$node_pid" 2>/dev/null || true
  grep -E 'Saved figure|ERROR|error' "$OUT/self_flow.log" | head -10 || true
  ls -la "$OUT/fig" | grep -i flow || warn "没有稠密光流图"
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
