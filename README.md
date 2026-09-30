# EGaosuTidy — e高速界面精简插件

**目标**：把「e高速」（山东高速官方 ETC 平台，`com.sdhs.easy.high.road`）的
**底栏 5 个 tab（首页 / 车主服务 / 会员服务 / 商城 / 我的）精简到只剩「我的」**，
并清掉**「我的」页中「我的订单」与「我的服务」之间的图片广告**（"移动积分兑高速通行券"横幅）。

当前版本：**v0.1.1-probe —— 纯探针，只取证、不改任何界面行为。**

> **v0.1.1 修了什么（依据 = 2026-09-30 23:21:29 真机 .ips）**
>
> v0.1 在真机上**启动即闪退**（SIGBUS，0.18 秒）。.ips 显示崩溃帧属于**主二进制**
> （`imgIdx=0`），我们的 dylib（`imgIdx=43`, `base=0x111ef0000`, `size=0x18000`）
> **栈上一帧都没有** —— 但崩溃发生在 `dyld → runAllInitializersForMain → notifyObjCInit
> → load_images`，即**宿主的 `+load` 正在执行时**，而 v0.1 的 `%ctor` 恰好在这个阶段
> 做了三件有副作用的事：调 Foundation、用 `sigaction` 覆盖宿主 6 个信号处理器 +
> `sigaltstack`、文件 IO。
>
> **dyld 阶段是别人的地盘。** 宿主若在 `+load` 里用信号做自检 / 反调试 / 崩溃收集
> （国产 App 常见），我们的覆盖会把它变成真崩溃，而崩溃点自然落在它的代码上 ——
> 与这份 .ips 的形状完全吻合。
>
> v0.1.1 因此把 `%ctor` 砍到**只剩一次 `dispatch_async`**，Foundation 调用、文件 IO、
> 信号处理器全部推迟到主队列（runloop 已起来、宿主 `+load` 已跑完）执行。
> 信号处理器**默认关闭**（`ENABLE_CRASH_HANDLERS 0`），代价是失去"爆栈/无限递归"的
> 现场取证 —— 那类崩溃系统 .ips 里同样有完整栈，本次这个崩溃正是靠 .ips 定位的。
>
> 顺带修正：bundle id 实测为 **`com.sdhsie.westeros.weirwood`**，
> 不是之前从 Android 包名推断的 `com.sdhs.easy.high.road`（推断错了）。

---

## 0. 当前状态：为什么第一版是探针

目标是全新 App，我们对它的内部结构**零知识**。下面四条关键信息全部未知，
而**每一条猜错都要白做一版** —— 每一版 = 一轮 GitHub Actions + 一次真机注入：

| # | 待回答 | 为什么必须实测 |
|---|---|---|
| **Q1** | 底栏是**系统 `UITabBarController`** 还是**自绘容器**？ | 截图里中间「车主服务」是**凸起**的，这是自绘的典型特征 —— 但**特征不是证据**。系统 tab 过滤 `viewControllers` 即可；自绘底栏过滤数据层**一个图标都不会动**（"幽灵图标"），必须两层处理 + 手动重排 |
| **Q2** | 5 个 tab 各自的 **VC 类名 / `tabBarItem.title` / `tabBarItem.tag`**？ | 决定"哪个才是「我的」"。同类项目的教训：VC 类名可能**全是** `BaseNavigationController`、`title` 可能**全为空**，只有 `tag` 可用。认身份的字段必须实测，不能猜 |
| **Q3** | 那条广告是 `UICollectionViewCell` / `UITableViewCell` / 还是独立视图？ | 决定隐藏与**收起**方式。`hidden = YES` 只是不画，**布局里那一格还在** —— 藏在页面中部会留下一块空白 |
| **Q4** | 「我的」页是**原生**还是 **H5**？ | 原生方案对 H5 内部元素**完全无效**（H5 里画的广告在原生树上只是个 `WKContentView`），白改一版才发现。dump 里给每个节点打了 `[H5]` 标 |

所以先花一轮把上面四条**实测**出来，再写规则版。探针的全部产出就是文本。

---

