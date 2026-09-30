# EGaosuTidy — e高速界面精简插件

**目标**：把「e高速」（山东高速官方 ETC 平台，`com.sdhsie.westeros.weirwood`）的
**底栏 5 个 tab（首页 / 车主服务 / 会员服务 / 商城 / 我的）精简到只剩「我的」**，
并清掉**「我的」页中「我的订单」与「我的服务」之间的图片广告**（"移动积分兑高速通行券"横幅）。

当前版本：**v0.1.2-probe —— 纯探针，只取证、不改任何界面行为。**

---

## 0. 现在最要紧的事：判定「闪退是不是插件引起的」

真机上连续两次启动即闪退（v0.1 与 v0.1.1 各一次）。两份 `.ips` 都显示
**崩溃栈上没有任何一帧属于我们的 dylib**。但"不在栈上"不等于"无责任"——
也可能是**镜像被加载**这件事本身触发了宿主的反注入检测。

为了不再一轮一轮猜，v0.1.2 把这个问题拆成**四个互不重叠的台阶**，一轮 CI 全出。

### 0.1 台阶表（真机上按顺序做，**第一个开始崩的台阶就是嫌疑层**）

| 台阶 | dylib | 它做了什么 | 它回答什么 |
|---|---|---|---|
| **0** | *(不注入)* | TrollFools 里**移除** dylib | 宿主自身 / 环境有没有问题 |
| **1** | `EGaosuTidy-minimal.dylib` | `%ctor` **完全为空**（连 `NSLog` 都不调） | 「我们的镜像被 dyld 加载」本身是否被检测 |
| **2** | `EGaosuTidy-dispatchonly.dylib` | `%ctor` 写一行流水 + 一次 `dispatch_async`，块里什么都不做 | 在 `%ctor` 里碰 libdispatch 是否安全 |
| **3** | `EGaosuTidy-nofloat.dylib` | 完整启动流程（Foundation / 文件 IO / 自愈 / 定时任务），**不装悬浮球** | 窗口 / 视图操作有没有问题 |
| **4** | `EGaosuTidy-normal.dylib` | 完整探针 | 正式取数 |

**判读规则（结合启动流水交叉验证，不需要额外跑轮次）：**

```
台阶 0 就崩              → 与我们无关（宿主自身或环境问题）
台阶 0 不崩、台阶 1 崩    → 镜像存在即被检测 → 反注入 / 完整性校验
台阶 1 不崩、台阶 2 崩    → 看流水：
                            有 ctor、无 main-block → dispatch_async 本身（或它之后立刻）
                            两者都没有            → 我们的构造函数第一条语句就没跑成
                                                    （再对照台阶 1：台阶 1 空 ctor 不崩，
                                                     说明"空 ctor 能跑"，那就是那行流水写入的问题）
台阶 2 不崩、台阶 3 崩    → 悬浮球 / 窗口 / 定时器
台阶 3 不崩、台阶 4 崩    → 只剩延迟任务（viewDidAppear 钩子已默认关闭）
```

**为什么 `dispatchonly` 里要在 `%ctor` 写一行流水**：这样"崩在 ctor 里"和"崩在
`dispatch_async` 里"能分开 —— 只看 `.ips` 是分不开的（两者都不带我们的帧）。
代价是 dyld 阶段多三个 syscall（`open`/`write`/`close`），
比 v0.1 在那个阶段做的事（Foundation 初始化 + `sigaction` 覆盖宿主 6 个信号处理器 + `sigaltstack`）
轻得多，风险可接受。**这是刻意的取舍，不是疏忽。**

**操作**：每换一个 dylib，在 TrollFools 里先移除旧的再注入新的，然后启动 App **连开 3 次**。
只要有一次能进到界面，就算这一台阶通过。

### 0.2 ★ 崩溃了怎么把证据拿出来（不用翻文件系统）

App 一崩，悬浮球也就没了 —— 而悬浮球本来是读日志的唯一入口，这是个死结。破法：

