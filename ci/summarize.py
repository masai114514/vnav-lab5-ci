#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ci/summarize.py —— 把各 stage 的日志揉成一份 out/report.md

为什么单独写一个脚本而不是在 bash 里 printf：
  - 统计行的格式来自 C++ 里 printStats 的 7 行，解析要稳（缺行、NaN、只有 1 个样本
    都要能对上），bash 里做太脆；
  - 报告里的表要能直接贴进团队报告，数字必须与日志一一对应，不能手抄。

用法：
  python3 ci/summarize.py --out out --pass "env,apt,..." --fail ""
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
from datetime import datetime, timezone

# FeatureTracker::printStats / LKFeatureTracker::printStats 的输出字段
FIELDS = [
    ("kp1", r"Avg\. Keypoints 1 Size:\s*([0-9.eE+-]+)"),
    ("kp2", r"Avg\. Keypoints 2 Size:\s*([0-9.eE+-]+)"),
    ("matches", r"Avg\. Number of matches:\s*([0-9.eE+-]+)"),
    ("good", r"Avg\. Number of good matches:\s*([0-9.eE+-]+)"),
    ("inliers", r"Avg\. Number of Inliers:\s*([0-9.eE+-]+)"),
    ("ratio", r"Avg\. Inliers ratio:\s*([0-9.eE+-]+)"),
    ("samples", r"Num\. of samples:\s*([0-9.eE+-]+)"),
]

# handout / 官方参考解在 box 图像对上的结果，用来判断我们的口径对不对
REFERENCE_SIFT = {
    "kp1": 603, "kp2": 969, "matches": 93, "good": 78, "ratio": 0.839,
}


