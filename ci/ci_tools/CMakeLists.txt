cmake_minimum_required(VERSION 3.0.2)
project(ci_tools)

find_package(catkin REQUIRED COMPONENTS
  roscpp rosbag sensor_msgs rosgraph_msgs opencv3_catkin
)

catkin_package(CATKIN_DEPENDS roscpp rosbag sensor_msgs rosgraph_msgs)
include_directories(${catkin_INCLUDE_DIRS})

add_executable(mp4_to_bag src/mp4_to_bag.cpp)
target_link_libraries(mp4_to_bag ${catkin_LIBRARIES})
