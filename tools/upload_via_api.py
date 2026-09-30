"""把本地仓库内容通过 GitHub Git Data API 直接提交到远程。

为什么不用 git push：本机代理对 github.com:443 持续返回 502（CONNECT tunnel failed），
而 api.github.com 可达。Git Data API 走的就是 api.github.com，绕开 git 传输层。

流程：blobs -> tree -> commit -> ref（分支已存在则带 parent 再 PATCH）。

用法：
    python tools/upload_via_api.py                 # 用本地 HEAD 的提交信息
    python tools/upload_via_api.py -m "自定义信息"

★ 提交信息默认取 `git log -1 --pretty=%B`，不再硬编码。
  硬编码的坑上次已经踩过：远程 commit 的信息与本地 commit 完全无关，
  事后对不上"哪次改了什么"。
"""
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

REPO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OWNER = "chowbing"
REPO = "EGaosuTidy"
BRANCH = "main"


def commit_message():
    """默认用本地 HEAD 的提交信息；-m/--message 可覆盖。"""
    for flag in ("-m", "--message"):
        if flag in sys.argv:
            i = sys.argv.index(flag)
            if i + 1 < len(sys.argv):
                return sys.argv[i + 1]
    p = subprocess.run(["git", "log", "-1", "--pretty=%B"],
                       capture_output=True, text=True, cwd=REPO_DIR)
    msg = (p.stdout or "").strip()
    if not msg:
        raise SystemExit("本地没有提交可同步（git log 返回空）—— 先 git commit")
    return msg


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


def api(method, path, payload=None, allow_404=False):
    url = "https://api.github.com" + path
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "token " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "EGaosuTidy-uploader")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        if allow_404 and e.code == 404:
            return None
        body = e.read().decode("utf-8", "replace")
        raise SystemExit("HTTP %d on %s %s: %s" % (e.code, method, path, body[:500]))


def list_files():
    p = subprocess.run(["git", "ls-files"], capture_output=True, text=True, cwd=REPO_DIR)
    files = [f for f in (p.stdout or "").splitlines() if f.strip()]
    if not files:
        raise SystemExit("git ls-files 返回空")
    return files


def main():
    files = list_files()
    print("待上传 %d 个文件" % len(files))

    # 1) 每个文件 -> blob
    entries = []
    for rel in files:
        full = os.path.join(REPO_DIR, rel.replace("/", os.sep))
        with open(full, "rb") as fh:
            raw = fh.read()
        blob = api("POST", "/repos/%s/%s/git/blobs" % (OWNER, REPO), {
            "content": base64.b64encode(raw).decode("ascii"),
            "encoding": "base64",
        })
        entries.append({
            "path": rel,
            "mode": "100755" if rel.endswith(".py") else "100644",
            "type": "blob",
            "sha": blob["sha"],
        })
        print("  blob %-34s %8d B  %s" % (rel, len(raw), blob["sha"][:10]))

    # 2) tree
    tree = api("POST", "/repos/%s/%s/git/trees" % (OWNER, REPO), {"tree": entries})
    print("tree  %s" % tree["sha"][:10])

    # 3) commit（main 已存在则带 parent，保持历史连续）
    # ★ GET 用单数 /git/ref/，PATCH 用复数 /git/refs/ —— 写错会得到一个像
    #   "仓库不存在" 的 404 Not Found（已在 ios-theos-dylib-ci 技能里记过，这里同样踩了）
    get_ref_path = "/repos/%s/%s/git/ref/heads/%s" % (OWNER, REPO, BRANCH)
    patch_ref_path = "/repos/%s/%s/git/refs/heads/%s" % (OWNER, REPO, BRANCH)
    existing = api("GET", get_ref_path, allow_404=True)
    parents = []
    if existing and existing.get("object", {}).get("sha"):
        parents.append(existing["object"]["sha"])
        print("远程 %s 已存在 -> parent = %s" % (BRANCH, parents[0][:10]))

    author = {"name": "Shawn", "email": "chowbing@users.noreply.github.com"}
    msg = commit_message()
    print("提交信息首行：%s" % msg.splitlines()[0])
    commit = api("POST", "/repos/%s/%s/git/commits" % (OWNER, REPO), {
        "message": msg,
        "tree": tree["sha"],
        "parents": parents,
        "author": author,
        "committer": author,
    })
    print("commit %s" % commit["sha"][:10])

    # 4) ref
    if existing:
        api("PATCH", patch_ref_path, {"sha": commit["sha"], "force": True})
    else:
        api("POST", "/repos/%s/%s/git/refs" % (OWNER, REPO), {
            "ref": "refs/heads/" + BRANCH,
            "sha": commit["sha"],
        })
    print("\n>>> 已提交到 %s/%s 的 %s 分支" % (OWNER, REPO, BRANCH))
    print(">>> https://github.com/%s/%s/commit/%s" % (OWNER, REPO, commit["sha"]))
    print(">>> 本地 HEAD = %s" % subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=REPO_DIR
    ).stdout.strip())


if __name__ == "__main__":
    sys.exit(main())