## 1. 真机操作步骤（请按顺序跑，然后把粘贴内容发回）

**前置**：TrollStore + TrollFools → 选「e高速」→ 注入 `EGaosuTidy.dylib` → 重启 App。

注入后右上角出现一个蓝色圆点 **EG**（可拖动）：

| 操作 | 作用 |
|---|---|
| **点一下** | 抓当前页面 → 底栏取证 + 当前页视图树 + 广告候选汇总 → 写剪贴板，按钮标题闪一下显示抓到的字节数 |
| **长按**（0.6s） | 完整诊断 → 底栏取证 + 类名扫描 + 崩溃回读 + 视图树 → 写剪贴板 |
| **拖动** | 移开按钮，避免遮挡 |

**请这样跑：**

1. 停在任意**底栏可见**的页面 → **点一下 EG** → 粘贴回来　→ 回答 **Q1 / Q2**
2. 切到**「我的」页**（滚到能看到那条广告）→ **点一下 EG** → 粘贴回来　→ 回答 **Q3 / Q4**
3. （可选）**长按 EG** → 完整诊断 → 粘贴回来　→ 补上类名扫描与崩溃记录

> 按钮标题闪成 `xx.xk` 表示**点击生效、文本已进剪贴板**。
> 如果按钮标题不动，说明点击没被收到 —— 那就是另一类问题（窗口层级），请告诉我。

---

## 2. 构建（CI，本机无 macOS）

```bash
git add -A && git commit -m "..." && git push
```

GitHub Actions（`.github/workflows/build.yml`）在 `macos-latest` 上装 Theos + iPhoneOS SDK + ldid，
编译 `arm64` dylib，并把 **build log** 与 **dylib** 都作为 artifact 上传（失败也上传日志）。

- 产物路径：`.theos/obj/debug/EGaosuTidy.dylib`
- Actions → 左侧选 `Build EGaosuTidy dylib` → 也可网页手动触发（`workflow_dispatch`）

**推送前必跑静态预检**（本机没有 macOS，每次推送都是一轮 CI，所以这步不能省）：

```bash
python tools/preflight.py Tweak.xm     # 退出码 0 = 可以推送
```

它先**自证检查器本身没瞎**（拿故意写坏的文件喂每个检查器，必须报错），
再对 `Tweak.xm` 跑四项检查：括号平衡、调用/引用早于定义、字符串闭合、ObjC++ 类型陷阱。
`.xm` 按 **Objective-C++** 编译，隐式函数声明是**硬 error**（`-Wno-error` 救不了）。

---

## 3. 探针输出什么（对照检查）

一次「点一下」的输出分七段：

```
===== 当前页面 =====        当前 VC 类名 / VC 父链 / 根视图与窗口坐标
===== 底栏取证 =====        找到几个 UITabBarController；每个的 selectedIndex、
                            viewControllers（类名 + title + tag）、tabBar 的直接子视图；窗口清单
===== 自绘底栏候选 =====     类名含 TabBar/TabItem/TabButton/... 的类（只报告）
===== 当前页视图树 =====     逐节点：类名 + frame + **窗口坐标** + hidden + 文案/图片尺寸 + 标记
===== 广告候选汇总 =====     横幅形态（宽>=150 高>=30 比例 1.8~8）或类名疑似广告的节点，带窗口坐标
===== 本会话 VC 类名 =====   去重后的 VC 类名列表
===== 诊断缓冲 =====         滚动窗口内的全部日志
```

**视图树的 `win=(x,y,w,h)` 是窗口坐标** —— `frame` 是相对父视图的，
"屏幕底部那条"要自己把父链 origin 加一遍才能对上截图，节点一多必然算错，算错就会改错节点。

**`[H5]` 标是停止信号**：标了 `[H5]` 的节点，原生隐藏方案对它**无效**，要改用 CSS 注入。

---

## 4. 已知假设与风险（如实标注）

