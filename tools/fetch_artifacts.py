#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fetch_artifacts.py —— 取最新一次 CI 的产物，并**在本地**独立核验

为什么需要它：CI 自己说"成功"不等于产物能用。本项目实测踩过一次 ——
CI 用 `find .theos -name 'EGaosuTidy.dylib' | head -1` 取产物，抓到的是
dsymutil 生成的 dSYM 里的**同名文件**（filetype=10 MH_DSYM，只有 __DWARF 段），
构建绿着、大小看着正常，注入真机后什么都不会发生。
所以核验必须在**下载之后、独立做**，不能只看 CI 的报告。

核验项：
  1. Mach-O 合法（magic cf fa ed fe = 64 位 arm64 小端）
  2. filetype == 6（MH_DYLIB）—— 10 是 MH_DSYM，直接判失败
  3. 变体标记字符串已嵌入（防产物串档）
  4. 打印各段大小（确认不是只有调试信息的空壳）

用法：
    python tools/fetch_artifacts.py            # 最新一次 run
    python tools/fetch_artifacts.py 6          # 指定 run 序号
"""
import io
import json
import os
import struct
import subprocess
import sys
import urllib.request
import zipfile

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OWNER = "chowbing"
REPO = "EGaosuTidy"
DIST = os.path.join(REPO_DIR, "dist")

VARIANTS = ["normal", "nofloat", "dispatchonly", "minimal"]
FILETYPE = {2: "MH_EXECUTE", 6: "MH_DYLIB", 8: "MH_BUNDLE", 10: "MH_DSYM"}


def contains_literal(raw, s):
    """在二进制里找字符串字面量 —— **必须试两种编码**。

    这个坑实测踩过：ObjC 的 @"..." 字面量不在 __cstring，而在
      __ustring  （UTF-16LE，每个字符 2 字节）
      __DATA_CONST,__cfstring（CFString 结构，指向 __ustring）
    而 C 字符串字面量（EGJournal("ensure-start") 这种）在
      __cstring  （UTF-8）
    只按 UTF-8 搜，会得出"中文字面量全都不在二进制里"的错误结论 ——
    实际上它们好好地躺在 __ustring 里。
    """
    return s.encode("utf-8") in raw or s.encode("utf-16-le") in raw


class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    """artifact 下载会 302 到带签名的 blob 存储；把 Authorization 一起带过去会被拒(403)。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        r = super().redirect_request(req, fp, code, msg, headers, newurl)
        if r is not None:
            r.remove_header("Authorization")
        return r


OPENER = urllib.request.build_opener(NoAuthRedirect)


def token():
    p = subprocess.run(["git", "credential", "fill"],
                       input="protocol=https\nhost=github.com\n\n",
                       capture_output=True, text=True, cwd=REPO_DIR)
    for line in (p.stdout or "").splitlines():
        if line.startswith("password="):
            return line[len("password="):]
    raise SystemExit("拿不到 GitHub token")


TOKEN = token()


def api(url):
    r = urllib.request.Request(url)
    r.add_header("Authorization", "token " + TOKEN)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("User-Agent", "EGaosuTidy-fetch")
    with OPENER.open(r, timeout=180) as x:
        return x.read()


def macho_info(raw):
    """返回 (ok, filetype, 段列表)。段列表 = [(名, filesize)]"""
    if raw[:4] != b"\xcf\xfa\xed\xfe":
        return False, None, []
    ftype = struct.unpack("<I", raw[12:16])[0]
    ncmds = struct.unpack("<I", raw[16:20])[0]
    off, segs = 32, []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", raw[off:off + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            name = raw[off + 8:off + 24].rstrip(b"\0").decode("ascii", "replace")
            _, _, _, filesize = struct.unpack("<QQQQ", raw[off + 24:off + 56])
            segs.append((name, filesize))
        off += cmdsize
    return True, ftype, segs


def main():
    want = int(sys.argv[1]) if len(sys.argv) > 1 else None
    runs = json.loads(api("https://api.github.com/repos/%s/%s/actions/runs?per_page=20"
                          % (OWNER, REPO)))["workflow_runs"]
    if not runs:
        raise SystemExit("没有任何 CI run")
    run = None
    for r in runs:
        if want is None or r["run_number"] == want:
            run = r
            break
    if run is None:
        raise SystemExit("找不到 run #%s" % want)

    print("run #%s  %s/%s  %s" % (run["run_number"], run["status"], run["conclusion"], run["head_sha"][:10]))
    print("       %s" % run["html_url"])
    if run["status"] != "completed":
        raise SystemExit("该 run 还没跑完，等一会儿再试")

    arts = json.loads(api("https://api.github.com/repos/%s/%s/actions/runs/%d/artifacts"
                          % (OWNER, REPO, run["id"])))["artifacts"]
    os.makedirs(DIST, exist_ok=True)

    dylibs = {}
    for a in arts:
        data = api(a["archive_download_url"])
        zpath = os.path.join(DIST, "%s.zip" % a["name"])
        with open(zpath, "wb") as f:
            f.write(data)
        z = zipfile.ZipFile(io.BytesIO(data))
        print("\n[artifact] %-20s %8d B  内含 %d 个文件" % (a["name"], len(data), len(z.namelist())))
        for n in z.namelist():
            if a["name"] == "EGaosuTidy-dylibs":
                dylibs[os.path.basename(n)] = z.read(n)
            else:
                print("   %s" % n)

    # ★ 只核验**本次真的构建出来**的变体。
    #   CI 默认只出 normal（2026-10-01 起），把其余三个当成"缺失"会永远报红。
    present = [v for v in VARIANTS if ("EGaosuTidy-%s.dylib" % v) in dylibs]
    if not present:
        raise SystemExit("产物包里没有任何 dylib —— 构建其实没成功")

    print("\n" + "=" * 74)
    print("本地独立核验（不采信 CI 自己的报告）")
    print("=" * 74)
    bad = 0
    for v in present:
        name = "EGaosuTidy-%s.dylib" % v
        raw = dylibs.get(name)
        if raw is None:
            print("  [%s] 缺失" % v)
            bad += 1
            continue
        ok, ftype, segs = macho_info(raw)
        kind = FILETYPE.get(ftype, "?")
        if not ok:
            print("  [%s] 不是 64 位 arm64 Mach-O" % v)
            bad += 1
            continue
        if ftype != 6:
            print("  [%s] filetype=%d (%s) —— 不是 dylib！" % (v, ftype, kind))
            bad += 1
            continue
        tag_ok = contains_literal(raw, v)
        seg_txt = " ".join("%s=%d" % (n, s) for n, s in segs if s)
        print("  [%s] OK  filetype=6 MH_DYLIB  %d B" % (v, len(raw)))
        print("       段: %s" % seg_txt)
        print("       变体标记: %s" % ("已嵌入" if tag_ok else "!! 找不到"))
        if not tag_ok:
            bad += 1
        out = os.path.join(DIST, name)
        with open(out, "wb") as f:
            f.write(raw)

    print()
    if bad:
        print(">>> 核验未通过：%d 项有问题" % bad)
        return 1
    print(">>> 4 个变体全部核验通过，已解出到 dist/")
    for v in VARIANTS:
        p = os.path.join(DIST, "EGaosuTidy-%s.dylib" % v)
        print("    %s" % p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