> **本次启动发现"上一次没正常结束"时，会自动把启动流水写进系统剪贴板。**
> 所以：**闪退之后直接粘贴**，就能看到「我们崩在哪一步」。

流水长这样（`<单调秒>  <阶段>  [<变体>]`）：

```
14.062  ctor  [dispatchonly]
14.081  main-block  [dispatchonly]
```

正常探针（`normal`）的一次完整启动大约是这样：

```
22.310  ensure-start  [normal]
22.318  paths-ok  [normal]
22.319  guard-ok  [normal]
22.402  overlay-ok  [normal]
22.403  timers-armed  [normal]
25.405  dump+3s  [normal]
28.409  class-scan  [normal]
34.420  confirmed  [normal]
```

**判读**：哪一行是最后一行，就说明崩在那一行**之后**、下一行之前。
连 `ensure-start` 都没有 → `%ctor` 的 `dispatch_async` 块根本没被主队列执行。

也可以手动看文件：`<App 容器>/Library/Caches/eg_tidy_journal.txt`

---

## 1. 两次闪退的证据与判读（事实与推断分开写）

### 1.1 v0.1 —— 2026-09-30 23:21:29

| 项 | 值 |
|---|---|
| App | e高速 **5.10.7**（build 2）/ iOS 16.6.1 |
| bundleID | **`com.sdhsie.westeros.weirwood`** ← 实测，推翻了之前从 Android 包名推断的值 |
| 异常 | `EXC_CRASH` / **SIGBUS**（Bus error: 10） |
| 启动→崩溃 | **0.18 秒** |
| 栈 | `#0 e高速+0x51f21e8` ← `#1 e高速+0x59c1d40` ← `#2 load_images` ← `#3 notifyObjCInit` ← `#4 runInitializersBottomUp` ← … ← `#8 runAllInitializersForMain` |
| 归属 | 崩溃帧 `imgIdx=0`（主二进制）；我们 dylib `imgIdx=43` `base=0x111ef0000` `size=0x18000` → **栈上零帧** |

**判读**：崩溃发生在**宿主某个 image 的 `+load` 正在执行时**。
而 v0.1 的 `%ctor` 恰好在 dyld 阶段做了三件有副作用的事：
① 调 Foundation（`NSSearchPathForDirectoriesInDomains`）
② 用 `sigaction` 覆盖宿主 6 个信号处理器 + `sigaltstack`
③ 文件 IO。

**dyld 阶段是别人的地盘。** 宿主若在 `+load` 里用信号做自检 / 反调试 / 崩溃收集
（国产 App 常见），我们的覆盖会把它的"自检"变成"真崩溃"，而崩溃点自然落在它的代码上
—— 与这份 `.ips` 的形状吻合。**v0.1.1 据此把 `%ctor` 砍到只剩一次 `dispatch_async`。**

### 1.2 v0.1.1 —— 2026-09-30 23:39:19（形状完全不同）

| 项 | 值 |
|---|---|
| 异常 | `EXC_BAD_ACCESS` / SIGBUS，subtype `UNKNOWN_0x101 at 0xf7` |
| 启动→崩溃 | **0.48 秒** |
| 触发线程 | `thread 1` = **`com.apple.root.default-qos`**（全局并发队列），**不是主线程** |
| 帧 | **只有 1 帧**：`imageOffset=247`、`imageIndex=54` —— 而 `usedImages[54]` 是**全零条目**（`base=0 size=0 uuid=0000…`），即 `pc=0xf7` **不属于任何已加载镜像** |
| 寄存器 | `pc = lr = fp = 0xf7`（同一个值，且**未对齐**）；`x1 = SEL "release"`；`x17 = -[__NSCFConstantString release]`；`x2/x14/x15/x16 = __CFConstantStringClassReference` |
| 另一条线程 | `dyld3::MachOLoaded::findClosestSymbol` ← `dyld4::APIs::dladdr` ← `JMCodeProtectKit` ×3 ← `_dispatch_call_block_and_release` ← `_dispatch_root_queue_drain` |

