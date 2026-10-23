// ci/mp4_to_bag.cpp —— 把 mp4 逐帧写进一个 ROS1 rosbag
//
// 目的：官方 6b 的两个数据集已从 GitHub 消失（LFS 对象 404，见 docs/环境与踩坑.md §2）。
// 这个工具把任意 mp4 打成与 TESSE 完全同话题、同消息类型的 bag，于是
// `roslaunch lab_5 video_tracking.launch path_to_dataset:=<bag>` 可以原样跑，
// 不需要改官方 launch 里的任何一行。
//
// 为什么用 C++ 而不是 python：
//   melodic 是 python2，而能写 ROS1 bag 的 python 库（rosbags）要求 python3.7+，
//   在 bionic 上 pip 装会拖进一堆新版本依赖。ROS 自带 rosbag 的 C++ API 零依赖。
//
// 用法：
//   rosrun ci_tools mp4_to_bag <video.mp4> <out.bag> [topic] [fps]
//   topic 默认 /tesse/left_cam/rgb/image_raw（与官方 launch 的 remap 对齐）
//   fps   默认用视频自带帧率
//
// 时间戳从 1 s 起（rosbag 拒绝 < ros::TIME_MIN 的消息），同时写入 /clock，
// 这样 `roslaunch ... --clock` 的 use_sim_time 链路才成立。

#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>

#include <opencv2/core.hpp>
#include <opencv2/videoio.hpp>
#include <opencv2/imgproc.hpp>

#include <ros/ros.h>
#include <rosbag/bag.h>
#include <sensor_msgs/Image.h>
#include <rosgraph_msgs/Clock.h>

int main(int argc, char** argv) {
  ros::init(argc, argv, "mp4_to_bag");

  if (argc < 3) {
    std::fprintf(stderr,
                 "usage: %s <video> <out.bag> [topic] [fps]\n", argv[0]);
    return 1;
  }

  const std::string video_path = argv[1];
  const std::string bag_path = argv[2];
  const std::string topic =
      (argc > 3) ? argv[3] : "/tesse/left_cam/rgb/image_raw";

  cv::VideoCapture cap(video_path);
  if (!cap.isOpened()) {
    std::fprintf(stderr, "[mp4_to_bag] 打不开视频: %s\n", video_path.c_str());
    return 1;
  }

  double fps = (argc > 4) ? std::atof(argv[4]) : cap.get(cv::CAP_PROP_FPS);
  if (!(fps > 1e-3)) {
    fps = 30.0;
  }

  rosbag::Bag bag;
  bag.open(bag_path, rosbag::bagmode::Write);

  cv::Mat frame;
  int count = 0;
  int width = 0, height = 0;
  const double period = 1.0 / fps;

  // rosbag::Bag::write 拒绝 time < ros::TIME_MIN（即 (1,0)，1 纳秒）的消息。
  // 原来从 0 起算，第一帧就抛 "Tried to insert a message with time less than
  // ros::TIME_MIN"，然后因为异常没走到 bag.close()，留下一个 unindexed 的坏包。
  // 起点挪到 1 s：既满足 TIME_MIN，又给 rosbag play 留出前导时间。
  const ros::Time t0(1, 0);

  try {
  while (cap.read(frame)) {
    if (frame.empty()) {
      break;
    }
    if (!frame.isContinuous()) {
      frame = frame.clone();
    }
    width = frame.cols;
    height = frame.rows;

    const ros::Time stamp = t0 + ros::Duration(count * period);

    sensor_msgs::Image img;
    img.header.stamp = stamp;
    img.header.frame_id = "camera";
    img.height = static_cast<uint32_t>(height);
    img.width = static_cast<uint32_t>(width);
    img.encoding = "bgr8";
    img.is_bigendian = 0;
    img.step = static_cast<uint32_t>(width * 3);
    const size_t nbytes =
        static_cast<size_t>(img.step) * static_cast<size_t>(height);
    img.data.assign(frame.data, frame.data + nbytes);

    bag.write(topic, stamp, img);

    // rosbag play --clock 会用它发布 /clock；同时 play 时不能有其他 /clock 源。
    rosgraph_msgs::Clock clock_msg;
    clock_msg.clock = stamp;
    bag.write("/clock", stamp, clock_msg);

    ++count;
  }
  bag.close();
  } catch (const std::exception &e) {
    // 出了异常也必须 close()，否则 rosbag 不写索引，产物是个 unindexed 的坏包，
    // 下游 `rosbag play` 直接拒绝打开。
    std::fprintf(stderr, "[mp4_to_bag] 写 bag 时出错：%s（已写 %d 帧）\n",
                 e.what(), count);
    try {
      bag.close();
    } catch (...) {
    }
    return 1;
  }

  std::printf("[mp4_to_bag] %s -> %s\n", video_path.c_str(), bag_path.c_str());
  std::printf("             %d 帧 %dx%d @ %.2f fps, 时长 %.2f s\n",
              count, width, height, fps, count / fps);
  std::printf("             topic=%s  (另写 /clock)\n", topic.c_str());

  return count > 0 ? 0 : 1;
}
