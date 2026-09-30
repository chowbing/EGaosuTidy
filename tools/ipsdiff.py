#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ipsdiff.py —— 崩溃报告结构化对比

用途：两份 .ips 放在一起看，回答三个问题
  Q1 崩溃的那一帧落在哪个 image 里？是不是我们的 dylib？
  Q2 进程里加载了哪些「保护/加固/反调试」类 SDK？
  Q3 两次崩溃的 image 列表差异（第二次多/少了什么）

.ips 是「一行 JSON 头 + 一个 JSON 体」两个文档拼起来的，不是单个 JSON。
直接 json.load 整个文件必然失败，必须先切第一行。
"""
import json
import os
import re
import sys

# 可疑 SDK 关键字：命中即打印，用于定位加固/反注入厂商
SUSPECT = re.compile(
    r"protect|security|secure|jailbreak|jb|guard|shield|anti|risk|safe|"
    r"armor|encrypt|crypt|obfusc|integrity|tamper|harden|frida|cydia|"
    r"substrate|ellekit|detect|verify|sign|licen|jm|riskified|"
    r"xguard|tx|alibaba|aliyun|tencent|bugly|netguard|kits",
    re.I,
)

# 明确是我们自己的东西，单独标记
MINE = re.compile(r"EGaosuTidy|JegoTidy", re.I)


def load_ips(path):
    """返回 (header: dict, body: dict)"""
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        raw = f.read()
    nl = raw.find("\n")
    if nl < 0:
        raise ValueError("文件不是 .ips 格式（找不到换行）")
    head = json.loads(raw[:nl])
    body = json.loads(raw[nl + 1:])
    return head, body


def images_of(body):
    """返回 [(idx, base, size, name)]"""
    out = []
    for i, im in enumerate(body.get("usedImages") or []):
        out.append((
            i,
            im.get("base", 0),
            im.get("size", 0),
            im.get("name") or im.get("path") or "<None>",
            im.get("uuid", ""),
        ))
    return out


def frames_of(thread):
    out = []
    for f in thread.get("frames") or []:
        out.append({
            "img": f.get("imageIndex"),
            "off": f.get("imageOffset"),
            "sym": f.get("symbol"),
            "name": f.get("symbolLocation"),
        })
    return out


def main():
    if len(sys.argv) < 3:
        print("用法: python ipsdiff.py a.ips b.ips")
        return 2

    reports = []
    for p in sys.argv[1:]:
        if not os.path.isfile(p):
            print("!! 文件不存在: %s" % p)
            return 2
        reports.append((os.path.basename(p),) + load_ips(p))

    for name, head, body in reports:
        print("=" * 78)
        print("报告: %s" % name)
        print("=" * 78)
        print("  app        : %s" % head.get("app_name"))
        print("  bundle     : %s" % head.get("bundleID"))
        print("  version    : %s (%s)" % (head.get("app_version"), head.get("build_version")))
        print("  os         : %s %s" % (head.get("os_version"), head.get("osBuild")))
        print("  device     : %s" % head.get("product"))
        print("  timestamp  : %s" % head.get("timestamp"))
        print("  reportType : %s" % head.get("reportType"))
        print("  uptime     : %s" % head.get("uptime"))

        ex = body.get("exception") or {}
        print("  exception  : %s / %s" % (ex.get("type"), ex.get("signal")))
        print("  codes      : %s" % ex.get("codes"))
        print("  subtype    : %s" % ex.get("subtype"))
        if ex.get("message"):
            print("  message    : %s" % ex.get("message"))
        ti = body.get("termination") or {}
        if ti:
            print("  termination: %s" % json.dumps(ti, ensure_ascii=False))

        imgs = images_of(body)
        print("  image 数量 : %d" % len(imgs))

        # ---- 我们的 dylib ----
        print("\n  -- 我们自己注入的 dylib --")
        found_mine = False
        for idx, base, size, nm, uuid in imgs:
            if MINE.search(nm):
                found_mine = True
                print("     idx=%d base=0x%x size=0x%x uuid=%s" % (idx, base, size, uuid))
                print("       %s" % nm)
        if not found_mine:
            print("     (未在 image 列表中找到 —— 说明本次启动注入未生效)")

        # ---- 可疑 SDK ----
        print("\n  -- 命中「保护/加固/检测」关键字的 image --")
        hits = 0
        for idx, base, size, nm, uuid in imgs:
            if MINE.search(nm):
                continue
            if SUSPECT.search(nm):
                hits += 1
                print("     idx=%-4d base=0x%-12x %s" % (idx, base, nm))
        if not hits:
            print("     (无)")

        # ---- 全零 image 条目 ----
        zeros = [i for i, b, s, n, u in imgs if b == 0 and s == 0]
        if zeros:
            print("\n  -- 全零 image 条目(崩溃帧可能落在这里) --")
            print("     %s" % zeros)

        # ---- 各线程 ----
        print("\n  -- 线程 --")
        threads = body.get("threads") or []
        print("     线程总数: %d" % len(threads))
        for t in threads:
            trig = t.get("triggered")
            mark = "  <<< 触发崩溃" if trig else ""
            print("     thread %s  name=%s qos=%s  frames=%d%s" % (
                t.get("id"), t.get("name"), t.get("queue"),
                len(t.get("frames") or []), mark))
            fs = frames_of(t)
            limit = len(fs) if trig else 6
            for k, f in enumerate(fs[:limit]):
                nm = ""
                if f["img"] is not None and 0 <= f["img"] < len(imgs):
                    nm = imgs[f["img"]][3]
                print("        #%-2d %-42s +%s   [img=%s]" % (
                    k, (f["sym"] or "<no symbol>")[:42], f["off"], f["img"]))
                if nm:
                    print("            %s" % nm)
            if not trig and len(fs) > limit:
                print("        ... 省略 %d 帧" % (len(fs) - limit))

        # ---- 崩溃帧是否落在我们 dylib ----
        print("\n  -- 结论性检查 --")
        for t in threads:
            if not t.get("triggered"):
                continue
            for k, f in enumerate(frames_of(t)):
                if f["img"] is not None and 0 <= f["img"] < len(imgs):
                    nm = imgs[f["img"]][3]
                    if MINE.search(nm):
                        print("     !! 崩溃帧 #%d 落在我们的 dylib: %s" % (k, nm))
                    else:
                        print("     #%d 落在: %s" % (k, nm))
                else:
                    print("     #%d imageIndex=%s 越界/无效" % (k, f["img"]))

        # 崩溃帧里是否出现过任何保护 SDK
        prot_in_frames = set()
        for t in threads:
            for f in frames_of(t):
                if f["img"] is not None and 0 <= f["img"] < len(imgs):
                    nm = imgs[f["img"]][3]
                    if SUSPECT.search(nm):
                        prot_in_frames.add(nm)
        print("\n  -- 调用栈中出现过的保护类 SDK --")
        if prot_in_frames:
            for n in sorted(prot_in_frames):
                print("     %s" % n)
        else:
            print("     (无)")
        print()

    # ---- 两次的 image 差异 ----
    if len(reports) >= 2:
        print("=" * 78)
        print("两次崩溃的 image 列表差异")
        print("=" * 78)
        sets = []
        for name, head, body in reports:
            s = set()
            for idx, base, size, nm, uuid in images_of(body):
                s.add(os.path.basename(nm))
            sets.append((name, s))
        for i in range(len(sets)):
            for j in range(i + 1, len(sets)):
                n1, s1 = sets[i]
                n2, s2 = sets[j]
                only1 = sorted(s1 - s2)
                only2 = sorted(s2 - s1)
                print("\n[%s] 独有 (%d):" % (n1, len(only1)))
                for x in only1:
                    print("   - %s" % x)
                print("\n[%s] 独有 (%d):" % (n2, len(only2)))
                for x in only2:
                    print("   - %s" % x)
                print("\n共有: %d" % len(s1 & s2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