**判读（事实 / 推断分开）：**

- **事实 1**：崩溃线程在**全局并发队列**上，而我们的代码**只跑主队列**。
- **事实 2**：崩溃线程只有一帧，且那一帧**落在任何镜像之外**。
- **事实 3**：`pc / lr / fp` 三个寄存器是**同一个未对齐值 `0xf7`**。真实的指令地址不可能未对齐。
  普通的内存越界会给出一个**指向出错代码的合法 pc** 和一条可读的栈。
  三个寄存器同时被写成同一个垃圾值，说明**线程上下文本身是坏的**（内存被破坏，或被主动覆写），
  不是"简单的野指针解引用"。
- **推断**：第三方加固 SDK `JMCodeProtectKit` 在启动 0.48 秒时正在后台队列上走 `dladdr`
  遍历镜像列表做符号化 —— 这是**完整性校验 / 反注入扫描**的典型形状。

> **结论（必须说清楚）：没有任何证据表明这次崩溃由我们的代码引起。**
> 但也没有证据**排除**"我们的镜像被加载"是触发条件 —— 这是两个不同的问题。
> 这正是台阶表要分开测的东西。

### 1.3 为什么不做"直接反制"

"隐藏我们的镜像不被 `dladdr` / `_dyld_*` 枚举到"听起来是对策，但现在做它是**没有依据的工程**：
判读里的 `JMCodeProtectKit` 也可能只是个良性的 backtrace 符号化器，与崩溃无关。
**先花 10 分钟把台阶 0 / 台阶 1 跑完，再决定要不要做反制。**
顺序反了就会白写一堆代码，还可能把问题弄得更复杂。

---

## 2. 真机操作步骤（探针取数，在台阶 4 通过之后做）

**前置**：TrollStore + TrollFools → 选「e高速」→ 注入 `EGaosuTidy-normal.dylib` → 重启 App。

注入后右上角出现一个蓝色圆点 **EG**（可拖动）：

| 操作 | 作用 |
|---|---|
| **点一下** | 抓当前页面 → 底栏取证 + 当前页视图树 + 广告候选汇总 → 写剪贴板，按钮标题闪一下显示抓到的字节数 |
| **长按**（0.6s） | 完整诊断 → **启动流水** + 底栏取证 + 类名扫描 + 崩溃回读 + 视图树 → 写剪贴板 |
| **拖动** | 移开按钮，避免遮挡 |

**请这样跑：**

1. 停在任意**底栏可见**的页面 → **点一下 EG** → 粘贴回来　→ 回答 **Q1 / Q2**
2. 切到**「我的」页**（滚到能看到那条广告）→ **点一下 EG** → 粘贴回来　→ 回答 **Q3 / Q4**
3. **长按 EG** → 完整诊断 → 粘贴回来　→ 补上启动流水、类名扫描与崩溃记录

> 按钮标题闪成 `xx.xk` 表示**点击生效、文本已进剪贴板**。
> 如果按钮标题不动，说明点击没被收到 —— 那是另一类问题（窗口层级），请告诉我。

---

## 3. 探针要回答的四个问题

目标是全新 App，我们对它的内部结构**零知识**。四条关键信息全部未知，
而**每一条猜错都要白做一版**：

| # | 待回答 | 为什么必须实测 |
|---|---|---|
| **Q1** | 底栏是**系统 `UITabBarController`** 还是**自绘容器**？ | 截图里中间「车主服务」是**凸起**的，这是自绘的典型特征 —— 但**特征不是证据**。系统 tab 过滤 `viewControllers` 即可；自绘底栏只过滤数据层**一个图标都不会动**（"幽灵图标"），必须两层处理 + 手动重排 |
| **Q2** | 5 个 tab 各自的 **VC 类名 / `tabBarItem.title` / `tabBarItem.tag`**？ | 决定"哪个才是「我的」"。同类项目的教训：VC 类名可能**全是** `BaseNavigationController`、`title` 可能**全为空**，只有 `tag` 可用。认身份的字段必须实测，不能猜 |
| **Q3** | 那条广告是 `UICollectionViewCell` / `UITableViewCell` / 还是独立视图？ | 决定隐藏与**收起**方式。`hidden = YES` 只是不画，**布局里那一格还在** —— 藏在页面中部会留下一块空白 |
| **Q4** | 「我的」页是**原生**还是 **H5**？ | 原生方案对 H5 内部元素**完全无效**（H5 里画的广告在原生树上只是个 `WKContentView`），白改一版才发现。dump 里给每个节点打了 `[H5]` 标 |