| 项 | 状态 |
|---|---|
| **Bundle ID** | ✅ **已实测**：`com.sdhsie.westeros.weirwood`（来源：2026-09-30 真机 .ips）。此前写的 `com.sdhs.easy.high.road` 是从小米/应用宝/OPPO 三处 **Android 包名推断**的 —— **推断错了**。iOS 与 Android 的 bundle id 不保证一致，这条只能靠实测 |
| **目标 App 版本** | ✅ **已实测**：e高速 **5.10.7**（build 2），运行在 iOS 16.6.1 |
| 界面结构 | **仍全部未知**。v0.1 在真机上启动即崩（见顶部 v0.1.1 说明），还没走到界面。等 v0.1.1 确认能正常启动后再取 dump |
| TrollFools 注入与 plist Filter | 注入模式下 `Filter` 不参与判定（dylib 由 dyld 无条件加载）—— 本次崩溃的 .ips 里确实出现了 `EGaosuTidy.dylib`，印证了这点。但若改用 deb 安装（Sileo/Zebra），Filter 必须准确，所以已同步改为实测值 |

---

## 5. 目录结构

```
EGaosuTidy/
├── Tweak.xm                    探针本体（唯一需要读的源文件）
├── Makefile / control / *.plist Theos 工程配置
├── tools/                      推送前静态预检（从既有项目复用，通用）
│   ├── preflight.py            一次跑完全部检查，并先自证检查器没瞎
│   ├── chk.py                  括号/引号平衡（tokeniser-aware）
│   ├── audit.py                调用早于定义 / 全局引用早于定义 / 递归 block 缺 __block
│   ├── strchk.py               字符串字面量未闭合
│   ├── objcpp.py               ObjC 合法但 ObjC++ 是硬 error 的构造
│   └── ips.py                  iOS 15+ .ips 崩溃报告解析（两个 JSON 文档拼在一个文件里）
└── .github/workflows/build.yml CI 构建
```

---

## 6. 安全底线（探针阶段）

- **探针不改任何东西**：不隐藏、不删除、不改约束、不拦弹窗、不动数据。产出只有文本。
- **`%ctor` 只做一件事：一次 `dispatch_async`。** 其余全部（崩溃日志路径、文件 IO、信号处理器、
  钩子）都放进那个块里，等主队列执行。
  **`%ctor` 运行在 dyld 的 `runAllInitializersForMain → runInitializersBottomUp → notifyObjCInit
  → load_images` 之中** —— 也就是说，**它跑在宿主自己的初始化过程里**，此时宿主的 `+load`
  可能还在执行。在那里做的任何有副作用的事，都发生在别人的地基上。
  v0.1 就是在这里翻了车（见顶部），实测证据是一份 0.18 秒的 SIGBUS `.ips`。
- **默认不装信号处理器**（`ENABLE_CRASH_HANDLERS 0`）。覆盖宿主自己的 `sigaction` 会把它的
  "自检"变成"真崩溃"。失去的只是爆栈类崩溃的现场取证，而系统 `.ips` 同样完整 ——
  本次这个崩溃正是靠 `.ips` 定位的。
- 查方法一律 `class_copyMethodList` 手走父类链，**绝不用 `class_getInstanceMethod`**
  —— 后者会强制 `+initialize`。
- 只 hook **一个类的一个 selector**（`UIViewController.viewDidAppear:`），一个 shim + 一个全局
  orig IMP。**不装"每个实现类各一份"的通用安装器** —— 共享 shim 无法区分直接调用与
  `[super]` 调用，会无限递归爆栈。
- **启动自愈**：同一构建连续 3 次启动异常 → 本次启动不装任何钩子，只留悬浮球。
  计数绑定构建令牌：同一构建内粘性（不会"崩一次下次又好"），换构建自动归零。
- 崩溃取证带 `sigaltstack` + `SA_ONSTACK`：否则爆栈类崩溃在已耗尽的栈上再崩一次，
  自己的日志会是**零字节**，只剩系统 `.ips`。
- 诊断缓冲用**滚动窗口 + 显式截断标记**，绝不"写满就静默停止"。

**后续规则版同样不做的事**：不 hook 网络请求 / 签名 / 鉴权；不伪造数据；不绕过付费；
不修改服务端可见的任何状态。只做**视图层与导航层的显示与隐藏**。
