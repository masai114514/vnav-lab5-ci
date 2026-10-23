# LAB5 CI 运行报告

生成时间：2026-10-23 11:50:58（UTC）
- `GITHUB_REPOSITORY` = `masai114514/vnav-lab5-ci`
- `GITHUB_SHA` = `14f0dcda487fa1d2c927ea1365f7360b8b9ec0bc`
- `GITHUB_RUN_ID` = `39948600343`
- `GITHUB_REF_NAME` = `main`
- 通过的 stage：env, apt, build_deps, build_main, pair, self_flow
- **失败的 stage**：video

## 1. 图像对统计（D3 / D5）

官方 `two_frames_tracking.launch`，`images/box.png` + `images/box_in_scene.png`，`mode:=0`。

| 描述子 | kp1 | kp2 | 匹配数 | 良好匹配(Lowe 0.8) | 内点 | 内点率 | 样本数 | 备注 |
|---|---|---|---|---|---|---|---|---|
| SIFT | 603 | 969 | 603 | 98 | 76 | 77.6 % | 1 | 与官方 603/969/93/78 差 0 个 kp1 |
| SURF | 997 | 1822 | 997 | 138 | 91 | 65.9 % | 1 |  |
| ORB | 500 | 500 | 500 | 13 | 7 | 53.8 % | 1 |  |
| FAST | 2266 | 3653 | 2266 | 41 | 17 | 41.5 % | 1 |  |

> 官方参考解：603 / 969 / 93 / 78 / 83.9 %。本机复算：603 / 969 / 603 / 98 / 77.6 %。

## 2. 视频序列统计（D6 / D7）

测试序列：`data/seq20s.mp4` → `ci_tools/mp4_to_bag` → `seq20s.bag`（与 TESSE 同话题）。

```
path:        /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/out/seq20s.bag
version:     2.0
duration:    19.8s
start:       Jan 01 1970 00:00:01.00 (1.00)
end:         Jan 01 1970 00:00:20.83 (20.83)
size:        22.0 MB
messages:    240
compression: none [25/25 chunks]
types:       rosgraph_msgs/Clock [a9c97c1d230cfc112e270351a944ee47]
             sensor_msgs/Image   [060021388200f6f0f447d0fcd9c64743]
topics:      /clock                          120 msgs    : rosgraph_msgs/Clock
             /tesse/left_cam/rgb/image_raw   120 msgs    : sensor_msgs/Image
```

| 描述子 | kp1 | kp2 | 匹配数 | 良好匹配 | 内点 | 内点率 | 样本数 |
|---|---|---|---|---|---|---|---|
| LK | 72 | 64 | 64 | 64 | 44 | 71.4 % | 114 |

## 3. 可视化产物（D4 / D6 / D7 / D8）

共 46 张，全部在 `out/fig/`：

```
flow/self_flow_0000.png
flow/self_flow_0010.png
flow/self_flow_0020.png
flow/self_flow_0030.png
flow/self_flow_0040.png
flow/self_flow_0050.png
flow/self_flow_0060.png
flow/self_flow_0070.png
flow/self_flow_0080.png
flow/self_flow_0090.png
flow/self_flow_0100.png
flow/self_flow_0110.png
pair/fast_brief_keypoints_img1.png
pair/fast_brief_keypoints_img2.png
pair/fast_brief_matches_all_knn.png
pair/fast_brief_matches_good_lowe.png
pair/fast_brief_matches_inliers_outliers.png
pair/orb_keypoints_img1.png
pair/orb_keypoints_img2.png
pair/orb_matches_all_knn.png
pair/orb_matches_good_lowe.png
pair/orb_matches_inliers_outliers.png
pair/sift_keypoints_img1.png
pair/sift_keypoints_img2.png
pair/sift_matches_all_knn.png
pair/sift_matches_good_lowe.png
pair/sift_matches_inliers_outliers.png
pair/surf_keypoints_img1.png
pair/surf_keypoints_img2.png
pair/surf_matches_all_knn.png
pair/surf_matches_good_lowe.png
pair/surf_matches_inliers_outliers.png
video/lk_tracks_0000.png
video/lk_tracks_0010.png
video/lk_tracks_0020.png
video/lk_tracks_0030.png
video/lk_tracks_0040.png
video/lk_tracks_0050.png
video/lk_tracks_0060.png
video/lk_tracks_0070.png
video/lk_tracks_0080.png
video/lk_tracks_0090.png
video/lk_tracks_0100.png
video/lk_tracks_0110.png
video/orb_matches_inliers_outliers.png
video/sift_matches_inliers_outliers.png
```

## 4. 构建证据

```
# catkin build 证据

## 编译环境
- ROS: melodic
- gcc: 7
- OpenCV: #define CV_VERSION_MAJOR    3

## lab_5 产物
total 16
drwxr-xr-x 2 root root 4096 Oct 23 11:49 .
drwxr-xr-x 7 root root 4096 Oct 23 11:49 ..
lrwxrwxrwx 1 root root   92 Oct 23 11:49 self_flow -> /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_main/devel/.private/lab_5/lib/lab_5/self_flow
lrwxrwxrwx 1 root root   97 Oct 23 11:49 track_features -> /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_main/devel/.private/lab_5/lib/lab_5/track_features

## OpenCV 版本（运行时实际链接到的那一份）
	libopencv_core.so.3.4 => /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_deps/install/lib/libopencv_core.so.3.4 (0x00007fa1df400000)
	libopencv_highgui.so.3.4 => /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_deps/install/lib/libopencv_highgui.so.3.4 (0x00007fa1df000000)
	libopencv_imgcodecs.so.3.4 => /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_deps/install/lib/libopencv_imgcodecs.so.3.4 (0x00007fa1de800000)
	libopencv_calib3d.so.3.4 => /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_deps/install/lib/libopencv_calib3d.so.3.4 (0x00007fa1dc800000)
	libopencv_features2d.so.3.4 => /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_deps/install/lib/libopencv_features2d.so.3.4 (0x00007fa1dc400000)
	libopencv_flann.so.3.4 => /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_deps/install/lib/libopencv_flann.so.3.4 (0x00007fa1dc000000)
	libopencv_imgproc.so.3.4 => /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_deps/install/lib/libopencv_imgproc.so.3.4 (0x00007fa1d9600000)
	libopencv_video.so.3.4 => /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_deps/install/lib/libopencv_video.so.3.4 (0x00007fa1d9000000)

## cv_bridge 链接到的 OpenCV
	libopencv_imgcodecs.so.3.4 => /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_deps/install/lib/libopencv_imgcodecs.so.3.4 (0x00007f2d3b800000)
	libopencv_imgproc.so.3.4 => /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_deps/install/lib/libopencv_imgproc.so.3.4 (0x00007f2d38c00000)
	libopencv_core.so.3.4 => /home/runner/work/vnav-lab5-ci/vnav-lab5-ci/ws_deps/install/lib/libopencv_core.so.3.4 (0x00007f2d37c00000)
```

## 5. stage 明细

| stage | 结果 | 日志 |
|---|---|---|
| env | ✅ | `out/stage_env.log` |
| apt | ✅ | `out/stage_apt.log` |
| build_deps | ✅ | `out/stage_build_deps.log` |
| build_main | ✅ | `out/stage_build_main.log` |
| pair | ✅ | `out/stage_pair.log` |
| self_flow | ✅ | `out/stage_self_flow.log` |
| video | ❌ | `out/stage_video.log` |