---

## 4. 构建（CI，本机无 macOS）

```bash
# 单变体（本机/CI 都可）
make EG_VARIANT=normal

# 四个变体（CI 的 build.yml 就是这么干的）
for V in normal nofloat dispatchonly minimal; do
  make clean; rm -rf .theos
  make EG_VARIANT=$V messages=yes 2>&1 | tee build-$V.log
  cp "$(find .theos -name EGaosuTidy.dylib | head -1)" "dist/EGaosuTidy-$V.dylib"
done
```

GitHub Actions（`.github/workflows/build.yml`）在 `macos-latest` 上装 Theos + iPhoneOS SDK + ldid，
**一轮编译出 4 个变体**，并逐个自证"变体标记字符串已嵌入产物"
（防"构建成功但产物是上一个变体残留"这类静默错误）。

**推送前必跑静态预检**（本机没有 macOS，每次推送都是一轮 CI，所以这步不能省）：

```bash
python tools/preflight.py Tweak.xm     # 退出码 0 = 可以推送
```

它先**自证检查器本身没瞎**（拿故意写坏的文件喂每个检查器，必须报错），
再对 `Tweak.xm` 跑四项检查：括号平衡、调用/引用早于定义、字符串闭合、ObjC++ 类型陷阱。
`.xm` 按 **Objective-C++** 编译，隐式函数声明是**硬 error**（`-Wno-error` 救不了）。

> **Makefile 里的 `GO_EASY_ON_ME := 1` 不能删。** Theos 的 `common.mk` 里有：
> `ifneq ($(GO_EASY_ON_ME),$(_THEOS_TRUE))` → `_THEOS_INTERNAL_CFLAGS += -Werror`。
> 也就是 `-Werror` 是 Theos 自己加的，加在**内部 CFLAGS** 里 —— 我们自己写的 `-Wno-error`
> 能不能压住它取决于两者先后顺序，而那个顺序不写在项目文件里。
> 靠顺序赢是运气；`GO_EASY_ON_ME=1` 是官方开关，一行关掉 `-Werror` 和 logos 的 `warnings=error`。

---

## 5. 探针输出什么（对照检查）

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

## 6. 已知假设与风险（如实标注）

| 项 | 状态 |
|---|---|
| **Bundle ID** | ✅ **已实测**：`com.sdhsie.westeros.weirwood`（来源：真机 `.ips`）。此前写的 `com.sdhs.easy.high.road` 是从小米/应用宝/OPPO 三处 **Android 包名推断**的 —— **推断错了**。iOS 与 Android 的 bundle id 不保证一致 |
| **目标 App 版本** | ✅ **已实测**：e高速 **5.10.7**（build 2），iOS 16.6.1 |
| **闪退归因** | ⚠️ **未定论**。两次崩溃栈上都没有我们的帧；v0.1.1 那次触发线程在后台队列、线程上下文已损坏。用台阶表判定，**不预先下结论** |
| **界面结构** | ⚠️ **仍全部未知**。还没走到界面。台阶 4 通过后再取 dump |
| **`JMCodeProtectKit`** | ⚠️ **未识别**。只知道它调 `dladdr`；厂商与用途未确认。是否与崩溃相关**未证实** |
| TrollFools 注入与 plist Filter | 注入模式下 `Filter` 不参与判定（dylib 由 dyld 无条件加载）—— `.ips` 里确实出现了 `EGaosuTidy.dylib`，印证了这点。若改用 deb 安装（Sileo/Zebra），Filter 必须准确，所以已同步为实测值 |