def read(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def parse_stats(text: str) -> dict:
    out = {}
    for key, pat in FIELDS:
        m = re.search(pat, text)
        if m:
            try:
                out[key] = float(m.group(1))
            except ValueError:
                out[key] = m.group(1)
    return out


def fmt(v, digits=0):
    if v is None:
        return "—"
    if isinstance(v, str):
        return v
    if digits == 0:
        return "%.0f" % v
    return ("%." + str(digits) + "f") % v


def pct(v):
    if isinstance(v, (int, float)) and v <= 1.5:
        return "%.1f %%" % (100.0 * v)
    if isinstance(v, (int, float)):
        return "%.1f %%" % v
    return "—"


def cells(st):
    return [fmt(st.get("kp1")), fmt(st.get("kp2")),
            fmt(st.get("matches")), fmt(st.get("good")),
            fmt(st.get("inliers")), pct(st.get("ratio")),
            fmt(st.get("samples"))]


def table_row(name, st, note=None):
    """note=None → 7 指标列；否则在末尾再加一列备注。"""
    if note is None:
        return "| %s | %s |" % (name, " | ".join(cells(st)))
    return "| %s | %s | %s |" % (name, " | ".join(cells(st)), note)


def find_figs(figdir: str) -> list:
    if not os.path.isdir(figdir):
        return []
    return sorted(f for f in os.listdir(figdir) if f.lower().endswith(".png"))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="out")
    ap.add_argument("--pass", dest="ok", default="")
    ap.add_argument("--fail", dest="bad", default="")
    args = ap.parse_args()

    out = args.out
    figdir = os.path.join(out, "fig")
    ok = [s for s in args.ok.split(",") if s]
    bad = [s for s in args.bad.split(",") if s]

    pair = {}
    surf_failed_nonfree = False
    for name in ("SIFT", "SURF", "ORB", "FAST"):
        text = read(os.path.join(out, "pair_%s.log" % name))
        st = parse_stats(text)
        if st:
            pair[name] = st
            if re.search(r"patented|is excluded", text, re.I):
                pair[name]["note"] = "nonfree 未开"
        elif re.search(r"patented|is excluded", text, re.I):
            surf_failed_nonfree = True
    pair.setdefault("SIFT", {})
    if "note" not in pair["SIFT"] and pair["SIFT"]:
        # 与官方参考值比一比，差太多说明实现口径不对
        d = abs(pair["SIFT"].get("kp1", 0) - REFERENCE_SIFT["kp1"])
        pair["SIFT"]["note"] = "与官方 603/969/93/78 差 %d 个 kp1" % d

    video = {}
    for name in ("LK", "SIFT", "ORB"):
        st = parse_stats(read(os.path.join(out, "video_%s.log" % name)))
        if st:
            video[name] = st

    figs = find_figs(figdir)
    build = read(os.path.join(out, "build_evidence.txt"))
    bag_info = read(os.path.join(out, "bag_info.txt"))

    lines = []
    A = lines.append
    A("# LAB5 CI 运行报告")
    A("")
    A("生成时间：%s（UTC）" % datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"))
    for k in ("GITHUB_REPOSITORY", "GITHUB_SHA", "GITHUB_RUN_ID", "GITHUB_REF_NAME"):
        v = os.environ.get(k)
        if v:
            A("- `%s` = `%s`" % (k, v))
    A("- 通过的 stage：%s" % (", ".join(ok) if ok else "（无）"))
    if bad:
        A("- **失败的 stage**：%s" % ", ".join(bad))
    A("")

    A("## 1. 图像对统计（D3 / D5）")
    A("")
    A("官方 `two_frames_tracking.launch`，`images/box.png` + `images/box_in_scene.png`，"
      "`mode:=0`。")
    A("")
    A("| 描述子 | kp1 | kp2 | 匹配数 | 良好匹配(Lowe 0.8) | 内点 | 内点率 | 样本数 | 备注 |")
    A("|---|---|---|---|---|---|---|---|---|")
    for name in ("SIFT", "SURF", "ORB", "FAST"):
        if name in pair:
            A(table_row(name, pair[name], pair[name].get("note", "")))
    A("")
    if surf_failed_nonfree:
        A("> **SURF 缺失**：日志里出现 `patented and is excluded` —— OpenCV 编译时没开 "
          "`OPENCV_ENABLE_NONFREE=ON`（pip 轮子一律不开，只能源码编）。"
          "修 `bundle/dependencies/opencv3_catkin/CMakeLists.txt` 后重跑（缓存 key 会变，"
          "会自动重建 OpenCV）。")
        A("")
    if pair.get("SIFT"):
        A("> 官方参考解：603 / 969 / 93 / 78 / 83.9 %%。本机复算：%s / %s / %s / %s / %s。"
          % (fmt(pair["SIFT"].get("kp1")), fmt(pair["SIFT"].get("kp2")),
             fmt(pair["SIFT"].get("matches")), fmt(pair["SIFT"].get("good")),
             pct(pair["SIFT"].get("ratio"))))
        A("")

    A("## 2. 视频序列统计（D6 / D7）")
    A("")
    if bag_info:
        A("测试序列：`data/seq20s.mp4` → `ci_tools/mp4_to_bag` → `seq20s.bag`（与 TESSE 同话题）。")
        A("")
        A("```")
        A(bag_info.strip()[:800])
        A("```")
        A("")
    if video:
        A("| 描述子 | kp1 | kp2 | 匹配数 | 良好匹配 | 内点 | 内点率 | 样本数 |")
        A("|---|---|---|---|---|---|---|---|")
        for name in ("LK", "SIFT", "ORB"):
            if name in video:
                A(table_row(name, video[name]))
        A("")
    else:
        A("_没有视频统计（video stage 未跑或失败）_")
        A("")

    A("## 3. 可视化产物（D4 / D6 / D7 / D8）")
    A("")
    if figs:
        A("共 %d 张，全部在 `out/fig/`：" % len(figs))
        A("")
        A("```")
        for f in figs:
            A(f)
        A("```")
    else:
        A("_没有图（pair/video stage 未跑成）_")
    A("")

    A("## 4. 构建证据")
    A("")
    if build:
        A("```")
        A(build.strip()[:2500])
        A("```")
    else:
        A("_没有 build_evidence.txt_")
    A("")

    A("## 5. stage 明细")
    A("")
    A("| stage | 结果 | 日志 |")
    A("|---|---|---|")
    for s in ok:
        A("| %s | ✅ | `out/stage_%s.log` |" % (s, s))
    for s in bad:
        A("| %s | ❌ | `out/stage_%s.log` |" % (s, s))
    A("")

    path = os.path.join(out, "report.md")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print("报告已写出：%s（%d 行）" % (path, len(lines)))
    print("\n".join(lines[:40]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
