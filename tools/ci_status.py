#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ci_status.py —— 查 Actions 运行状态（本机没有 gh，只能走 API）

为什么要有它：本机是 Windows，没有 gh / 没有 Xcode，每次验证都必须走一轮 CI。
推上去之后必须能立刻回答三个问题：
    1. 这次 push 有没有真的触发 run？（没触发 = 白等）
    2. run 是成功还是失败？失败在哪一步？
    3. 产物有几个、叫什么？

用法：
    python tools/ci_status.py              # 最近 5 次 run 的概览
    python tools/ci_status.py --jobs       # 附带每次 run 的 job/step 明细
    python tools/ci_status.py --log        # 失败时把失败 step 的日志尾部打出来

★ 只做只读查询，不触发、不重跑。
"""
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OWNER = "chowbing"
REPO = "EGaosuTidy"


def get_token():
    p = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True, text=True, cwd=REPO_DIR,
    )
    for line in (p.stdout or "").splitlines():
        if line.startswith("password="):
            return line[len("password="):]
    raise SystemExit("拿不到 GitHub token")


TOKEN = get_token()


def api(path, accept="application/vnd.github+json"):
    url = "https://api.github.com" + path
    req = urllib.request.Request(url, method="GET")
    req.add_header("Authorization", "token " + TOKEN)
    req.add_header("Accept", accept)
    req.add_header("User-Agent", "EGaosuTidy-ci-status")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print("  [HTTP %s] %s" % (e.code, path))
        return None


def main():
    want_jobs = "--jobs" in sys.argv or "--log" in sys.argv
    want_log = "--log" in sys.argv
    n = 5
    for a in sys.argv[1:]:
        if a.isdigit():
            n = int(a)

    runs = api("/repos/%s/%s/actions/runs?per_page=%d" % (OWNER, REPO, n))
    if not runs or "workflow_runs" not in runs:
        raise SystemExit("取不到 run 列表")

    print("=" * 62)
    print("最近 %d 次 Actions run —— %s/%s" % (n, OWNER, REPO))
    print("=" * 62)
    for r in runs["workflow_runs"]:
        print("#%s  %s  %-10s %s  %s" % (
            r.get("run_number"), r.get("status"), r.get("conclusion") or "-",
            r.get("display_title", "")[:40], r.get("head_sha", "")[:10]))
        print("     %s" % r.get("html_url", ""))

    if not want_jobs:
        return

    rid = runs["workflow_runs"][0].get("id")
    jobs = api("/repos/%s/%s/actions/runs/%s/jobs" % (OWNER, REPO, rid))
    if not jobs:
        return
    print("\n" + "-" * 62)
    print("最新 run #%s 的步骤" % runs["workflow_runs"][0].get("run_number"))
    print("-" * 62)
    for j in jobs.get("jobs", []):
        print("job: %s -> %s / %s" % (j.get("name"), j.get("status"), j.get("conclusion")))
        for s in j.get("steps", []):
            print("   [%s] %s" % (s.get("conclusion") or s.get("status"), s.get("name")))
            if want_log and s.get("conclusion") == "failure":
                body = api("/repos/%s/%s/actions/jobs/%s/logs" % (OWNER, REPO, j.get("id")),
                           accept="application/vnd.github+json")
                if isinstance(body, str):
                    print("      ---- 日志尾部 ----")
                    for line in body.splitlines()[-40:]:
                        print("      " + line)


if __name__ == "__main__":
    main()