---

## 7. 目录结构

```
EGaosuTidy/
├── Tweak.xm                    探针本体（唯一需要读的源文件）
├── Makefile                    含 4 变体机制 + GO_EASY_ON_ME
├── control / *.plist           Theos 工程配置
├── tools/                      推送前静态预检（从既有项目复用，通用）
│   ├── preflight.py            一次跑完全部检查，并先自证检查器没瞎
│   ├── chk.py                  括号/引号平衡（tokeniser-aware）
│   ├── audit.py                调用早于定义 / 全局引用早于定义 / 递归 block 缺 __block
│   ├── strchk.py               字符串字面量未闭合
│   ├── objcpp.py               ObjC 合法但 ObjC++ 是硬 error 的构造
│   ├── ips.py                  iOS 15+ .ips 崩溃报告解析（两个 JSON 文档拼在一个文件里）
│   └── ipsdiff.py              两份 .ips 的结构化对比（崩溃帧归属 / 保护类 SDK / 镜像差异）
├── docs/                       崩溃现场留档
└── .github/workflows/build.yml CI：一轮出 4 个变体
```

---

## 8. 安全底线（探针阶段）

- **探针不改任何东西**：不隐藏、不删除、不改约束、不拦弹窗、不动数据。产出只有文本。
- **`%ctor` 只做一件事：一次 `dispatch_async`。** 其余全部（崩溃日志路径、文件 IO、
  信号处理器、钩子）都放进那个块里，等主队列执行。
  **`%ctor` 运行在 dyld 的 `runAllInitializersForMain → runInitializersBottomUp →
  notifyObjCInit → load_images` 之中** —— 也就是说，**它跑在宿主自己的初始化过程里**，
  此时宿主的 `+load` 可能还在执行。在那里做的任何有副作用的事，都发生在别人的地基上。
  v0.1 就是在这里翻了车，实测证据是一份 0.18 秒的 SIGBUS `.ips`。
- **默认不装信号处理器**（`ENABLE_CRASH_HANDLERS 0`）。覆盖宿主自己的 `sigaction` 会把它的
  "自检"变成"真崩溃"。失去的只是爆栈类崩溃的现场取证，而系统 `.ips` 同样完整。
- **默认不装 `viewDidAppear:` 钩子**（`ENABLE_VIEWDIDAPPEAR_HOOK 0`，v0.1.2 的削减）。
  收益≈0、风险>0 —— 探针的产出靠点按钮和定时 dump，这个钩子只多一条日志，
  却要在宿主**最热的类**上换 IMP。
- 查方法一律 `class_copyMethodList` 手走父类链，**绝不用 `class_getInstanceMethod`**
  —— 后者会强制 `+initialize`。
- 只 hook **一个类的一个 selector**，一个 shim + 一个全局 orig IMP。
  **不装"每个实现类各一份"的通用安装器** —— 共享 shim 无法区分直接调用与 `[super]` 调用，
  会无限递归爆栈。
- **启动自愈**：同一构建连续 3 次启动异常 → 第 4 次启动不装任何钩子，只留悬浮球。
  计数绑定构建令牌，换构建自动归零。
- 崩溃取证带 `sigaltstack` + `SA_ONSTACK`：否则爆栈类崩溃在已耗尽的栈上再崩一次，
  自己的日志会是**零字节**，只剩系统 `.ips`。
- 诊断缓冲用**滚动窗口 + 显式截断标记**，绝不"写满就静默停止"。
- 启动流水超过 128 KB 自动整份轮换，不会无限增长。

**后续规则版同样不做的事**：不 hook 网络请求 / 签名 / 鉴权；不伪造数据；不绕过付费；
不修改服务端可见的任何状态。只做**视图层与导航层的显示与隐藏**。
