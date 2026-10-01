// ============================================================================
// Tweak.xm — e高速 (com.sdhsie.westeros.weirwood) 界面精简 Tweak
// v0.1.2-probe —— **纯探针：只取证，不改任何界面行为**
// ============================================================================
//
// 目标（Shawn 提出，2026-09-30）：
//   1) 底栏 5 个 tab（首页 / 车主服务 / 会员服务 / 商城 / 我的）→ **只保留「我的」**；
//   2) 「我的」页中，「我的订单」与「我的服务」之间的**图片广告**
//      （「移动积分兑高速通行券」横幅）一并去掉。
//
// ---------------------------------------------------------------------------
// v0.1.2 相对 v0.1.1 改了什么（三件，全部有据）
// ---------------------------------------------------------------------------
//   ① **削减**：探针阶段关掉 UIViewController.viewDidAppear: 钩子
//      （ENABLE_VIEWDIDAPPEAR_HOOK 0）。收益≈0、风险>0 —— 理由见配置区。
//   ② **判定仪器**：新增「启动流水」+「崩溃时自动镜像到剪贴板」。
//      两次崩溃我们的代码都**不在崩溃栈上**，光看 .ips 无法回答"我们走到哪一步了"。
//      流水每启动一行，崩溃后粘贴剪贴板就知道停在哪。
//   ③ **一次问完**：构建变体机制 —— 一轮 CI 出 4 个 dylib（minimal / dispatchonly /
//      nofloat / normal），把"是不是我们引起的"拆成互不重叠的台阶。见配置区那一节。
//
// ---------------------------------------------------------------------------
// 为什么 v0.1 是纯探针，而不是直接写规则
// ---------------------------------------------------------------------------
// 目标是全新 App，我们对它的内部结构**零知识**。四条关键信息全部未知，
// 而每一条猜错都要白做一版 —— 每一版 = 一轮 CI + 一次真机注入：
//
//   Q1 底栏是**系统 UITabBarController** 还是**自绘容器**？
//      截图里中间「车主服务」是**凸起**的 —— 这是自绘的典型特征，但**特征不是证据**。
//      两种情况的改法完全不同（前者过滤 viewControllers，后者要处理自绘视图 + 手动重排）。
//   Q2 5 个 tab 各自的 **VC 类名 / tabBarItem.title / tabBarItem.tag** 是什么？
//      决定"哪个才是「我的」"。无忧行的教训：VC 类名可能全是 BaseNavigationController，
//      title 可能全为空，只有 tag 可用 —— 认身份的字段必须**实测**。
//   Q3 那条广告是 UICollectionViewCell / UITableViewCell / 还是独立视图？
//      决定用哪种隐藏与收起方式（隐藏 cell 不会回收布局空间，会留白）。
//   Q4 页面是**原生**还是 **H5**？
//      原生方案对 H5 内部元素**完全无效** —— H5 里画的广告在原生树上只是个 WKContentView，
//      白改一版才发现。所以 dump 里必须给节点打 [H5] 标。
//
// ---------------------------------------------------------------------------
// 使用方式（真机，TrollFools 注入 dylib 后重启 App）
// ---------------------------------------------------------------------------
//   右上角出现一个蓝色圆点 **EG**（可拖动）：
//     · **点一下** = 抓当前页面 → 底栏取证 + 当前页视图树 + 广告候选汇总
//                    → 写入剪贴板，按钮标题闪一下显示抓到的字节数（自证"点到了"）
//     · **长按**   = 完整诊断（含**启动流水**、启动期自动 dump、崩溃日志回读、类名扫描）→ 写入剪贴板
//
//   ★ 如果 App 启动就闪退（悬浮球根本来不及出现）：
//     本次启动检测到**上一次没正常结束**时，会**自动把启动流水写进系统剪贴板**。
//     所以：闪退之后**直接粘贴**，就能把「我们崩在哪一步」的证据拿出来 ——
//     不需要 Filza，也不需要翻 App 容器目录。
//     也可以手动看文件：<App 容器>/Library/Caches/eg_tidy_journal.txt
//
//   请按这个顺序跑，然后把两次粘贴的内容发回：
//     第 1 步：停在任意**底栏可见**的页面，点一下 EG → 回答 Q1 / Q2
//     第 2 步：切到**「我的」页**（滚到能看到那条广告），点一下 EG → 回答 Q3 / Q4
//     第 3 步（可选）：长按 EG → 完整诊断（含启动期 dump 与类名扫描）
//
// ---------------------------------------------------------------------------
// ★ 探针不改任何东西
// ---------------------------------------------------------------------------
//   不隐藏、不删除、不改约束、不拦弹窗、不动数据。它的全部产出就是文本。
//   所以不存在"探针把界面弄坏"的风险 —— 唯一的风险是崩溃，
//   而那由「启动自愈」+「崩溃取证」兜住（见下）。
//
// ---------------------------------------------------------------------------
// 安全设计（每条都对应本项目翻过的一次车，详见 skill ios-theos-dylib-ci）
// ---------------------------------------------------------------------------
//   · %ctor **只做一件事**：一次 dispatch_async，其余全部丢到主队列。
//     诊断钩子绝不放在启动路径上 —— 一次"在 dyld 阶段全进程扫类"曾把目标 App
//     打到**完全打不开**（且 @try/@catch 救不了：异常在 dispatch_once 里被 libdispatch
//     边界吞成 std::terminate）。
//     v0.1 在这里翻过车（%ctor 里调 Foundation + 覆盖宿主信号处理器），v0.1.1 修掉。
//   · 查方法一律 class_copyMethodList 手走父类链，**绝不用 class_getInstanceMethod**
//     —— 后者会强制 +initialize，全进程遍历等于让每个类都在 dyld 阶段初始化一次。
//   · 只 hook **一个类的一个 selector**（UIViewController.viewDidAppear:），
//     一个 shim + 一个全局 orig IMP。**不装"每个实现类各一份"的通用安装器** ——
//     共享 shim 无法区分直接调用与 [super] 调用，会无限递归爆栈（511 帧实锤过）。
//   · 诊断缓冲用**滚动窗口 + 显式截断标记**，绝不"写满就静默停止" ——
//     那会让"只发生了这些"和"只留下了这些"看起来一样。
//   · 信号处理器里只用 open/write/snprintf/backtrace_symbols_fd（异步信号安全），
//     并配 sigaltstack + SA_ONSTACK：否则爆栈类崩溃在已经耗尽的栈上再崩一次，
//     自己的崩溃日志会是**零字节**，只剩系统 .ips。
//   · 延迟任务一律走 EGAfterOnMain（内部 @try），避免异常打到 libdispatch 边界。
//   · 全进程扫类前先按"类名关键词"廉价预筛，再对命中的少量类走方法链 ——
//     对几万个类各做一次 class_copyMethodList 会卡住启动一两秒。
//   · 扫描结果剔除"万能类"（对不存在的 selector 也返回 YES 的类），否则
//     12 个不相关的 selector 会返回同样的 5 个类，全是噪声。
//   · 悬浮球**不自建 UIWindow**（iOS 13+ 用 initWithFrame: 建的 window 可能没有 scene，
//     只是个孤儿窗口，永远不显示）—— 直接挂到宿主窗口上，并定时置顶。
// ============================================================================

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <execinfo.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>

// 不依赖 substrate / ellekit 头文件：直接用 Objective-C runtime 替换方法实现。
// TrollFools 注入的进程内同样可用，同时消掉一类"头文件找不到"的构建失败。

// ============================== 配置 ==============================

#define EG_TAG              "EGaosuTidy"
#define EG_VERSION          "1.0.0-release"
// ★ bundle id：真机 .ips 实测（2026-09-30 23:21:29）是 com.sdhsie.westeros.weirwood。
//   之前写的 com.sdhs.easy.high.road 是从三个 Android 商店包名**推断**的 —— 推断错了。
//   iOS 与 Android 的 bundle id 不保证一致，这条只能靠实测。
#define EG_BUNDLE_ID        "com.sdhsie.westeros.weirwood"

#define ENABLE_CRASH_LOG         1   // 崩溃取证（阶段标记 + 日志回读）
// ★ 信号处理器开关，默认 **0（关）** —— v0.1.1 的改动之一。
//   理由见 %ctor 上方那段：v0.1 在 dyld 阶段用 sigaction 覆盖了宿主 6 个信号处理器
//   并 sigaltstack 覆盖备用栈，那是在**别人的初始化过程中**动别人的地基。宿主若在
//   +load 里用信号做自检 / 反调试，我们的覆盖会把它变成真崩溃。
//   关掉只损失"爆栈 / 无限递归"的现场取证 —— 那类崩溃系统 .ips 里同样有完整栈，
//   本次这个崩溃（v0.1 真机 SIGBUS）就是靠 .ips 定位的，不是靠这个处理器。
#define ENABLE_CRASH_HANDLERS    0
#define ENABLE_FLOAT_BUTTON      1   // 悬浮按钮
#define ENABLE_TABBAR_FORENSICS  1   // 底栏构造取证
#define ENABLE_CLASS_SCAN        1   // 全进程类名扫描（一次性，启动后跑）
#define ENABLE_AUTO_DUMP         1   // 启动后自动 dump 一次底栏（用户没点也能拿到数据）

// ============================================================================
// ★★ 正式版发布开关（EG_RELEASE） ==========================================
// ============================================================================
// 1 = 干净交付。逐条说明**关掉什么、为什么关、留下什么**：
//
//   关：ENABLE_FLOAT_BUTTON —— 右上角那个 EG 圆圈。它是**取数工具**，不是功能。
//       目标达成后它就是屏幕上多余的一个圆，Shawn 明确要求去掉。
//   关：ENABLE_AUTO_DUMP / ENABLE_CLASS_SCAN —— 启动后定时 dump 底栏 + 全进程类名扫描。
//       两者的唯一消费者是"长按 EG 看诊断"，按钮没了它们就没人读；
//       而全进程类名扫描（1597 个类）每次启动都要跑一遍，纯属浪费。
//   留：EG_ENABLE_RULES —— 三条规则是**功能本体**，必须开着。
//   留：ENABLE_LAUNCH_JOURNAL / EG_JOURNAL_MIRROR —— 这是**唯一的崩溃出口**。
//       悬浮球没了之后，万一将来某版启动就崩，只剩"上次未正常结束 → 流水镜像到剪贴板"
//       这一条路能拿到证据。它只在**上次没走到 confirmed** 时才写，正常使用不碰剪贴板。
//   缩：EG_DIAG_CAP —— 诊断缓冲没有读者了，从 200000 缩到 8000，别白占内存。
//
// ★ 审计过的边界（Gotcha 30：别以为一个 *_FORENSICS 开关只管日志）：
//   · ENABLE_FLOAT_BUTTON 只包住 EGInstallOverlay() 一个调用点，不改任何规则行为
//   · ENABLE_AUTO_DUMP / ENABLE_CLASS_SCAN 只包住三个 EGAfterOnMain 定时块
//   · ENABLE_TABBAR_FORENSICS 全文**没有任何 #if 使用它** —— 它其实什么都不gate
// ============================================================================
#define EG_RELEASE               1

#if EG_RELEASE
#  undef  ENABLE_FLOAT_BUTTON
#  define ENABLE_FLOAT_BUTTON    0
#  undef  ENABLE_AUTO_DUMP
#  define ENABLE_AUTO_DUMP       0
#  undef  ENABLE_CLASS_SCAN
#  define ENABLE_CLASS_SCAN      0
#  undef  EG_DIAG_CAP
#  define EG_DIAG_CAP            8000
#endif

// ★ 探针阶段默认**不装** UIViewController.viewDidAppear: 钩子（v0.1.2 的削减）。
//   收益≈0：探针的全部产出靠「点 EG」+ 启动后定时 dump 拿到，这个钩子只额外补一条
//   「VC 首次出现」的日志。
//   风险>0：它要在宿主**最热的类**上换 IMP。宿主若有方法完整性校验 / 方法 IMP 表比对，
//   这正好是最容易被发现的一处 —— 而探针阶段我们**不需要**这个信息。
//   收益≈0、风险>0 的事，探针不做。（规则版需要它，到时候再开。）
#define ENABLE_VIEWDIDAPPEAR_HOOK 0

// ★ 启动流水（v0.1.2 新增）—— 判定「是不是我们引起的」的**直接证据**。
//   场景：App 启动 0.5 秒即崩，我们的代码**不在崩溃栈上**（两次 .ips 都是这样）。
//   那到底我们走到哪一步了？光看系统 .ips 答不了这个问题。
//   做法：每次启动往 Caches/eg_tidy_journal.txt 追加一行「单调时钟毫秒 + 阶段名 + 变体名」。
//   崩溃后读这个文件就知道：
//     · 连 ctor 那一行都没有 → 我们的构造函数根本没跑（崩在 dyld 更早的阶段）
//     · 停在某一行           → 崩在那一行**之后**、下一行之前 —— 这就是定位
//   写入用纯 POSIX open/write/close + clock_gettime，**不碰 Foundation**
//   （早期阶段 Foundation 未必可用，且碰 Foundation 本身就是 v0.1 翻车的原因之一）。
#define ENABLE_LAUNCH_JOURNAL    1

// ★ 流水镜像到剪贴板（v0.1.2 新增）—— 解决"App 崩了就点不到悬浮球"的死结。
//   悬浮球是读流水的唯一入口，可 App 一崩，悬浮球也就没了 —— 这是个死循环。
//   破法：**上一次启动没有走到 confirmed 时**（即大概率崩过），本次启动就把流水
//   写进**系统剪贴板**。剪贴板跨进程存活，崩溃后 Shawn 直接粘贴就能把证据拿出来，
//   不需要 Filza、不需要翻容器目录。
//   只在"上次没正常结束"时才写 —— 正常使用时不会反复覆盖你的剪贴板。
#define EG_JOURNAL_MIRROR        1

// 是否允许在 %ctor（dyld 阶段）写一行启动流水。
//   默认 **0** —— dyld 阶段是别人的地盘，v0.1 就是在这里翻的车。
//   只有 dispatchonly 变体打开：那一版的目的正是**测 %ctor 本身**，
//   而 open/write/close 是三个 syscall，比 v0.1 做的三件事（Foundation 初始化 +
//   sigaction 覆盖宿主 6 个信号处理器 + sigaltstack）轻得多，风险可接受。
#define EG_JOURNAL_IN_CTOR       0

// 诊断缓冲上限（滚动窗口保留最新 N 字符，超出即丢弃**最旧**的部分并标记截断）
#define EG_DIAG_CAP          200000

// 页面 dump 预算：长页面（表格型）在到达底部广告位之前就会耗尽小预算
#define EG_DUMP_MAX_DEPTH    12
#define EG_DUMP_MAX_NODES    1500

// "横幅形态"判定：宽 >=150、高 >=30、宽高比 1.8~8 —— 用于挑出广告候选
#define EG_AD_CAND_MIN_W       150.0
#define EG_AD_CAND_MIN_H        30.0
#define EG_AD_CAND_MIN_RATIO     1.8
#define EG_AD_CAND_MAX_RATIO     8.0
#define EG_AD_CAND_MAX_REPORT   25

// 启动自愈：同一构建连续 N 次启动异常 → 本次启动不装任何钩子
#define EG_LAUNCH_GUARD_MAX      3

// ★ 最小验证模式：打开后 %ctor 里连 EGEnsureStarted 都不调，什么都不做。
//   用途：如果 v0.1.1 仍然闪退，用这一版做**对照实验** ——
//     · 最小模式**不崩** → 问题在我们的代码，继续往下查；
//     · 最小模式**照崩** → 问题在"注入行为本身被宿主检测"（反注入 / 完整性校验），
//       %ctor 再怎么减也没用，要换注入方式或另想办法。
//   默认 0。
#define EG_MINIMAL_CTOR          0

// ============================================================================
// ★★ 构建变体（v0.1.2）—— 一轮 CI 出 4 个 dylib，把「是不是我们引起的」一次问完
// ============================================================================
//
// 为什么做成变体而不是一版一版试：每一版 = 一轮 CI + 一次真机注入。
// 把"我们的代码在哪一步出错"拆成**互不重叠的台阶**，一轮全出，真机上按顺序注入即可定位。
//
//   台阶 0  (手动)   TrollFools 里**移除** dylib 后启动   → 测「宿主自身 / 环境」
//   台阶 1  minimal     %ctor 完全为空（连 NSLog 都不调） → 测「我们的镜像被 dyld 加载」本身
//   台阶 2  dispatchonly %ctor 只写一行流水 + 一次 dispatch_async，块里什么都不做
//                                                        → 测「在 %ctor 里碰 libdispatch」
//   台阶 3  nofloat     完整启动流程，但不装悬浮球        → 测「窗口 / 定时器 / 视图操作」
//   台阶 4  normal      完整探针（正式取数用）
//
// 判读规则（结合启动流水交叉验证，不需要额外跑轮次）：
//   台阶 0 就崩              → 与我们无关（宿主自身问题）
//   台阶 0 不崩、台阶 1 崩    → 镜像存在即被检测（反注入 / 完整性校验）
//   台阶 1 不崩、台阶 2 崩    → 看流水：
//                               有 ctor、无 main-block → dispatch_async 本身出问题
//                               两者都没有            → 构造函数第一条语句就没跑成
//   台阶 2 不崩、台阶 3 崩    → 悬浮球 / 窗口 / 定时器
//   台阶 3 不崩、台阶 4 崩    → 只剩延迟任务（viewDidAppear 钩子已默认关）
//
// 为什么 dispatchonly 要在 %ctor 里写一行流水：这样"崩在 ctor 里"和"崩在 dispatch_async 里"
// 能分开 —— 只看 .ips 是分不开的（两者都不带我们的帧）。代价是 dyld 阶段多三个 syscall
// （open/write/close），比 v0.1 在那个阶段做的事（Foundation 初始化 + sigaction 覆盖宿主
// 6 个信号处理器 + sigaltstack）轻得多。**这是刻意的取舍，不是疏忽。**
//
// CI 侧通过 -DEG_VARIANT_xxx=1 选择（见 Makefile 的 EG_VARIANT）；本机默认 normal。
#ifndef EG_VARIANT_MINIMAL
#  define EG_VARIANT_MINIMAL      0
#endif
#ifndef EG_VARIANT_DISPATCHONLY
#  define EG_VARIANT_DISPATCHONLY 0
#endif
#ifndef EG_VARIANT_NOFLOAT
#  define EG_VARIANT_NOFLOAT      0
#endif

#if EG_VARIANT_MINIMAL
#  define EG_VARIANT_TAG "minimal"
#elif EG_VARIANT_DISPATCHONLY
#  define EG_VARIANT_TAG "dispatchonly"
#elif EG_VARIANT_NOFLOAT
#  define EG_VARIANT_TAG "nofloat"
#else
#  define EG_VARIANT_TAG "normal"
#endif

// 变体对既有开关的覆盖（#undef 后再 define，保证命令行 -D 与文件内默认值不打架）
#if EG_VARIANT_MINIMAL
#  undef EG_MINIMAL_CTOR
#  define EG_MINIMAL_CTOR 1
#endif
#if EG_VARIANT_DISPATCHONLY
#  undef EG_JOURNAL_IN_CTOR
#  define EG_JOURNAL_IN_CTOR 1
#endif
#if EG_VARIANT_NOFLOAT
#  undef ENABLE_FLOAT_BUTTON
#  define ENABLE_FLOAT_BUTTON 0
#endif

// 类名扫描关键词（只用来**报告**，不用来改行为）
#define EG_SCAN_KEYWORDS_TAB   @[@"TabBar", @"Tabbar", @"TabItem", @"TabButton", @"TabView", @"TabController", @"BottomBar", @"MainTab"]
#define EG_SCAN_KEYWORDS_AD    @[@"Banner", @"Advert", @"AdView", @"Promot", @"Popup", @"Splash", @"Market", @"Operat"]
#define EG_SCAN_KEYWORDS_MINE  @[@"Mine", @"MyCenter", @"Personal", @"UserCenter", @"Member", @"Profile"]

// ============================== 全局（全部前置，避免"先用后定义"） ==============================

static char gEGCrashLogPath[512] = {0};
static char gEGJournalPath[512]  = {0};
static volatile const char *gEGStage = "启动";

static NSMutableString *gEGDiag = nil;
static BOOL             gEGDiagTruncated = NO;
static NSString        *gEGCrashReport = nil;

static IMP  gEGOrigViewDidAppear = NULL;
static BOOL gEGVDAInstalled      = NO;

static NSHashTable<UIViewController *> *gEGVCLive = nil;
static NSMutableSet<NSString *>        *gEGSeenVCClasses = nil;
static __weak UIViewController          *gEGLastVC = nil;

static UIWindow *gEGHostWindow = nil;
static UIButton *gEGButton     = nil;
static id        gEGProxy      = nil;
static dispatch_source_t gEGTopTimer = NULL;

static BOOL gEGStarted      = NO;
static BOOL gEGGuardTripped = NO;

// ============================== 前向声明（全部前置） ==============================
// 为什么集中放在这里：.xm 按 Objective-C++ 编译，**隐式函数声明是硬错误**（不是 warning），
// 且 -Wno-error 救不了。把声明集中前置，任何实现顺序都不会踩这个坑。

static const char *EGStageText(void);
static void EGStageSet(const char *s);
static void EGAppendCrashFile(const char *text);
static void EGSignalHandler(int sig);
static void EGExceptionHandler(NSException *e);
static void EGInitCrashLogPath(void);
static void EGInstallCrashHandlers(void);
static void EGReadBackCrashLog(void);

// 启动流水：纯 POSIX，异步信号安全，早期（含 %ctor）也能写
static void EGInitJournalPath(void);
static void EGJournal(const char *stage);
static void EGJournalRotate(void);
static NSString *EGJournalTail(NSUInteger maxBytes);
static BOOL EGLastLaunchUnclean(void);

static const char *EGBuildToken(void);
static int  EGLaunchGuardCheck(void);
static void EGLaunchGuardClear(void);

static Method EGFindMethodInChain(Class c, SEL sel, Class *outOwner);
static Method EGSafeInstanceMethod(Class c, SEL sel);
static Method EGOwnMethod(Class c, SEL sel);
static BOOL   EGIsDescendantOf(Class c, Class root);
static BOOL   EGClassAnswersEverything(Class c);

static void EGDiag(NSString *fmt, ...);
static NSString *EGDiagSnapshot(void);
static void EGAfterOnMain(double delay, dispatch_block_t block);

static NSArray<UIWindow *> *EGAllWindows(void);
static UIViewController *EGCurrentVC(void);
static NSArray *EGChildrenOf(UIViewController *vc);
static NSString *EGVCChainOf(id vc, NSUInteger maxDepth);
static UIView *EGRootViewOfCurrentScreen(void);

static BOOL EGIsH5Hosted(UIView *v);
static BOOL EGIsBannerShaped(UIView *v);
static NSString *EGNodeTagOf(UIView *v);
static NSString *EGDescribeNode(UIView *v, NSString *indent);
static void EGWalkNode(UIView *v, NSUInteger depth, NSUInteger maxDepth,
                       NSUInteger *budget, NSMutableString *s);
static NSString *EGDumpViewTree(UIView *root, NSUInteger maxDepth, NSUInteger maxNodes);
static NSString *EGBannerCandidates(UIView *root);

static void EGCollectTabBarControllers(UIViewController *vc, NSMutableArray *out, NSUInteger depth);
static NSArray *EGFindTabBarControllers(void);
static NSString *EGDescribeVCArray(NSArray *arr);
static NSString *EGDescribeTabBar(UITabBar *tb);
static NSString *EGDescribeTabBarController(UITabBarController *tbc);
static NSString *EGTabBarForensics(void);
static NSString *EGScanTabBarLikeClasses(void);

static BOOL EGClassNameMatchesAny(NSString *n, NSArray<NSString *> *kws);
static NSString *EGScanClassNames(NSArray<NSString *> *keywords, NSUInteger maxOut);

// v0.2 规则引擎（前向声明）
static BOOL EGIsMineTabVC(UIViewController *vc);
static void EGApplyTabBarRule(UITabBarController *tbc, const char *reason);
static void EGApplyMineAdRule(UIView *root, const char *reason);
static void EGApplyAllRules(UITabBarController *tbc, const char *reason);
static void EGInstallHeightHook(void);
static void EGInstallRulesHooks(void);
static void EGWatchMinePage(void);
static NSArray *EGFindTabBarControllers(void);
static UITableView *EGEnclosingTableView(UIView *v, NSIndexPath **outIP);
static BOOL EGIsAdRowRegistered(UITableView *tv, NSIndexPath *ip);

static void EGSetClipboard(NSString *text);
static void EGFlashButton(NSString *text);
static void EGInstallOverlay(void);

#if ENABLE_VIEWDIDAPPEAR_HOOK
static void EGViewDidAppearHook(id self, SEL _cmd, BOOL animated);
#endif
static void EGInstallViewDidAppearHook(void);
static void EGEnsureStarted(void);
static void EGCaptureCurrentPage(NSString *why);
static void EGCaptureFull(void);

// ============================== 阶段标记 + 崩溃取证 ==============================

// volatile 全局不能直接喂给 [NSString stringWithUTF8String:]（丢限定符在 C++ 里是硬错误），
// 统一走这个 accessor 做一次 cast。读取一个全局 + cast 是异步信号安全的，
// 所以崩溃处理器里也能用。
static const char *EGStageText(void) {
    return gEGStage ? (const char *)gEGStage : "?";
}

static void EGStageSet(const char *s) {
    gEGStage = s;
}

static void EGInitCrashLogPath(void) {
    @autoreleasepool {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        NSString *base = dirs.count ? dirs[0] : @"/tmp";
        NSString *path = [base stringByAppendingPathComponent:@"eg_tidy_crash.log"];
        const char *utf8 = path.UTF8String;
        if (!utf8) return;
        size_t n = strlen(utf8);
        if (n >= sizeof(gEGCrashLogPath)) n = sizeof(gEGCrashLogPath) - 1;
        memcpy(gEGCrashLogPath, utf8, n);
        gEGCrashLogPath[n] = '\0';
    }
}

// ---------------------------------------------------------------------------
// 启动流水
// ---------------------------------------------------------------------------
// 为什么**不走 Foundation**：这个函数要在 %ctor（dyld 阶段）也能调。
// 而 v0.1 翻车的三件事之一就是"在 dyld 阶段调 Foundation"。
// getenv("HOME") 读的是 dyld 早就铺好的 environ，纯 libc，零副作用。
// iOS 上 App 进程的 HOME 就是自己的容器根，Caches 恒为 $HOME/Library/Caches。
static void EGInitJournalPath(void) {
    if (gEGJournalPath[0]) return;
    const char *home = getenv("HOME");
    if (!home || !home[0]) return;
    char buf[512];
    int n = snprintf(buf, sizeof(buf), "%s/Library/Caches/eg_tidy_journal.txt", home);
    if (n <= 0) return;
    size_t m = ((size_t)n < sizeof(buf)) ? (size_t)n : (sizeof(buf) - 1);
    if (m >= sizeof(gEGJournalPath)) m = sizeof(gEGJournalPath) - 1;
    memcpy(gEGJournalPath, buf, m);
    gEGJournalPath[m] = '\0';
}

// 流水超过 128 KB 就整份丢掉重来（每次启动检查一次，够廉价）。
// 不设上限的话，一天开关几十次就会攒出几 MB 的无用文件。
static void EGJournalRotate(void) {
#if ENABLE_LAUNCH_JOURNAL
    if (!gEGJournalPath[0]) return;
    struct stat st;
    if (stat(gEGJournalPath, &st) == 0 && st.st_size > (off_t)(128 * 1024)) {
        unlink(gEGJournalPath);
    }
#endif
}

// 追加一行：<单调秒.毫秒>  <阶段>  [<变体>]
// 用**单调时钟**不用墙上时钟：格式化日期要碰 Foundation，且墙上时钟会跳。
// 单调秒是进程内相对时间，配合 .ips 的 uptime 正好能对上（.ips 也是这么算的）。
static void EGJournal(const char *stage) {
#if ENABLE_LAUNCH_JOURNAL
    if (!stage) return;
    EGInitJournalPath();
    if (!gEGJournalPath[0]) return;
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return;
    char line[256];
    int n = snprintf(line, sizeof(line), "%lld.%03ld  %s  [%s]\n",
                     (long long)ts.tv_sec, ts.tv_nsec / 1000000L, stage, EG_VARIANT_TAG);
    if (n <= 0) return;
    size_t len = ((size_t)n < sizeof(line)) ? (size_t)n : (size_t)(sizeof(line) - 1);
    int fd = open(gEGJournalPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    ssize_t ig = write(fd, line, len);
    (void)ig;
    close(fd);
#else
    (void)stage;
#endif
}

// 读回流水尾部 —— 长按 EG 的完整诊断里会带上它，这样 Shawn 不用去翻文件系统
static NSString *EGJournalTail(NSUInteger maxBytes) {
#if ENABLE_LAUNCH_JOURNAL
    @autoreleasepool {
        EGInitJournalPath();
        if (!gEGJournalPath[0]) return @"(流水路径未初始化)";
        NSString *p = [NSString stringWithUTF8String:gEGJournalPath];
        NSData *d = [NSData dataWithContentsOfFile:p];
        if (!d || d.length == 0) return @"(流水文件为空或不存在)";
        NSData *tail = d;
        BOOL cut = NO;
        if (d.length > maxBytes) {
            tail = [d subdataWithRange:NSMakeRange(d.length - maxBytes, maxBytes)];
            cut = YES;
        }
        NSString *s = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
        if (!s) return @"(流水不是合法 UTF-8)";
        if (cut) return [@"…（只显示尾部）…\n" stringByAppendingString:s];
        return s;
    }
#else
    (void)maxBytes;
    return @"(ENABLE_LAUNCH_JOURNAL=0)";
#endif
}

// 判读「上一次启动是否异常结束」。
// 必须**在写本次 ensure-start 之前**调用 —— 否则从后往前找到的第一个 ensure-start
// 就是本次这一行，而它后面当然没有 confirmed，会永远判成"异常"。
// 逻辑：从后往前定位**最后一个** ensure-start（= 上一次启动的开头），
//       看它之后到文件末尾之间有没有 confirmed。没有 = 上次没走完 = 异常结束。
static BOOL EGLastLaunchUnclean(void) {
#if ENABLE_LAUNCH_JOURNAL
    @autoreleasepool {
        NSString *tail = EGJournalTail(8192);
        if (!tail.length) return NO;
        NSArray *lines = [tail componentsSeparatedByString:@"\n"];
        NSInteger lastStart = -1;
        for (NSInteger i = (NSInteger)lines.count - 1; i >= 0; i--) {
            NSString *l = lines[(NSUInteger)i];
            if ([l rangeOfString:@"ensure-start"].location != NSNotFound) {
                lastStart = i;
                break;
            }
        }
        if (lastStart < 0) return NO;
        for (NSUInteger i = (NSUInteger)lastStart; i < lines.count; i++) {
            if ([lines[i] rangeOfString:@"confirmed"].location != NSNotFound) return NO;
        }
        return YES;
    }
#else
    return NO;
#endif
}

// 崩溃日志写入：只用 open/write/close（异步信号安全）。
static void EGAppendCrashFile(const char *text) {
    if (!text || !gEGCrashLogPath[0]) return;
    int fd = open(gEGCrashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    ssize_t ignored = write(fd, text, strlen(text));
    (void)ignored;
    close(fd);
}

static void EGSignalHandler(int sig) {
    char buf[512];
    int n = snprintf(buf, sizeof(buf), "\n===== SIGNAL %d =====\nstage=%s\n", sig, EGStageText());
    if (n > 0) {
        size_t m = ((size_t)n < sizeof(buf)) ? (size_t)n : (sizeof(buf) - 1);
        EGAppendCrashFile(buf);
        (void)m;
    }
    void *frames[64];
    int cnt = backtrace(frames, 64);
    if (cnt > 0 && gEGCrashLogPath[0]) {
        int fd = open(gEGCrashLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) {
            backtrace_symbols_fd(frames, cnt, fd);
            close(fd);
        }
    }
    // 恢复默认处理并重发信号 —— 不返回（返回会让进程带着损坏状态继续跑，被看门狗当挂起杀掉）
    signal(sig, SIG_DFL);
    raise(sig);
}

static void EGExceptionHandler(NSException *e) {
    @autoreleasepool {
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"\n===== EXCEPTION =====\nstage=%s\nname=%@\nreason=%@\n",
                          EGStageText(), e.name, e.reason];
        NSArray *stack = e.callStackSymbols;
        NSUInteger lim = stack.count < 40 ? stack.count : 40;
        for (NSUInteger i = 0; i < lim; i++) {
            NSString *f = stack[i];
            if (f.length > 200) f = [f substringToIndex:200];
            [s appendFormat:@"  %@\n", f];
        }
        EGAppendCrashFile(s.UTF8String);
    }
}

static void EGInstallCrashHandlers(void) {
    NSSetUncaughtExceptionHandler(&EGExceptionHandler);

    // 必须给信号处理器**自己的栈**（sigaltstack + SA_ONSTACK）。
    // 否则最需要看到的那类崩溃（爆栈/无限递归）会在已经耗尽的栈上再崩一次，
    // 我们的日志会是零字节，只剩系统 .ips。
    // 注意 signal() 设不了 SA_ONSTACK，必须用 sigaction()。
    static char *altStack = NULL;
    if (!altStack) {
        altStack = (char *)malloc(128 * 1024);
        if (altStack) {
            stack_t ss;
            memset(&ss, 0, sizeof(ss));
            ss.ss_sp = altStack;
            ss.ss_size = 128 * 1024;
            ss.ss_flags = 0;
            if (sigaltstack(&ss, NULL) != 0) {
                free(altStack);
                altStack = NULL;
            }
        }
    }

    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE };
    for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = EGSignalHandler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_ONSTACK;
        sigaction(sigs[i], &sa, NULL);
    }
}

// 回读上一次的崩溃日志（读一次就删，避免陈旧的报告被当成新问题反复看到）。
// 读到的内容**缓存**起来：因为读一次就删，第二次读会返回空 —— 那是"自删证据"。
static void EGReadBackCrashLog(void) {
    if (gEGCrashReport) return;                 // 已缓存，直接复用
    gEGCrashReport = @"";
    if (!gEGCrashLogPath[0]) return;
    int fd = open(gEGCrashLogPath, O_RDONLY);
    if (fd < 0) return;
    char buf[8192];
    NSMutableData *data = [NSMutableData data];
    ssize_t n = 0;
    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        [data appendBytes:buf length:(NSUInteger)n];
    }
    close(fd);
    unlink(gEGCrashLogPath);
    if (data.length == 0) return;
    NSString *txt = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!txt) txt = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    gEGCrashReport = txt ? txt : @"";
}

// ============================== 启动自愈 ==============================
// 把"同一构建连续几次启动异常"记在 Caches 下，绑定构建令牌：
//   · 同一构建内计数**粘性** —— 不会出现"崩一次、下次又好"的振荡，App 始终打得开；
//   · 换构建自动归零 —— 修好的版本无需手动删文件即可重新启用。

static const char *EGBuildToken(void) {
    return __DATE__ " " __TIME__;
}

static NSString *EGLaunchGuardPath(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = dirs.count ? dirs[0] : @"/tmp";
    return [base stringByAppendingPathComponent:@"eg_tidy_launch.txt"];
}

// 返回 0 = 正常启动；>0 = 已经连续异常这么多次，本次应"停手"
static int EGLaunchGuardCheck(void) {
    @autoreleasepool {
        NSString *path = EGLaunchGuardPath();
        NSString *token = [NSString stringWithUTF8String:EGBuildToken()];
        NSString *stored = [NSString stringWithContentsOfFile:path
                                                     encoding:NSUTF8StringEncoding
                                                        error:NULL];
        int count = 0;
        if (stored.length > 0) {
            NSArray *parts = [stored componentsSeparatedByString:@"\n"];
            if (parts.count >= 2 && [parts[0] isEqualToString:token]) {
                count = [parts[1] intValue];
            }
        }
        count += 1;
        NSString *next = [NSString stringWithFormat:@"%@\n%d", token, count];
        [next writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        if (count > EG_LAUNCH_GUARD_MAX) return count;
        return 0;
    }
}

static void EGLaunchGuardClear(void) {
    @autoreleasepool {
        NSString *path = EGLaunchGuardPath();
        NSString *token = [NSString stringWithUTF8String:EGBuildToken()];
        NSString *next = [NSString stringWithFormat:@"%@\n0", token];
        [next writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

// ============================== 诊断缓冲（滚动窗口 + 截断标记） ==============================

static void EGDiag(NSString *fmt, ...) {
    if (!fmt) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (!msg) return;

    @synchronized (@"EGDiag") {
        if (!gEGDiag) gEGDiag = [NSMutableString string];
        [gEGDiag appendFormat:@"%@\n", msg];
        // 滚动窗口：保留最新 N 字符，丢弃**最旧**的；绝不"写满就静默停止"
        if (gEGDiag.length > EG_DIAG_CAP) {
            NSUInteger drop = gEGDiag.length - EG_DIAG_CAP;
            [gEGDiag deleteCharactersInRange:NSMakeRange(0, drop)];
            gEGDiagTruncated = YES;   // 粘性：丢过一次就永远声明
        }
    }
    NSLog(@"[%@] %@", @EG_TAG, msg);
}

static NSString *EGDiagSnapshot(void) {
    @synchronized (@"EGDiag") {
        NSString *body = gEGDiag ? [gEGDiag copy] : @"";
        if (gEGDiagTruncated) {
            return [NSString stringWithFormat:
                    @"…（诊断缓冲超出 %d 字符，已丢弃较早内容，以下是**最新**部分）…\n%@",
                    EG_DIAG_CAP, body];
        }
        return body;
    }
}

// 延迟任务统一走这里：内部 @try。
//   主队列是串行的 —— 宿主 App 长时间占用主线程时，块不会丢，而是被无限推迟。
//   如果块里抛异常，异常会到达 libdispatch 边界被吞成 std::terminate() -> abort()。
//   注意：不要在 %ctor 里用"是主线程就直接跑"的变体：dyld 的初始化就跑在主线程上，
//   那会把诊断放回启动路径（正是我们要避免的）。%ctor 里必须用 dispatch_async。
static void EGAfterOnMain(double delay, dispatch_block_t block) {
    if (!block) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            block();
        } @catch (NSException *e) {
            EGDiag(@"[延迟任务 %.1fs] 异常: %@", delay, e.reason);
        }
    });
}

// ============================== 安全方法查找 ==============================
// 全部手走父类链。**绝不用 class_getInstanceMethod** —— 它会强制 +initialize，
// 在启动阶段遍历全进程类表时会把宿主 App 打到打不开（实锤过）。

static Method EGFindMethodInChain(Class c, SEL sel, Class *outOwner) {
    if (outOwner) *outOwner = Nil;
    if (!c || !sel) return NULL;
    for (Class k = c; k; k = class_getSuperclass(k)) {
        unsigned int n = 0;
        Method *ms = class_copyMethodList(k, &n);
        if (!ms) continue;
        Method found = NULL;
        for (unsigned int i = 0; i < n; i++) {
            if (method_getName(ms[i]) == sel) { found = ms[i]; break; }
        }
        free(ms);
        if (found) {
            if (outOwner) *outOwner = k;
            return found;
        }
    }
    return NULL;
}

static Method EGSafeInstanceMethod(Class c, SEL sel) {
    return EGFindMethodInChain(c, sel, NULL);
}

// 只返回"这个类自己实现的"那份；继承来的返回 NULL。
// 要 method_setImplementation 时必须用这个 —— 改一个继承来的 Method 等于改了父类，
// 会波及所有兄弟子类。
static Method EGOwnMethod(Class c, SEL sel) {
    Class owner = Nil;
    Method m = EGFindMethodInChain(c, sel, &owner);
    return (owner == c) ? m : NULL;
}

static BOOL EGIsDescendantOf(Class c, Class root) {
    for (Class k = c; k; k = class_getSuperclass(k)) {
        if (k == root) return YES;
    }
    return NO;
}

// 万能类判定：对**不存在**的 selector 也"实现"了的类，答案一律不可信。
// 不加这个控制组，全进程扫描会把 12 个不相关的 selector 都返回同样的几个类。
static BOOL EGClassAnswersEverything(Class c) {
    static SEL probe = NULL;
    if (!probe) probe = NSSelectorFromString(@"eg_nonexistent_probe_xyz_123:");
    return EGSafeInstanceMethod(c, probe) != NULL;
}

// ============================== 窗口 / VC ==============================

static NSArray<UIWindow *> *EGAllWindows(void) {
    NSMutableArray *out = [NSMutableArray array];
    UIApplication *app = nil;
    @try {
        app = (UIApplication *)[UIApplication performSelector:@selector(sharedApplication)];
    } @catch (NSException *e) {}
    if (!app) return out;

    @try {
        NSArray *ws = app.windows;
        for (id w in ws) {
            if ([w isKindOfClass:[UIWindow class]] && ![out containsObject:w]) [out addObject:w];
        }
    } @catch (NSException *e) {}

    // connectedScenes 走 KVC：不依赖 SDK 是否把该属性声明出来
    @try {
        id scenes = [app valueForKey:@"connectedScenes"];
        if ([scenes isKindOfClass:[NSSet class]] || [scenes isKindOfClass:[NSArray class]]) {
            for (id sc in (id)scenes) {
                id ws = nil;
                @try { ws = [sc valueForKey:@"windows"]; } @catch (NSException *e) { continue; }
                if (![ws isKindOfClass:[NSArray class]]) continue;
                for (id w in (NSArray *)ws) {
                    if ([w isKindOfClass:[UIWindow class]] && ![out containsObject:w]) {
                        [out addObject:w];
                    }
                }
            }
        }
    } @catch (NSException *e) {}

    return out;
}

// childViewControllers 走 KVC —— 不依赖 SDK 是否暴露该属性
static NSArray *EGChildrenOf(UIViewController *vc) {
    if (!vc) return nil;
    @try {
        id v = [vc valueForKey:@"children"];
        if ([v isKindOfClass:[NSArray class]]) return (NSArray *)v;
    } @catch (NSException *e) {}
    @try {
        id v = [vc valueForKey:@"childViewControllers"];
        if ([v isKindOfClass:[NSArray class]]) return (NSArray *)v;
    } @catch (NSException *e) {}
    return nil;
}

static UIViewController *EGCurrentVC(void) {
    UIViewController *last = gEGLastVC;
    if (last && last.view && last.view.window) return last;

    for (UIWindow *w in EGAllWindows()) {
        if (w.hidden || w.alpha < 0.01) continue;
        UIViewController *top = w.rootViewController;
        if (!top) continue;
        for (int i = 0; i < 8; i++) {
            UIViewController *p = nil;
            @try { p = top.presentedViewController; } @catch (NSException *e) {}
            if (p) { top = p; continue; }
            NSArray *kids = EGChildrenOf(top);
            if (!kids.count) break;
            id nxt = [kids lastObject];
            if (![nxt isKindOfClass:[UIViewController class]]) break;
            top = (UIViewController *)nxt;
        }
        return top;
    }
    return last;
}

static NSString *EGVCChainOf(id vc, NSUInteger maxDepth) {
    NSMutableArray *parts = [NSMutableArray array];
    id cur = vc;
    NSUInteger guard = 0;
    while (cur && guard++ < maxDepth) {
        [parts addObject:NSStringFromClass([cur class])];
        id parent = nil;
        @try {
            id p = [cur valueForKey:@"parentViewController"];
            if ([p isKindOfClass:[UIViewController class]]) parent = p;
        } @catch (NSException *e) {}
        cur = parent;
    }
    return [parts componentsJoinedByString:@" > "];
}

static UIView *EGRootViewOfCurrentScreen(void) {
    UIViewController *vc = EGCurrentVC();
    if (vc) {
        UIView *v = nil;
        @try { v = vc.view; } @catch (NSException *e) {}
        if (v) return v;
    }
    for (UIWindow *w in EGAllWindows()) {
        if (w.hidden || w.alpha < 0.01) continue;
        UIView *v = w.rootViewController.view;
        if (v) return v;
    }
    return nil;
}

// ============================== 视图 dump ==============================

// H5 标记：原生方案对 H5 内部元素**完全无效**，一眼看出"在不在 H5 里"才能避免白改一版。
static BOOL EGIsH5Hosted(UIView *v) {
    for (UIView *p = v; p; p = p.superview) {
        NSString *n = NSStringFromClass([p class]);
        if ([n containsString:@"WKWebView"] || [n containsString:@"WKContentView"] ||
            [n containsString:@"UIWebView"]  || [n containsString:@"WKScrollView"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL EGIsBannerShaped(UIView *v) {
    if (!v) return NO;
    CGRect r = CGRectZero;
    @try {
        UIView *win = v.window;
        r = win ? [v convertRect:v.bounds toView:win] : v.bounds;
    } @catch (NSException *e) { return NO; }
    if (r.size.width < EG_AD_CAND_MIN_W || r.size.height < EG_AD_CAND_MIN_H) return NO;
    CGFloat ratio = r.size.width / (r.size.height > 0.5 ? r.size.height : 0.5);
    return (ratio >= EG_AD_CAND_MIN_RATIO && ratio <= EG_AD_CAND_MAX_RATIO);
}

// 节点标记：横幅形态 / [H5] / 类名疑似广告
static NSString *EGNodeTagOf(UIView *v) {
    NSMutableArray *tags = [NSMutableArray array];
    NSString *cls = NSStringFromClass([v class]);
    if (EGIsBannerShaped(v)) [tags addObject:@"★横幅形态"];
    if (EGIsH5Hosted(v)) [tags addObject:@"[H5]"];
    if ([cls containsString:@"Banner"] || [cls containsString:@"Advert"] ||
        [cls containsString:@"Promot"] || [cls containsString:@"Marquee"] ||
        [cls containsString:@"Carousel"] || [cls containsString:@"Cycle"]) {
        [tags addObject:@"★类名疑似广告"];
    }
    if (!tags.count) return @"";
    return [NSString stringWithFormat:@"  %@", [tags componentsJoinedByString:@" "]];
}

static NSString *EGDescribeNode(UIView *v, NSString *indent) {
    NSMutableString *s = [NSMutableString string];
    NSString *cls = NSStringFromClass([v class]);
    CGRect f = v.frame;
    CGRect b = v.bounds;

    [s appendFormat:@"%@%@  frame=(%.0f,%.0f,%.0f,%.0f)",
        indent, cls, f.origin.x, f.origin.y, f.size.width, f.size.height];

    // 窗口坐标：frame 是相对父视图的，"屏幕底部那条"要自己把父链加一遍才能对上截图，
    // 节点一多必然算错，算错就会改错节点。
    UIView *win = v.window;
    if (win) {
        CGRect w = [v convertRect:b toView:win];
        [s appendFormat:@" win=(%.0f,%.0f,%.0f,%.0f)",
            w.origin.x, w.origin.y, w.size.width, w.size.height];
    } else {
        [s appendString:@" win=(不在窗口)"];
    }

    if (v.hidden) [s appendString:@" hidden=YES"];
    if (v.alpha < 0.99) [s appendFormat:@" alpha=%.2f", v.alpha];
    if (v.tag != 0) [s appendFormat:@" tag=%ld", (long)v.tag];

    // UILabel 打文案 —— 「我的订单」/「我的服务」这类文本是定位锚点，对照截图最直观
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length) {
            if (t.length > 40) t = [[t substringToIndex:40] stringByAppendingString:@"..."];
            [s appendFormat:@" text=[%@]", t];
        }
    } else if ([v isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)v;
        if (iv.image) {
            [s appendFormat:@" img=%.0fx%.0f", iv.image.size.width, iv.image.size.height];
        }
    } else if ([v isKindOfClass:[UIButton class]]) {
        NSString *t = [((UIButton *)v) titleForState:UIControlStateNormal];
        if (t.length) [s appendFormat:@" title=[%@]", t];
    }

    [s appendString:EGNodeTagOf(v)];
    return s;
}

static void EGWalkNode(UIView *v, NSUInteger depth, NSUInteger maxDepth,
                       NSUInteger *budget, NSMutableString *s) {
    if (!v || !s || !budget) return;
    if (*budget == 0) return;

    NSMutableString *indent = [NSMutableString string];
    for (NSUInteger i = 0; i < depth && i < 24; i++) [indent appendString:@"  "];

    [s appendFormat:@"%@\n", EGDescribeNode(v, indent)];
    *budget = (*budget > 0) ? (*budget - 1) : 0;

    if (depth >= maxDepth) {
        if (v.subviews.count > 0) {
            [s appendFormat:@"%@  ...（已达深度上限 %lu，子树 %lu 个未展开）\n",
                indent, (unsigned long)maxDepth, (unsigned long)v.subviews.count];
        }
        return;
    }
    for (UIView *sub in v.subviews) {
        if (*budget == 0) {
            [s appendFormat:@"%@  ...（节点预算耗尽，剩余兄弟节点未展开）\n", indent];
            return;
        }
        EGWalkNode(sub, depth + 1, maxDepth, budget, s);
    }
}

static NSString *EGDumpViewTree(UIView *root, NSUInteger maxDepth, NSUInteger maxNodes) {
    if (!root) return @"(没有可 dump 的根视图)\n";
    NSMutableString *s = [NSMutableString string];
    NSUInteger budget = maxNodes;
    EGWalkNode(root, 0, maxDepth, &budget, s);
    if (budget == 0) {
        [s appendString:@"  ...（节点预算已耗尽，dump 被截断 —— 见上方标记）\n"];
    }
    return s;
}

// 广告候选汇总：只**报告**，不隐藏。
// 关键词判定误报率高（一个正常的轮播组件也会叫 Banner），
// 直接拿它去藏视图就是把"猜"写进产品行为。判定由人做，改由下一版做。
static NSString *EGBannerCandidates(UIView *root) {
    if (!root) return @"(无根视图)\n";
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger guard = 0;
    while (stack.count && guard++ < 4000 && rows.count < EG_AD_CAND_MAX_REPORT) {
        UIView *v = [stack lastObject];
        [stack removeLastObject];
        for (UIView *sub in v.subviews) [stack addObject:sub];

        BOOL banner = EGIsBannerShaped(v);
        NSString *cls = NSStringFromClass([v class]);
        BOOL suspicious = ([cls containsString:@"Banner"] || [cls containsString:@"Advert"] ||
                           [cls containsString:@"Promot"] || [cls containsString:@"Carousel"] ||
                           [cls containsString:@"Cycle"]  || [cls containsString:@"Marquee"]);
        if (!banner && !suspicious) continue;

        UIView *win = v.window;
        CGRect w = win ? [v convertRect:v.bounds toView:win] : v.bounds;
        NSString *parentCls = v.superview ? NSStringFromClass([v.superview class]) : @"(无父)";
        [rows addObject:[NSString stringWithFormat:
            @"  %@  win=(%.0f,%.0f,%.0f,%.0f)  父=%@%@%@%@%@",
            cls, w.origin.x, w.origin.y, w.size.width, w.size.height, parentCls,
            banner ? @"  [横幅形态]" : @"",
            suspicious ? @"  [类名疑似]" : @"",
            EGIsH5Hosted(v) ? @"  [H5→原生方案无效]" : @"",
            v.hidden ? @"  hidden=YES" : @""]];
    }
    if (!rows.count) return @"  (没有命中：既非横幅形态，类名也不含广告关键词)\n";
    NSMutableString *s = [NSMutableString string];
    for (NSString *r in rows) [s appendFormat:@"%@\n", r];
    if (rows.count >= EG_AD_CAND_MAX_REPORT) {
        [s appendFormat:@"  ...（已达报告上限 %d 条）\n", EG_AD_CAND_MAX_REPORT];
    }
    return s;
}

// ============================== 底栏取证 ==============================

static void EGCollectTabBarControllers(UIViewController *vc, NSMutableArray *out, NSUInteger depth) {
    if (!vc || depth > 12) return;
    if ([vc isKindOfClass:[UITabBarController class]] && ![out containsObject:vc]) {
        [out addObject:vc];
    }
    NSArray *kids = EGChildrenOf(vc);
    for (id k in kids) {
        if ([k isKindOfClass:[UIViewController class]]) {
            EGCollectTabBarControllers((UIViewController *)k, out, depth + 1);
        }
    }
    UIViewController *presented = nil;
    @try { presented = vc.presentedViewController; } @catch (NSException *e) {}
    if (presented) EGCollectTabBarControllers(presented, out, depth + 1);
}

static NSArray *EGFindTabBarControllers(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIWindow *w in EGAllWindows()) {
        UIViewController *r = w.rootViewController;
        if (r) EGCollectTabBarControllers(r, out, 0);
    }
    return out;
}

static NSString *EGDescribeVCArray(NSArray *arr) {
    NSMutableString *s = [NSMutableString string];
    if (!arr) return @"    (viewControllers = nil)\n";
    [s appendFormat:@"    viewControllers 数量 = %lu\n", (unsigned long)arr.count];
    NSUInteger i = 0;
    for (id vc in arr) {
        if (![vc isKindOfClass:[UIViewController class]]) {
            [s appendFormat:@"    [%lu] (不是 UIViewController：%@)\n", (unsigned long)i,
                NSStringFromClass([vc class])];
            i++;
            continue;
        }
        UIViewController *v = (UIViewController *)vc;
        NSString *title = @"";
        NSInteger tag = -1;
        @try {
            UITabBarItem *it = v.tabBarItem;
            title = it.title ?: @"";
            tag = (NSInteger)it.tag;
        } @catch (NSException *e) {}
        NSString *navTop = @"";
        if (EGIsDescendantOf([v class], [UINavigationController class])) {
            @try {
                id top = [(UINavigationController *)v topViewController];
                if (top) navTop = [NSString stringWithFormat:@" top=%@", NSStringFromClass([top class])];
            } @catch (NSException *e) {}
        }
        [s appendFormat:@"    [%lu] %@  title=[%@] tag=%ld%@\n",
            (unsigned long)i, NSStringFromClass([v class]), title, (long)tag, navTop];
        i++;
    }
    return s;
}

static NSString *EGDescribeTabBar(UITabBar *tb) {
    NSMutableString *s = [NSMutableString string];
    if (!tb) return @"    (tabBar = nil)\n";
    CGRect f = tb.frame;
    [s appendFormat:@"    tabBar 类=%@  frame=(%.0f,%.0f,%.0f,%.0f)  直接子视图=%lu\n",
        NSStringFromClass([tb class]), f.origin.x, f.origin.y, f.size.width, f.size.height,
        (unsigned long)tb.subviews.count];

    @try {
        NSArray<UITabBarItem *> *items = tb.items;
        [s appendFormat:@"    tabBar.items 数量 = %lu\n", (unsigned long)items.count];
        NSUInteger i = 0;
        for (UITabBarItem *it in items) {
            [s appendFormat:@"      item[%lu] title=[%@] tag=%ld\n",
                (unsigned long)i, it.title ?: @"", (long)it.tag];
            i++;
        }
    } @catch (NSException *e) {}

    // 直接子视图逐个打：**自绘 tab bar 的图标/按钮常常就是直接子视图**，
    // 它们不在 items 里，类名也不是 UITabBarButton。
    NSUInteger idx = 0;
    for (UIView *sub in tb.subviews) {
        CGRect sf = sub.frame;
        UIView *win = sub.window;
        CGRect w = win ? [sub convertRect:sub.bounds toView:win] : sf;
        [s appendFormat:@"      子[%lu] %@ frame=(%.0f,%.0f,%.0f,%.0f) win=(%.0f,%.0f,%.0f,%.0f)%@%@\n",
            (unsigned long)idx, NSStringFromClass([sub class]),
            sf.origin.x, sf.origin.y, sf.size.width, sf.size.height,
            w.origin.x, w.origin.y, w.size.width, w.size.height,
            sub.hidden ? @" [隐]" : @"",
            EGIsH5Hosted(sub) ? @" [H5]" : @""];
        idx++;
    }
    return s;
}

static NSString *EGDescribeTabBarController(UITabBarController *tbc) {
    NSMutableString *s = [NSMutableString string];
    NSInteger sel = -1;
    @try { sel = (NSInteger)tbc.selectedIndex; } @catch (NSException *e) {}
    [s appendFormat:@"  > %@  selectedIndex=%ld\n", NSStringFromClass([tbc class]), (long)sel];
    @try {
        [s appendString:EGDescribeVCArray(tbc.viewControllers)];
    } @catch (NSException *e) {}
    @try {
        [s appendString:EGDescribeTabBar(tbc.tabBar)];
    } @catch (NSException *e) {}
    return s;
}

static NSString *EGTabBarForensics(void) {
    NSMutableString *s = [NSMutableString string];
    NSArray *tbcs = EGFindTabBarControllers();
    [s appendFormat:@"找到 %lu 个 UITabBarController\n", (unsigned long)tbcs.count];
    if (!tbcs.count) {
        [s appendString:@"  [!] 一个都没有 -> **大概率是自绘底栏**（见下方「自绘底栏候选」）\n"];
        [s appendString:@"      但先别下结论：也可能它挂在 UIApplication.windows 之外，\n"];
        [s appendString:@"      请看下面「窗口清单」里是否有我们没走到的 window。\n"];
    }
    NSUInteger i = 0;
    for (id t in tbcs) {
        if ([t isKindOfClass:[UITabBarController class]]) {
            [s appendFormat:@"[%lu]\n", (unsigned long)i];
            [s appendString:EGDescribeTabBarController((UITabBarController *)t)];
            i++;
        }
    }

    [s appendString:@"\n窗口清单：\n"];
    for (UIWindow *w in EGAllWindows()) {
        CGRect f = w.frame;
        [s appendFormat:@"  %@ frame=(%.0f,%.0f,%.0f,%.0f) hidden=%d alpha=%.2f level=%.1f root=%@\n",
            NSStringFromClass([w class]), f.origin.x, f.origin.y, f.size.width, f.size.height,
            w.hidden ? 1 : 0, w.alpha, (double)w.windowLevel,
            w.rootViewController ? NSStringFromClass([w.rootViewController class]) : @"(无)"];
    }
    return s;
}

// 自绘底栏候选：底栏不在 UITabBarController 里时，容器类只能靠类名找。
// 只报告候选，不改任何东西。
static NSString *EGScanTabBarLikeClasses(void) {
    NSMutableString *s = [NSMutableString string];
    NSArray<NSString *> *kws = EG_SCAN_KEYWORDS_TAB;
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return @"(objc_getClassList 返回 0)\n";
    Class *all = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (!all) return @"(malloc 失败)\n";
    total = objc_getClassList(all, total);

    NSMutableArray<NSString *> *hits = [NSMutableArray array];
    NSUInteger universal = 0;
    for (int i = 0; i < total; i++) {
        Class c = all[i];
        const char *nm = class_getName(c);
        if (!nm) continue;
        NSString *n = [NSString stringWithUTF8String:nm];
        if (!EGClassNameMatchesAny(n, kws)) continue;
        if (EGClassAnswersEverything(c)) { universal++; continue; }   // 剔除万能类
        if (hits.count < 80) [hits addObject:n];
    }
    free(all);

    [s appendFormat:@"类名含 %@ 的类：%lu 个",
        [kws componentsJoinedByString:@"/"], (unsigned long)hits.count];
    if (universal) [s appendFormat:@"（另有 %lu 个万能类已剔除）", (unsigned long)universal];
    [s appendString:@"\n"];
    for (NSString *n in hits) [s appendFormat:@"  %@\n", n];
    return s;
}

// ============================== 类名扫描 ==============================

static BOOL EGClassNameMatchesAny(NSString *n, NSArray<NSString *> *kws) {
    if (!n.length) return NO;
    for (NSString *k in kws) {
        if ([n rangeOfString:k].location != NSNotFound) return YES;
    }
    return NO;
}

// 全进程类名扫描：只读 class_getName / class_getSuperclass / class_copyMethodList，
// 全部是线程安全的只读运行时查询，**不触发 +initialize**。
static NSString *EGScanClassNames(NSArray<NSString *> *keywords, NSUInteger maxOut) {
    NSMutableString *s = [NSMutableString string];
    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return @"(objc_getClassList 返回 0)\n";
    Class *all = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (!all) return @"(malloc 失败)\n";
    total = objc_getClassList(all, total);

    NSUInteger hit = 0, universal = 0;
    for (int i = 0; i < total; i++) {
        Class c = all[i];
        const char *nm = class_getName(c);
        if (!nm) continue;
        NSString *n = [NSString stringWithUTF8String:nm];
        if (!EGClassNameMatchesAny(n, keywords)) continue;
        if (EGClassAnswersEverything(c)) { universal++; continue; }
        if (hit < maxOut) {
            Class super = class_getSuperclass(c);
            NSString *sn = super ? [NSString stringWithUTF8String:class_getName(super)] : @"(无)";
            [s appendFormat:@"  %@ : %@\n", n, sn];
        }
        hit++;
    }
    free(all);

    NSMutableString *head = [NSMutableString string];
    [head appendFormat:@"命中 %lu 个", (unsigned long)hit];
    if (universal) [head appendFormat:@"（另有 %lu 个万能类已剔除）", (unsigned long)universal];
    if (hit > maxOut) [head appendFormat:@"，只列前 %lu 个", (unsigned long)maxOut];
    [head appendString:@"\n"];
    return [head stringByAppendingString:s];
}

// ============================================================================
// ★★★ v0.2 规则引擎 —— 从"只取证"转为"真改界面"
// ============================================================================
//
// 全部规则**只依赖 2026-10-01 两次真机抓取实测到的字段**，没有一个字是猜的：
//
//   [实测] RootTabBarController : UITabBarController（原生，非自绘）
//   [实测] viewControllers[0..4] 全部是 e高速.RootNavigationController
//   [实测] 真身在各 RootNavigationController 的 topViewController 类名上：
//            [0] FunctionMenuHomePageViewController   首页
//            [1] TheOwnerServiceMainViewController    车主服务
//            [2] ETCMemberMainViewController          会员服务
//            [3] MallMainContorller                   商城
//            [4] MyInfoViewControllerNew              我的
//   [实测] tabBarItem.tag **全部为 0** -> tag 不可用作识别键
//   [实测] tabBarItem.title 分别是 首页/车主服务/会员服务/商城/我的
//   [实测] 「我的」页广告 = e高速.MyInfoViewControllerBannerCell（原生 cell）
//            位于 MyInfoViewControllerNew 的 UITableView，frame.y=275 高 79
//            内部 ZCycleView -> UICollectionView -> ZCycleViewCell（非 H5）
//   [实测] 同一 UITableView 里有 **4 个 hidden=YES 且高度为 0 的 MyInfoTitleCell 残影**
//            （cell 复用池里的游离实例）-> 不能按类名盲删，必须判 hidden/尺寸
//
// 设计要点（每条都对应一次真实翻车的可能性）：
//   ① **不删 viewControllers，只重建数组。** 直接 removeObjectAtIndex: 会让
//      NavigationController 与其持有的 VC 引用计数关系变化；重建数组最干净。
//   ② **保留的对象直接引用原实例**，不新建 —— 新建会丢掉已加载的状态。
//   ③ **幂等**。userDefaults 不用；每次调用重新算一遍，已经是 1 个就跳过。
//      不依赖"哪一次时机是对的"这个假设（viewDidLoad / viewWillAppear 都挂）。
//   ④ **只改 UITabBarController 这一个类的 viewDidLoad/viewWillAppear:**，
//      单类单 selector 单 shim，不装通用安装器（见 hook 一节的理由）。
//   ⑤ 广告位：**"不显示"和"不占位"是两件事**。hide cell 只做了前者，
//      高度必须一起改，否则留 79pt 空白。
// ============================================================================

#define EG_ENABLE_RULES        1   // 总开关：关掉即退回纯探针
// ★ 下面三个全是**裸名**（不含 Swift 模块前缀）。运行时一律经 EGResolveClass /
//   EGClassNameIs 解析，绝不能直接拿去 objc_getClass / strcmp —— 见下方"类名解析"一节。
#define EG_RULE_KEEP_TOP_VC    "MyInfoViewControllerNew"   // 唯一保留的 tab（按 topViewController 类名匹配）
#define EG_RULE_TAB_VC         "RootTabBarController"       // 宿主底栏控制器（实测 : UITabBarController）

// 广告 cell 类名（实测于「我的」页）
#define EG_RULE_AD_CELL_CLASS  "MyInfoViewControllerBannerCell"
#define EG_RULE_MINE_TABLE_VC  "MyInfoViewControllerNew"

// 副判据：广告内部是轮播控件 ZCycleView（实测）。主判据（类名）万一因版本升级
// 改名，这条兜底还能认出来。只在「我的」页视图树里生效。
#define EG_RULE_AD_FALLBACK_ZCYCLE  1
#define EG_RULE_AD_ZCYCLE_HINT      "ZCycle"

static BOOL gEGRulesInstalled    = NO;
static BOOL gEGTabBarNarrowed    = NO;
static NSUInteger gEGTabBarCutCount = 0;
static NSUInteger gEGAdCellHiddenCount = 0;

// ============================================================================
// ★★ 类名解析 —— v0.2.1 的核心修复（v0.2.0 就是死在这里） =================
// ============================================================================
//
// 【错在哪】v0.2.0 用**裸名**做 strcmp 全等比较：
//     objc_getClass("RootTabBarController")        -> Nil
//     strcmp(class_getName(cls), "RootTabBarController") != 0 -> 永远不等
//   而实测 dump 里类名的真身是：
//     e高速.RootTabBarController / e高速.MyInfoViewControllerNew
//   这是 **Swift 的模块名前缀**（模块名 = App 显示名，中文）。
//   class_getName() 返回的是**带前缀的全名**，不是裸名。
//
// 【后果】objc_getClass 返回 Nil -> 一个钩子都没装上；
//         每个规则函数在类名这道门上直接 return；
//         巡检跑了 8 轮，8 轮全是空转。所以用户看到"都还在，没有改变"——
//         **不是规则没生效，是规则从头到尾没被触发过一次**。
//
// 【修法】统一走下面两个函数，禁止再出现任何裸名 strcmp / objc_getClass：
//   1. EGClassBareName() —— 取全名最后一个 '.' 之后的部分
//   2. EGResolveClass()  —— 先裸名直取，取不到就扫全进程类表按"后缀"找
//
// 为什么用"最后一个点之后"而不是"子串包含"：
//   子串包含会让 "MyInfoCell" 误配到 "MyInfoViewControllerBannerCell"，
//   而「我的」页几乎全是 MyInfoCell —— 那会误伤一大片。后缀匹配不会。
// ============================================================================

static const char *EGClassBareName(const char *cn) {
    if (!cn) return NULL;
    const char *dot = strrchr(cn, '.');
    return dot ? (dot + 1) : cn;
}

// 对象/类的类名是否等于裸名（兼容 Swift 模块前缀）
static BOOL EGClassNameIs(id obj, const char *bare) {
    if (!obj || !bare || !*bare) return NO;
    @try {
        const char *cn = class_getName([obj class]);
        if (!cn) return NO;
        return strcmp(EGClassBareName(cn), bare) == 0;
    } @catch (NSException *e) { return NO; }
}

// 按裸名解析 Class。找不到返回 Nil —— 调用方保持"找不到就放弃"的纪律，不许猜父类。
//
// ★ 优先级：**带模块前缀的同名类 > 纯裸名类**。
//   理由：本 App 的类一定带 "e高速." 前缀；全系统里若恰好有个第三方类叫
//   RootTabBarController（概率极低但存在），前缀版才是我们要的那个。
static Class EGResolveClass(const char *bare) {
    if (!bare || !*bare) return Nil;

    Class direct = objc_getClass(bare);
    if (direct) {
        const char *dname = class_getName(direct);
        if (dname && strchr(dname, '.')) return direct;   // 直取命中且带前缀 = 就是它
        // 直取命中的是裸名版：继续扫，看看有没有带模块前缀的优先版本
    }

    int total = objc_getClassList(NULL, 0);
    if (total <= 0) return direct;

    Class *all = (Class *)malloc(sizeof(Class) * (size_t)total);
    if (!all) return direct;
    total = objc_getClassList(all, total);

    Class found = Nil;
    for (int i = 0; i < total; i++) {
        Class c = all[i];
        if (!c) continue;
        const char *nm = class_getName(c);
        if (!nm) continue;
        if (strcmp(EGClassBareName(nm), bare) != 0) continue;
        if (strchr(nm, '.')) { found = c; break; }      // 带模块前缀 —— 优先
        if (!found) found = c;                          // 裸名版 —— 备选
    }
    free(all);
    if (found) return found;
    return direct;
}

// 解析结果留痕：诊断里直接打出「裸名 -> 真名」，下次不再靠猜。
static NSString *EGResolvedName(const char *bare) {
    Class c = EGResolveClass(bare);
    return c ? [NSString stringWithUTF8String:class_getName(c)]
             : [NSString stringWithFormat:@"(未找到 %s)", bare];
}

// ---- 识别：这个 viewController 是不是"我的" ----
// 匹配顺序刻意从最可靠到最不可靠：
//   1. topViewController 类名（实测唯一可靠 —— tag 全 0、title 可能被本地化）
//   2. tabBarItem.title == "我的"（实测可用，作为二次确认）
static BOOL EGIsMineTabVC(UIViewController *vc) {
    if (!vc) return NO;
    @try {
        // 1) 剥掉 NavigationController 取真身
        UIViewController *top = vc;
        if ([vc isKindOfClass:[UINavigationController class]]) {
            top = [(UINavigationController *)vc topViewController];
        }
        if (top && EGClassNameIs(top, EG_RULE_KEEP_TOP_VC)) return YES;
        // 2) title 兜底
        NSString *t = vc.tabBarItem.title;
        if (t.length && [t isEqualToString:@"我的"]) return YES;
    } @catch (NSException *e) {}
    return NO;
}

// 底栏兜底识别：**不依赖类名**。
//   万一宿主把 RootTabBarController 改名/混淆（版本升级很常见），光靠类名又会瞎一次。
//   指纹 = 恰好这 5 个标题且顺序完全一致 —— 这个组合在别的 tab 上撞的概率极低。
//   即便真撞上，后果也只是"少一个 tab"，肉眼立刻可见，不会静默出错。
static BOOL EGIsEgaosuMainTabBarByTitles(UITabBarController *tbc) {
    static NSArray<NSString *> *want = nil;
    if (!want) want = @[@"首页", @"车主服务", @"会员服务", @"商城", @"我的"];
    @try {
        NSArray *vcs = tbc.viewControllers;
        if (!vcs || vcs.count != want.count) return NO;
        NSMutableArray<NSString *> *got = [NSMutableArray array];
        for (UIViewController *vc in vcs) {
            NSString *t = vc.tabBarItem.title;
            if (!t.length) return NO;
            [got addObject:t];
        }
        return [got isEqualToArray:want];
    } @catch (NSException *e) { return NO; }
}

// ---- 规则 1：底栏只留「我的」 ----
static void EGApplyTabBarRule(UITabBarController *tbc, const char *reason) {
#if EG_ENABLE_RULES
    if (!tbc) return;
    if (![tbc isKindOfClass:[UITabBarController class]]) return;
    // 只用实测到的那个类：别人的 UITabBarController（若 App 里还有别的）不动
    // ★ 走 EGClassNameIs —— 兼容 "e高速." 模块前缀（v0.2.0 的裸名 strcmp 在此永久失配）
    // ★ 再加标题指纹兜底 —— 类名将来改名也不至于整条规则失效
    if (!EGClassNameIs(tbc, EG_RULE_TAB_VC) && !EGIsEgaosuMainTabBarByTitles(tbc)) return;

    @try {
        NSArray *vcs = tbc.viewControllers;
        if (!vcs || vcs.count <= 1) {   // 已经是 1 个 -> 幂等，直接记状态
            gEGTabBarNarrowed = (vcs.count == 1);
            return;
        }

        NSMutableArray *keep = [NSMutableArray array];
        NSMutableArray *drop = [NSMutableArray array];
        for (UIViewController *vc in vcs) {
            if (EGIsMineTabVC(vc)) [keep addObject:vc];
            else                    [drop addObject:vc];
        }

        if (keep.count == 0) {
            // **一条都没匹配上就什么都不做** —— 宁可不动，也不要把底栏清空。
            // 这是硬底线：识别失败时"不动"永远优于"乱动"。
            EGDiag(@"[规则·底栏] (%s) 5 个 tab 里没识别出「我的」-> **放弃，不动**（保护性退出）",
                   reason);
            return;
        }
        if (drop.count == 0) {   // 本来就只有「我的」
            gEGTabBarNarrowed = YES;
            return;
        }

        NSMutableString *dropped = [NSMutableString string];
        for (UIViewController *vc in drop) {
            UIViewController *top = vc;
            if ([vc isKindOfClass:[UINavigationController class]])
                top = [(UINavigationController *)vc topViewController];
            [dropped appendFormat:@"%@ ", top ? NSStringFromClass([top class]) : @"?"];
        }

        // ★ 重建数组而不是 removeObjectAtIndex: —— 保留的对象仍是**原实例**
        tbc.viewControllers = [keep copy];
        tbc.selectedIndex = 0;
        gEGTabBarCutCount += drop.count;
        gEGTabBarNarrowed = YES;

        EGDiag(@"[规则·底栏] (%s) 5 -> %lu，移除: %@（保留 %@）",
               reason, (unsigned long)keep.count, dropped,
               keep.count ? NSStringFromClass([[keep firstObject] class]) : @"?");
        EGJournal("rule-tabbar-ok");
    } @catch (NSException *e) {
        EGDiag(@"[规则·底栏] 异常: %@", e.reason);
        EGJournal("rule-tabbar-EXC");
    }
#endif
}

// ---- 规则 3：广告行高 = 0（覆盖还没实例化的那一次） ----
//
// 为什么必须有这条：UITableView 只实例化**可见区域**的 cell。
// 广告行若在屏幕外，规则 2 的视图树遍历根本看不到它 —— 用户一滚就冒出来了。
// 必须从 dataSource 层面把高度压成 0，与"是否已实例化"无关。
//
// ★ 判据怎么来（这里是关键，也是我上一版写错的地方）：
//   不能靠"猜某个 indexPath 是广告行"。要**从行为上观察**：
//   `heightForRowAtIndexPath:` 被调用时，只有高度**不够可靠地区分身份**。
//   可靠的做法是**先观察谁被实例化了**：hook 只装在 `MyInfoViewControllerNew`，
//   当 tableView 要显示某一行时，我们自己问 dataSource 要 cell 是**有副作用**的
//   （会触发 cellForRow 并可能引起递归），所以不走那条路。
//
//   最终方案 —— **登记制**：
//     在 `EGApplyMineAdRule` 的视图树遍历里，凡命中广告类名的 cell，
//     把它所在的 tableView + indexPath 记进 `gEGAdRows`。
//     行高 hook 只查登记表。表格滚动时，新行会先走 heightForRow 再创建 cell，
//     首次可能漏一次；但 `EGWatchMinePage` 的周期巡检会补上登记
//     （cell 一旦实例化就被并入登记表，下一轮布局即塌陷）。
//
//   这比"猜"稳健：**判据来自真实观察，且有两个独立通道互相兜底**
//   （视图树遍历 + 周期巡检），任一通道生效即可。
//
// ★★ 但 v0.2.1 实测证明：**光有行高 hook 还不够**。
//   「hidden + frame.height=0.5」只改了 cell 自己，UITableView **内部缓存的行高仍是 79**，
//   于是后面所有行的 y 根本没上移 —— 页面上就是一条 79pt 的空白。
//   实测坐标（2026-10-01 真机）：
//     MyOrderInfoTitleCell y=189 h=86  → 结束 275
//     BannerCell           y=275 h≈0.5   （我们改过的）
//     MyInfoTitleCell      y=366          ← 空了 90.5 ≈ 79 + 12 正常间距
//   **判读**：hidden/cell.frame 管的是"不显示"，行高缓存管的是"占不占位"。
//   要消掉空白，必须让表格**重新向 dataSource 问一次行高** —— 见 EGRefreshAdRowHeights。
static NSMutableSet<NSString *> *gEGAdRowKeys = nil;   // key = "<tableView 指针>#<section>.<row>"

// 已经强制刷新过行高的行（同 key）。**每个行只刷一次** ——
// 既避免每轮巡检都刷（闪），也避免 reload → 建 cell → 再 reload 的递归。
static NSMutableSet<NSString *> *gEGAdRowsReloaded = nil;
static NSUInteger gEGAdReloadCount = 0;

// 兜底升级：**只做一次**的 reloadData。
//   判据来自实测：重排后如果广告 cell 仍按 79pt 建出来，就说明 reloadRows 没生效。
static BOOL    gEGAdReloadDataDone = NO;
static CGFloat gEGLastAdOrigH      = -1;   // 最近一次塌陷**前**广告 cell 的实测高度

static NSString *EGAdRowKey(UITableView *tv, NSIndexPath *ip) {
    if (!tv || !ip) return nil;
    return [NSString stringWithFormat:@"%p#%ld.%ld", (void *)tv,
            (long)ip.section, (long)ip.row];
}

static BOOL EGIsAdRowRegistered(UITableView *tv, NSIndexPath *ip) {
    NSString *k = EGAdRowKey(tv, ip);
    if (!k) return NO;
    @synchronized (@"EGAdRows") {
        return gEGAdRowKeys && [gEGAdRowKeys containsObject:k];
    }
}

static IMP  gEGOrigHeightForRow    = NULL;
static BOOL gEGHeightHookInstalled = NO;

static CGFloat EGHeightForRowHook(id self, SEL _cmd, UITableView *tv, NSIndexPath *ip) {
    IMP orig = gEGOrigHeightForRow;

    // ★★ 安全闸（第二道）：orig 为空时**不返回 0**，而是返回 UITableView 的默认行高。
    //    为什么：本函数一旦被装上，就接管了这个类**全部**的行高计算。
    //    若 orig 拿不到（极端情况），返回 0 会让整页行高归零 —— 页面完全空白，
    //    比"广告没去掉"严重得多。所以这里宁可退回一个保守默认值。
    //    安装侧（EGInstallHeightHook）已经保证 orig 非空才安装；这里是纵深防御。
    if (!orig) {
        static BOOL logged = NO;
        if (!logged) { logged = YES; EGDiag(@"[规则·行高] [!] orig 为空 —— 退回默认行高 44，不做任何改动"); }
        return 44.0;
    }

    CGFloat h = 0;
    @try {
        h = ((CGFloat (*)(id, SEL, UITableView *, NSIndexPath *))orig)(self, _cmd, tv, ip);
    } @catch (NSException *e) {
        EGDiag(@"[规则·行高] 原实现抛异常: %@ —— 退回默认行高", e.reason);
        return 44.0;
    }

    @try {
        if (EGIsAdRowRegistered(tv, ip)) {
            if (h > 0.5) {
                EGDiag(@"[规则·行高] %@ -> 0.5（原 %.0f，已登记为广告行）", ip, (double)h);
            }
            // ★ 返回 **0.5 而不是 0**。理由（这是本项目踩过的坑，见 skill Gotcha 29）：
            //   高度为 0 = 空矩形。CGRectIntersectsRect 对空矩形返回 NO ->
            //   这一行会掉出可见区域计算 -> cell 被回收 -> 我们赖以识别身份的
            //   类名（MyInfoViewControllerBannerCell）随之丢失 -> 下一轮它又回到 79 高。
            //   结果是 0/79 振荡 = 肉眼可见的闪烁。
            //   0.5pt 不可见，但矩形非空，身份得以保留，塌陷稳定。
            h = 0.5;
        }
    } @catch (NSException *e) {}
    return h;
}

// 装行高钩子。
//   · 目标类自己有实现 -> 直接换 IMP
//   · 目标类没有实现   -> class_addMethod 给它加一个**只作用于这个子类**的覆盖
//   · 父类链上也拿不到原实现 -> **放弃**（加覆盖会让整页行高变 0）
// 三条路径的判据与后果都写在上面的分支注释里。
static void EGInstallHeightHook(void) {
    if (gEGHeightHookInstalled) return;
    Class c = EGResolveClass(EG_RULE_MINE_TABLE_VC);   // ★ 走解析，兼容 "e高速." 前缀
    if (!c) {
        EGDiag(@"[规则·行高] 找不到类 %s —— 不装（不猜父类）", EG_RULE_MINE_TABLE_VC);
        return;
    }
    SEL sel = @selector(tableView:heightForRowAtIndexPath:);

    // type encoding：CGFloat 在 64 位上是 d (double)；
    //   d@:@@   = CGFloat (self, _cmd, UITableView *, NSIndexPath *)
    // 这个字符串必须准确 —— 返回类型写错会让调用方按错误的宽度读返回值。
    static const char *kTypes = "d@:@@";

    Method own = EGOwnMethod(c, sel);
    if (own) {
        // (a) 自己有实现 —— 直接换
        IMP cur = method_getImplementation(own);
        if (cur == (IMP)EGHeightForRowHook) { gEGHeightHookInstalled = YES; return; }
        gEGOrigHeightForRow = method_setImplementation(own, (IMP)EGHeightForRowHook);
        gEGHeightHookInstalled = YES;
        EGDiag(@"[规则·行高] 已装 %s -%@（自有实现，orig=%p）",
               EG_RULE_MINE_TABLE_VC, NSStringFromSelector(sel), (void *)gEGOrigHeightForRow);
        return;
    }

    // (b) 没有自己的实现 —— 给它加一个覆盖。
    //     orig 取**父类**那份（UITableViewDelegate 链上的），这样我们的 hook
    //     调 orig 得到的是宿主原本的行高逻辑，而不是我们自己的。
    //     ★ 影响面被限制在 MyInfoViewControllerNew 这一个类上，不碰 UITableViewController。
    Method inherited = EGSafeInstanceMethod(c, sel);
    IMP inheritedIMP = inherited ? method_getImplementation(inherited) : NULL;

    // ★★ 安全闸：父类链上也没有实现 -> **绝不加覆盖**。
    //    因为我们的 hook 在 orig 为 NULL 时返回 0，那会把**整个「我的」页所有行高变成 0**
    //    —— 页面彻底空白。这比"广告没去掉"严重得多。
    //    "改不动就不改"永远优于"改出一个更坏的结果"。
    if (!inheritedIMP) {
        EGDiag(@"[规则·行高] %s 自身与父类链都没有 -%@ 的实现 -> **放弃规则 3**"
                @"（加覆盖会让整页行高变 0）。广告塌陷仍由规则 2 负责。",
               EG_RULE_MINE_TABLE_VC, NSStringFromSelector(sel));
        return;
    }

    if (class_addMethod(c, sel, (IMP)EGHeightForRowHook, kTypes)) {
        gEGOrigHeightForRow = inheritedIMP;
        gEGHeightHookInstalled = YES;
        EGDiag(@"[规则·行高] 已加覆盖 %s -%@（继承实现，orig=%p）",
               EG_RULE_MINE_TABLE_VC, NSStringFromSelector(sel), (void *)inheritedIMP);
    } else {
        EGDiag(@"[规则·行高] class_addMethod 失败 %s -%@ —— 规则 3 不生效，"
                @"只能靠规则 2 覆盖已实例化的 cell",
               EG_RULE_MINE_TABLE_VC, NSStringFromSelector(sel));
    }
}

// 从任意 view 向上找它所在的 UITableView（含 indexPath 反查）
static UITableView *EGEnclosingTableView(UIView *v, NSIndexPath **outIP) {
    if (outIP) *outIP = nil;
    UIView *cur = v;
    NSUInteger guard = 0;
    while (cur && guard++ < 64) {
        if ([cur isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)cur;
            if (outIP) {
                @try {
                    NSIndexPath *ip = [tv indexPathForCell:(UITableViewCell *)v];
                    if (!ip) {
                        // cell 可能有一层容器包着；逐级往上试
                        UIView *p = v.superview;
                        NSUInteger g2 = 0;
                        while (p && p != tv && g2++ < 8) {
                            if ([p isKindOfClass:[UITableViewCell class]]) {
                                ip = [tv indexPathForCell:(UITableViewCell *)p];
                                if (ip) break;
                            }
                            p = p.superview;
                        }
                    }
                    *outIP = ip;
                } @catch (NSException *e) {}
            }
            return tv;
        }
        cur = cur.superview;
    }
    return nil;
}

// ============================================================================
// ★ 消除空白的关键一步：让 UITableView **重新问一次行高** ==================
// ============================================================================
// 为什么必须有这一步（v0.2.1 实测翻车）：
//   我们改的是 cell 自己的 frame，而 UITableView 内部 `_rowData` 里缓存的行高
//   是**早先向 dataSource 问来的 79**。改 cell.frame 不会让这份缓存失效，
//   所以后面所有行的 y 纹丝不动 —— 表现就是"广告不见了，但留了一条 79pt 的空白"。
//
// 正确做法是让表格自己重排：
//   reloadRowsAtIndexPaths:  —— 苹果官方用来"改变某行高度"的 API。
//     它会重新走 heightForRowAtIndexPath:（我们的 hook 此时返回 0.5），
//     并把后面的行整体前移。比 reloadData 轻，不影响其他行。
//   万一它抛异常（宿主 dataSource 状态不允许），退到
//     beginUpdates/endUpdates —— 同样会触发一次行高重查，只是不重建 cell。
//
// ★ 只刷一次：key 记进 gEGAdRowsReloaded。
//   否则 reload → 建 cell → 巡检再刷 → 再建 cell …… 会一直闪。
// ============================================================================
static void EGRefreshAdRowHeights(NSMapTable *tvIPs) {
    if (!tvIPs) return;
    @synchronized (@"EGAdRows") {
        if (!gEGAdRowsReloaded) gEGAdRowsReloaded = [NSMutableSet set];
    }

    NSEnumerator *tvs = [tvIPs keyEnumerator];
    UITableView *tv = nil;
    while ((tv = [tvs nextObject])) {
        NSMutableSet<NSIndexPath *> *ips = [tvIPs objectForKey:tv];
        if (!ips.count) continue;

        // 先做边界校验 + 去重：表格可能已经重排过，旧的 indexPath 可能越界
        NSMutableArray<NSIndexPath *> *todo = [NSMutableArray array];
        @synchronized (@"EGAdRows") {
            for (NSIndexPath *ip in ips) {
                NSString *k = EGAdRowKey(tv, ip);
                if (!k || [gEGAdRowsReloaded containsObject:k]) continue;
                @try {
                    if (ip.section >= tv.numberOfSections) continue;
                    if (ip.row >= [tv numberOfRowsInSection:ip.section]) continue;
                } @catch (NSException *e) { continue; }
                [todo addObject:ip];
                [gEGAdRowsReloaded addObject:k];
            }
        }
        if (!todo.count) continue;

        BOOL done = NO;
        @try {
            [tv reloadRowsAtIndexPaths:todo withRowAnimation:UITableViewRowAnimationNone];
            done = YES;
            gEGAdReloadCount += todo.count;
            EGDiag(@"[规则·广告] 已强制重排行高 %lu 行（%@）—— 表格会重新问 heightForRow，"
                    @"后面的行随即上移",
                   (unsigned long)todo.count,
                   [todo componentsJoinedByString:@","]);
        } @catch (NSException *e) {
            EGDiag(@"[规则·广告] reloadRows 抛异常: %@ —— 退到 beginUpdates/endUpdates", e.reason);
        }
        if (!done) {
            @try {
                [tv beginUpdates];
                [tv endUpdates];
                gEGAdReloadCount += todo.count;
                EGDiag(@"[规则·广告] 已用 beginUpdates/endUpdates 触发行高重查");
            } @catch (NSException *e2) {
                EGDiag(@"[规则·广告] beginUpdates 也失败: %@", e2.reason);
            }
        }
        EGJournal("rule-ad-relayout");

        // 重排后 cell 会被重建一次，新的那个还没被隐藏。
        // 0.3s 后再扫一遍把它收掉（reloadRows 的 cell 创建不保证同步完成）。
        EGAfterOnMain(0.3, ^{
            @try { EGApplyMineAdRule(tv, "post-reload"); }
            @catch (NSException *e3) {}
        });
    }
}

// 塌陷**一个**广告 cell：登记行号（供规则 3）+ hidden + 高度压到 0.5。
// 返回 YES = 本轮真的动了这个 cell（用于统计，保证幂等计数不重复累加）。
// tvOut / ipOut：把"这个广告属于哪个表格的哪一行"回传给调用方 —— 调用方要拿它去
// **强制表格重新问一次行高**（见 EGRefreshAdRowHeights，那是真正消除空白的一步）。
static BOOL EGCollapseAdCell(UIView *v, const char *why, NSUInteger *regOut,
                             UITableView **tvOut, NSIndexPath **ipOut) {
    if (!v) return NO;
    CGFloat origH = v.frame.size.height;
    BOOL origHidden = v.hidden;
    gEGLastAdOrigH = origH;   // 留痕：用来判断"表格有没有真的按 0.5 重建这一行"

    // 登记行号（供规则 3）—— 独立于"是否已隐藏"，
    // 这样即使本轮因复用已被隐藏过，行号也不会漏登记
    NSIndexPath *ip = nil;
    UITableView *tv = EGEnclosingTableView(v, &ip);
    if (tv && ip) {
        NSString *k = EGAdRowKey(tv, ip);
        @synchronized (@"EGAdRows") {
            if (!gEGAdRowKeys) gEGAdRowKeys = [NSMutableSet set];
            if (k && ![gEGAdRowKeys containsObject:k]) {
                [gEGAdRowKeys addObject:k];
                if (regOut) (*regOut)++;
            }
        }
        if (tvOut) *tvOut = tv;
        if (ipOut) *ipOut = ip;
    }

    // 幂等：已经隐藏且高度为 0 就不再动
    if (origHidden && origH <= 0.5) return NO;

    v.hidden = YES;
    // ★ 高度设 0.5 而不是 0 —— 与 EGHeightForRowHook 同一理由：
    //   空矩形会让本行掉出可见区域计算、cell 被回收，我们就再也扫不到它。
    //   0.5pt 肉眼不可见，但保持"非空矩形"，身份稳定。
    CGRect f = v.frame;
    f.size.height = 0.5;
    v.frame = f;
    EGDiag(@"[规则·广告] 隐藏并塌陷 %@（判据=%s） frame=(%.0f,%.0f,%.0f,%.0f) -> h=0.5  行=%@",
           NSStringFromClass([v class]), why,
           f.origin.x, f.origin.y, f.size.width, origH,
           ip ? [NSString stringWithFormat:@"%ld.%ld", (long)ip.section, (long)ip.row] : @"(未定位)");
    return YES;
}

// ---- 规则 2：「我的」页广告位 隐藏 + 塌陷（并登记行号供规则 3 使用） ----
// 遍历整棵视图树：
//   · 命中广告类名的 cell -> hidden + 高度清零（"不显示"和"不占位"一起做）
//   · 顺手把它所在的 tableView + indexPath 登记进 gEGAdRowKeys，
//     让**尚未实例化**的同款行也能被规则 3 压成 0 高
static void EGApplyMineAdRule(UIView *root, const char *reason) {
#if EG_ENABLE_RULES
    if (!root) return;
    NSUInteger n = 0, reg = 0, zc = 0;
    @try {
        // 副判据收集：弱键 map —— cell 被回收时条目自动消失，不会留悬垂指针
        NSMapTable *zcCells = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                                   valueOptions:NSPointerFunctionsStrongMemory];
        // 广告行所在的「表格 -> 行号集合」，供 EGRefreshAdRowHeights 去重排版用
        NSMapTable *tvIPs = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                                 valueOptions:NSPointerFunctionsStrongMemory];
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
        NSUInteger guard = 0;
        while (stack.count && guard++ < 20000) {
            UIView *v = [stack lastObject];
            [stack removeLastObject];

            // 主判据：cell 类名（兼容 Swift 模块前缀）
            if (EGClassNameIs(v, EG_RULE_AD_CELL_CLASS)) {
                UITableView *atv = nil; NSIndexPath *aip = nil;
                if (EGCollapseAdCell(v, "类名", &reg, &atv, &aip)) n++;
                if (atv && aip) {
                    NSMutableSet *s = [tvIPs objectForKey:atv];
                    if (!s) { s = [NSMutableSet set]; [tvIPs setObject:s forKey:atv]; }
                    [s addObject:aip];
                }
            }
#if EG_RULE_AD_FALLBACK_ZCYCLE
            // 副判据：类名换了（版本升级/混淆）也不至于全瞎。
            //   实测广告内部是 ZCycleView（轮播）-> UICollectionView。
            //   遇到 ZCycle* 就往上找最近的 UITableViewCell，把它当广告容器塌陷。
            //   只在「我的」页视图树里跑（调用方已限定），影响面可控。
            else {
                const char *vn = class_getName([v class]);
                if (vn && strstr(EGClassBareName(vn), EG_RULE_AD_ZCYCLE_HINT)) {
                    UIView *p = v.superview;
                    NSUInteger g2 = 0;
                    while (p && g2++ < 12) {
                        if ([p isKindOfClass:[UITableViewCell class]]) break;
                        p = p.superview;
                    }
                    // ★ NSMapTable **不支持**下标写法（zcCells[p] = ... 编译不过：
                    //   "expected method to write dictionary element not found"）。
                    //   必须走 setObject:forKey:。弱键 map，天然去重。
                    if (p) [zcCells setObject:@"ZCycle" forKey:p];
                }
            }
#endif
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }

        // 副判据收集到的容器，统一塌陷（放在遍历后 —— 避免在遍历中改 frame）
        // 用 keyEnumerator 而不是 for-in：NSMapTable 的快速枚举语义不如 NSArray 直观，
        // 明确枚举 key 更不容易出错。
        NSEnumerator *keys = [zcCells keyEnumerator];
        UIView *p = nil;
        while ((p = [keys nextObject])) {
            UITableView *atv = nil; NSIndexPath *aip = nil;
            if (EGCollapseAdCell(p, "ZCycle", &reg, &atv, &aip)) { n++; zc++; }
            if (atv && aip) {
                NSMutableSet *s = [tvIPs objectForKey:atv];
                if (!s) { s = [NSMutableSet set]; [tvIPs setObject:s forKey:atv]; }
                [s addObject:aip];
            }
        }

        // ★ 真正消掉空白的一步：让表格重排一次。
        //   放在塌陷之后 —— 先登记好行号，重排时 hook 才会返回 0.5。
        //
        // 兜底升级：若这是一次"重排后的补扫"、且广告 cell 仍按 79pt 建出来
        // （gEGLastAdOrigH > 1），说明 reloadRows 没吃进去 —— 直接 reloadData。
        // 只做一次（gEGAdReloadDataDone），避免每次巡检都整表重建。
        BOOL escalated = NO;
        if (reason && strcmp(reason, "post-reload") == 0 &&
            gEGLastAdOrigH > 1.0 && !gEGAdReloadDataDone && tvIPs.count) {
            gEGAdReloadDataDone = YES;
            NSEnumerator *te = [tvIPs keyEnumerator];
            UITableView *atv2 = nil;
            while ((atv2 = [te nextObject])) {
                @try {
                    [atv2 reloadData];
                    EGDiag(@"[规则·广告] 重排未生效（cell 仍按 %.0fpt 建）-> 已整表 reloadData",
                           (double)gEGLastAdOrigH);
                } @catch (NSException *ee) {
                    EGDiag(@"[规则·广告] reloadData 失败: %@", ee.reason);
                }
                EGAfterOnMain(0.3, ^{
                    @try { EGApplyMineAdRule(atv2, "post-reload"); }
                    @catch (NSException *e3) {}
                });
            }
            escalated = YES;
        }
        if (!escalated) EGRefreshAdRowHeights(tvIPs);

        if (n || reg) {
            gEGAdCellHiddenCount += n;
            EGJournal("rule-ad-ok");
            EGDiag(@"[规则·广告] (%s) 本轮塌陷 %lu 个（其中 ZCycle 兜底 %lu 个），"
                    @"新登记行号 %lu 个（累计登记 %lu）",
                   reason, (unsigned long)n, (unsigned long)zc, (unsigned long)reg,
                   (unsigned long)(gEGAdRowKeys ? gEGAdRowKeys.count : 0));
        }
    } @catch (NSException *e) {
        EGDiag(@"[规则·广告] 异常: %@", e.reason);
    }
#endif
}

// ---- 规则总入口：对一个 tabBarController 把三条规则跑一遍（幂等） ----
static void EGApplyAllRules(UITabBarController *tbc, const char *reason) {
#if EG_ENABLE_RULES
    EGApplyTabBarRule(tbc, reason);

    // 广告规则只在进入「我的」页时才跑（其他页没有这个 cell，跑了也是空转）
    //
    // ★ v0.2.1 删掉了 v0.2.0 那句 `strcmp(cn,"RootNavigationController")`：
    //   它同样会撞上 Swift 模块前缀，等于又加了一道必然失配的门；
    //   而且它本来就是多余的 —— 我们要的是"当前页是不是「我的」"，
    //   跟外面那层导航控制器叫什么名字无关。直接问最上面那个 VC。
    UIViewController *sel = nil;
    @try { sel = tbc.selectedViewController; } @catch (NSException *e) {}
    if (!sel) return;

    UIViewController *top = sel;
    if ([sel isKindOfClass:[UINavigationController class]]) {
        @try {
            UIViewController *t = [(UINavigationController *)sel topViewController];
            if (t) top = t;
        } @catch (NSException *e) {}
    }
    if (!EGClassNameIs(top, EG_RULE_MINE_TABLE_VC)) return;

    if (gEGGuardTripped) return;
    EGApplyMineAdRule(top.view, reason);
#endif
}

// ============================================================================
// 规则钩子安装 —— 单类单 selector 单 shim，与 viewDidAppear 那套同一纪律
// ============================================================================
//
// hook 两个类，各两个（或一个）selector：
//   RootTabBarController : viewDidLoad / viewWillAppear:
//        —— 两个时机都挂，因为**构造时机未知**：
//           实测只能证明"运行时它有 5 个"，不能证明"什么时候变成 5 个"。
//           两个都挂 + 幂等 = 不依赖时序假设。（这是 2026-10-01 抓取后确定的做法）
//   MyInfoViewControllerNew : viewWillAppear:（另外还有 heightForRow，见规则 3）
//        —— 「我的」页每次出现都巡检一次广告位（cell 复用会重新显示）
//
// ★ 为什么 viewWillAppear: 要装在**每个具体类自己**的实现上，而不是 UIViewController：
//   viewWillAppear: 是"每个子类各写各的"的方法，不存在一个父类实现能覆盖全部。
//   装 3 个具体类 = 3 个 shim，各自独立；这与"装一个 UIViewController.viewDidAppear:"
//   完全不同 —— 后者是父类单点、子类调 super 会回到同一个 shim，才有递归风险。
//   这里每个类只挂自己那一份，调用链是 [self viewWillAppear:] -> 我们 -> 原 IMP，
//   我们的原 IMP 指向该类的**上一级**实现，不存在回到自己的路径。

static IMP  gEGOrigRootTBCViewDidLoad    = NULL;
static IMP  gEGOrigRootTBCViewWillAppear = NULL;
static IMP  gEGOrigMineViewWillAppear    = NULL;
static BOOL gEGRulesHooksInstalled       = NO;

static void EGRootTBCViewDidLoadHook(id self, SEL _cmd) {
    IMP orig = gEGOrigRootTBCViewDidLoad;
    if (orig) @try { ((void (*)(id, SEL))orig)(self, _cmd); } @catch (NSException *e) {}
    @try {
        if ([self isKindOfClass:[UITabBarController class]]) {
            EGApplyAllRules((UITabBarController *)self, "viewDidLoad");
        }
    } @catch (NSException *e) { EGDiag(@"[规则] viewDidLoad 异常: %@", e.reason); }
}

static void EGRootTBCViewWillAppearHook(id self, SEL _cmd, BOOL animated) {
    IMP orig = gEGOrigRootTBCViewWillAppear;
    if (orig) @try { ((void (*)(id, SEL, BOOL))orig)(self, _cmd, animated); } @catch (NSException *e) {}
    @try {
        if ([self isKindOfClass:[UITabBarController class]]) {
            EGApplyAllRules((UITabBarController *)self, "viewWillAppear");
        }
    } @catch (NSException *e) { EGDiag(@"[规则] viewWillAppear 异常: %@", e.reason); }
}

static void EGMineViewWillAppearHook(id self, SEL _cmd, BOOL animated) {
    IMP orig = gEGOrigMineViewWillAppear;
    if (orig) @try { ((void (*)(id, SEL, BOOL))orig)(self, _cmd, animated); } @catch (NSException *e) {}
    @try {
        if ([self isKindOfClass:[UIViewController class]]) {
            EGApplyMineAdRule(((UIViewController *)self).view, "mine-page-willAppear");
        }
    } @catch (NSException *e) { EGDiag(@"[规则] mine willAppear 异常: %@", e.reason); }
}

// 通用安装器：给**指定的这一个类**挂钩子。
//
// ★ 两种情形分开处理，这是关键：
//   (a) 目标类**自己有**这个方法的实现
//       -> method_setImplementation，orig 就是它原来的 IMP。调用链：
//          [self viewDidLoad] -> 我们的 hook -> 原 IMP。干净。
//   (b) 目标类**没有**自己的实现（继承父类的）
//       -> **不能**去改父类的 IMP（会波及全 App 同父类的所有对象）。
//          正确做法是 class_addMethod 给**这个子类**加一个覆盖，orig 取父类那份 IMP。
//          调用链：[self viewDidLoad] -> 我们的 hook -> 父类 IMP。同样干净，且影响面
//          被限制在这一个子类里。
//
//   ★ 早前的 EGInstallOne 只做了 (a)，遇到 (b) 直接放弃 —— 那会让规则只能靠巡检兜底。
//     实测数据回答不了"RootTabBarController 有没有自己实现 viewDidLoad"这个问题
//     （抓取只 dump 了对象状态，没有 dump 方法归属）。既然两种情形都有正确解法，
//     就不该把一个可以解决的问题留给兜底通道。
//
// 为什么这里加方法安全、而 v0.1 在 %ctor 里动宿主是危险的：时机完全不同。
//   这里在主队列上、宿主 +load 跑完之后、只加**一个子类的一个方法**；
//   v0.1 是在 dyld 初始化阶段覆盖宿主的信号处理器和备用栈。
static BOOL EGInstallOne(Class c, SEL sel, IMP hook, const char *types,
                         IMP *outOrig, const char *what) {
    if (!c) return NO;
    if (!types) {
        EGDiag(@"[规则·钩子] %s -%@ 未提供 type encoding —— 跳过",
               class_getName(c), NSStringFromSelector(sel));
        return NO;
    }

    Method own = EGOwnMethod(c, sel);
    if (own) {
        // (a) 自己有实现
        IMP cur = method_getImplementation(own);
        if (cur == hook) return YES;                 // 幂等
        IMP prev = method_setImplementation(own, hook);
        if (outOrig) *outOrig = prev;
        EGDiag(@"[规则·钩子] %s -%@ 已装（自有实现，orig=%p）%s",
               class_getName(c), NSStringFromSelector(sel), (void *)prev, what ? what : "");
        return YES;
    }

    // (b) 没有自己的实现 —— 给这个子类加一个覆盖
    //     先看看能不能从父类链上拿到原实现（拿到就把父类 IMP 当 orig，否则 orig=NULL）
    Method inherited = EGSafeInstanceMethod(c, sel);
    IMP inheritedIMP = inherited ? method_getImplementation(inherited) : NULL;

    if (!class_addMethod(c, sel, hook, types)) {
        EGDiag(@"[规则·钩子] %s -%@ class_addMethod 失败（可能已被别的 hook 加了）",
               class_getName(c), NSStringFromSelector(sel));
        return NO;
    }
    // class_addMethod 成功后，刚才加进去的就是我们的 hook。
    // 若此时调用 method_getImplementation(class_getInstanceMethod(...)) 会拿到 hook 自己，
    // 所以 orig 必须用**加之前**就从父类拿到的那个 IMP。
    if (outOrig) *outOrig = inheritedIMP;
    EGDiag(@"[规则·钩子] %s -%@ 已加覆盖（继承实现，orig=%p）%s",
           class_getName(c), NSStringFromSelector(sel), (void *)inheritedIMP, what ? what : "");
    return YES;
}

static void EGInstallRulesHooks(void) {
#if EG_ENABLE_RULES
    // ★ 失败**不锁死**：只要还有一个类没解析到，就允许下一轮重试。
    //   （v0.2.0 在这里无条件 gEGRulesHooksInstalled = YES，一次失败 = 永久放弃）
    if (gEGRulesHooksInstalled) return;

    Class tbc  = EGResolveClass(EG_RULE_TAB_VC);           // ★ 解析，兼容 "e高速." 前缀
    Class mine = EGResolveClass(EG_RULE_MINE_TABLE_VC);
    if (tbc && mine) gEGRulesHooksInstalled = YES;         // 两个都拿到才算装完

    if (tbc) {
        // type encoding 必须**写死**：class_addMethod 走的是 (b) 分支时需要它。
        //   "v@:"        = void (self, _cmd)
        //   "v@:B"       = void (self, _cmd, BOOL)   —— viewWillAppear: 的参数是 BOOL
        // 写错会导致调用约定不匹配、栈错位 —— 所以这里只对照苹果文档写死，不做推断。
        EGInstallOne(tbc, @selector(viewDidLoad), (IMP)EGRootTBCViewDidLoadHook,
                     "v@:", &gEGOrigRootTBCViewDidLoad, "tbc.viewDidLoad");
        EGInstallOne(tbc, @selector(viewWillAppear:), (IMP)EGRootTBCViewWillAppearHook,
                     "v@:B", &gEGOrigRootTBCViewWillAppear, "tbc.viewWillAppear");
    } else {
        EGDiag(@"[规则·钩子] 找不到 %s —— 底栏规则只能靠周期巡检（下轮重试）", EG_RULE_TAB_VC);
    }

    if (mine) {
        EGInstallOne(mine, @selector(viewWillAppear:), (IMP)EGMineViewWillAppearHook,
                     "v@:B", &gEGOrigMineViewWillAppear, "mine.viewWillAppear");
    } else {
        EGDiag(@"[规则·钩子] 找不到 %s —— 广告规则只能靠周期巡检（下轮重试）", EG_RULE_MINE_TABLE_VC);
    }

    EGInstallHeightHook();
#endif
}

// 类解析留痕 —— 诊断里直接输出「裸名 -> runtime 真名」。
// 目的：让"类名对不对"这件事**一眼可判**，不用再靠推理。
static NSString *EGClassResolutionReport(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"  底栏控制器   %-30s -> %@\n", EG_RULE_TAB_VC,        EGResolvedName(EG_RULE_TAB_VC)];
    [s appendFormat:@"  「我的」页VC  %-30s -> %@\n", EG_RULE_MINE_TABLE_VC, EGResolvedName(EG_RULE_MINE_TABLE_VC)];
    [s appendFormat:@"  广告 cell    %-30s -> %@\n", EG_RULE_AD_CELL_CLASS,  EGResolvedName(EG_RULE_AD_CELL_CLASS)];
    return s;
}

// ---- 周期巡检：兜住"钩子时机没赶上"的情况 ----
// 为什么不只靠钩子：hook 装在 viewDidLoad/viewWillAppear: 上，若宿主在
// **更早的时机**就把 viewControllers 塞好了、且那之后不再走这两个方法，
// 钩子就永远等不到。周期巡检与钩子**互为兜底**，任一通道生效即可。
// 只在"还没达成目标"时才继续巡检，达成后自动停 —— 不做无谓的常驻开销。
static NSUInteger gEGWatchRounds = 0;

static void EGWatchMinePage(void) {
#if EG_ENABLE_RULES
    if (gEGGuardTripped) return;
    // ★ 至少跑满 4 轮再收工。
    //   v0.2.1 的教训：第 1 轮塌陷成功就收工了，但"表格重排 + 重建 cell 后再收一次"
    //   这件事发生在第 1 轮**之后** —— 收工太早会漏掉重排后的补扫。
    if (gEGTabBarNarrowed && gEGAdCellHiddenCount > 0 && gEGWatchRounds >= 4) return;
    gEGWatchRounds++;

    // ★ 钩子还没装全 -> 每轮重试（宿主类可能在首轮之后才被加载/注册）
    if (!gEGRulesHooksInstalled) EGInstallRulesHooks();

    @try {
        NSArray *tbcs = EGFindTabBarControllers();
        for (id t in tbcs) {
            if ([t isKindOfClass:[UITabBarController class]]) {
                EGApplyAllRules((UITabBarController *)t, "watchdog");
            }
        }
    } @catch (NSException *e) {
        EGDiag(@"[规则·巡检] 异常: %@", e.reason);
    }

    if (gEGWatchRounds == 1 || gEGWatchRounds % 5 == 0) {
        EGDiag(@"[规则·巡检] 第 %lu 轮：底栏 %@ / 已塌陷广告 %lu 个",
               (unsigned long)gEGWatchRounds,
               gEGTabBarNarrowed ? @"已收窄" : @"未收窄",
               (unsigned long)gEGAdCellHiddenCount);
    }
#endif
}

// ============================== 剪贴板 / 悬浮球 ==============================

static void EGSetClipboard(NSString *text) {
    if (!text) return;
    @try {
        [UIPasteboard generalPasteboard].string = text;
    } @catch (NSException *e) {
        EGDiag(@"[剪贴板] 写入失败: %@", e.reason);
    }
}

// 按钮标题闪一下 —— 让"点到了没有"这件事**不需要看日志就能回答**。
// 一次点击如果只有看不见的副作用，用户无法区分"坏了"和"成功了"。
static void EGFlashButton(NSString *text) {
    if (!gEGButton) return;
    @try {
        [gEGButton setTitle:text forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try { [gEGButton setTitle:@"EG" forState:UIControlStateNormal]; }
            @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}

// 悬浮球手势代理：轻点 = 抓当前页；长按 = 完整诊断；拖动 = 移动。
@interface EGButtonProxy : NSObject
@end

@implementation EGButtonProxy

- (void)onTap:(UITapGestureRecognizer *)g {
    (void)g;
    EGCaptureCurrentPage(@"点击");
}

- (void)onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        EGCaptureFull();
    }
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    UIWindow *w = v.window;
    if (!v || !w) return;
    CGPoint p = [g translationInView:w];
    CGFloat half = v.bounds.size.width / 2.0;
    CGFloat cx = v.center.x + p.x;
    CGFloat cy = v.center.y + p.y;
    cx = MAX(half + 4.0, MIN(w.bounds.size.width - half - 4.0, cx));
    cy = MAX(half + 40.0, MIN(w.bounds.size.height - half - 4.0, cy));
    v.center = CGPointMake(cx, cy);
    [g setTranslation:CGPointZero inView:w];
}

@end

static void EGInstallOverlay(void) {
    if (gEGButton) return;
    @try {
        // 挑一个"有 scene 的可见窗口"作为宿主。
        // 不自建 UIWindow：iOS 13+ 用 initWithFrame: 建的 window 可能没有 scene，
        // 那只是个孤儿窗口，永远不显示（这是踩过的坑）。
        UIWindow *host = nil;
        for (UIWindow *c in EGAllWindows()) {
            if (c.hidden || c.alpha < 0.01) continue;
            id scene = nil;
            @try { scene = [c valueForKey:@"windowScene"]; } @catch (NSException *e) {}
            if (scene) { host = c; break; }
        }
        if (!host) {
            for (UIWindow *c in EGAllWindows()) {
                if (!c.hidden && c.alpha >= 0.01) { host = c; break; }
            }
        }
        if (!host) {
            EGDiag(@"[悬浮球] 找不到可用窗口，放弃安装");
            return;
        }

        CGFloat side = 46.0;
        CGRect hb = host.bounds;
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(hb.size.width - side - 8.0, 130.0, side, side);
        btn.backgroundColor = [UIColor colorWithRed:0.0 green:0.42 blue:0.75 alpha:0.88];
        btn.layer.cornerRadius = side / 2.0;
        btn.layer.masksToBounds = YES;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:15.0];
        [btn setTitle:@"EG" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

        EGButtonProxy *proxy = [[EGButtonProxy alloc] init];
        gEGProxy = proxy;

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:proxy action:@selector(onTap:)];
        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:proxy action:@selector(onLongPress:)];
        lp.minimumPressDuration = 0.6;
        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:proxy action:@selector(onPan:)];
        [btn addGestureRecognizer:tap];
        [btn addGestureRecognizer:lp];
        [btn addGestureRecognizer:pan];

        [host addSubview:btn];
        [host bringSubviewToFront:btn];
        gEGButton = btn;
        gEGHostWindow = host;
        EGDiag(@"[悬浮球] 已挂到 %@（%@）", NSStringFromClass([host class]),
               NSStringFromClass([host.rootViewController class]));

        // 定时置顶：App 重建视图树时可能把按钮盖住，1.5 秒一次把它提回来。
        // 幂等且极廉价（只是两次指针比较 + 一次 bringSubviewToFront）。
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_main_queue());
        if (t) {
            dispatch_source_set_timer(t,
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                (uint64_t)(1.5 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(t, ^{
                @try {
                    UIButton *bb = gEGButton;
                    UIWindow *ww = gEGHostWindow;
                    if (!bb || !ww) return;
                    if (bb.superview != ww) [ww addSubview:bb];
                    [ww bringSubviewToFront:bb];
                } @catch (NSException *e) {}
            });
            gEGTopTimer = t;
            dispatch_resume(t);
        }
    } @catch (NSException *e) {
        EGDiag(@"[悬浮球] 安装失败: %@", e.reason);
    }
}

// ============================== 采集 ==============================

static void EGCaptureCurrentPage(NSString *why) {
    EGStageSet("抓取当前页");
    @autoreleasepool {
        NSMutableString *out = [NSMutableString string];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        NSString *now = [df stringFromDate:[NSDate date]];

        [out appendFormat:@"########## %@ 抓取（%@）@ %@ ##########\n", @EG_TAG, why, now];

        UIViewController *vc = EGCurrentVC();
        [out appendString:@"\n===== 当前页面 =====\n"];
        [out appendFormat:@"  当前 VC = %@\n", vc ? NSStringFromClass([vc class]) : @"(未识别)"];
        [out appendFormat:@"  VC 链   = %@\n", vc ? EGVCChainOf(vc, 12) : @"(无)"];
        UIView *root = vc.view;
        if (root) {
            UIView *win = root.window;
            CGRect w = win ? [root convertRect:root.bounds toView:win] : root.bounds;
            [out appendFormat:@"  根视图 = %@ win=(%.0f,%.0f,%.0f,%.0f)\n",
                NSStringFromClass([root class]),
                w.origin.x, w.origin.y, w.size.width, w.size.height];
        }

        [out appendString:@"\n===== 底栏取证 =====\n"];
        [out appendString:EGTabBarForensics()];

        [out appendString:@"\n===== 自绘底栏候选（类名扫描） =====\n"];
        [out appendString:EGScanTabBarLikeClasses()];

        [out appendString:@"\n===== 当前页视图树（win = 窗口坐标） =====\n"];
        [out appendString:EGDumpViewTree(root, EG_DUMP_MAX_DEPTH, EG_DUMP_MAX_NODES)];

        [out appendString:@"\n===== 广告候选汇总（只报告，不隐藏） =====\n"];
        [out appendString:EGBannerCandidates(root)];

        [out appendString:@"\n===== 本会话出现过的 VC 类名 =====\n"];
        @synchronized (@"EGVCLive") {
            if (gEGSeenVCClasses.count) {
                for (NSString *n in [[gEGSeenVCClasses allObjects]
                                     sortedArrayUsingSelector:@selector(compare:)]) {
                    [out appendFormat:@"  %@\n", n];
                }
            } else {
                [out appendString:@"  (本会话还没记录到 VC —— ENABLE_VIEWDIDAPPEAR_HOOK=0 时这是预期的)\n"];
            }
        }

        [out appendString:@"\n===== 诊断缓冲 =====\n"];
        [out appendString:EGDiagSnapshot()];
        [out appendString:@"\n########## 抓取结束 ##########\n"];

        NSString *text = out;
        EGSetClipboard(text);
        EGFlashButton([NSString stringWithFormat:@"%.1fk", text.length / 1024.0]);
        EGDiag(@"[抓取] 当前页 dump 完成，%lu 字符，已写剪贴板", (unsigned long)text.length);
    }
}

static void EGCaptureFull(void) {
    EGStageSet("抓取完整诊断");
    @autoreleasepool {
        NSMutableString *out = [NSMutableString string];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";

        [out appendFormat:@"########## %@ 完整诊断 @ %@ ##########\n",
            @EG_TAG, [df stringFromDate:[NSDate date]]];
        [out appendFormat:@"版本 = %@   变体 = %s   构建令牌 = %s\n",
            @EG_VERSION, EG_VARIANT_TAG, EGBuildToken()];
        [out appendFormat:@"阶段 = %s\n", EGStageText()];

        // ★ 启动流水：判定「是不是我们引起的」的直接证据。
        //   每次启动一行「单调时钟 + 阶段 + 变体」。若某次启动崩了，这一行就停在崩之前的最后一步。
        [out appendString:@"\n===== 启动流水（最近若干次启动） =====\n"];
        [out appendFormat:@"%@\n", EGJournalTail(4096)];

        [out appendString:@"\n===== 上次崩溃回读 =====\n"];
        EGReadBackCrashLog();
        [out appendFormat:@"%@\n", gEGCrashReport.length ? gEGCrashReport : @"(无崩溃记录)\n"];

        // ★ v0.2：规则执行状态 —— 一眼看出"改成了没有"
        [out appendString:@"\n===== 规则状态 =====\n"];
        [out appendString:@"----- 类名解析（裸名 -> runtime 真名） -----\n"];
        [out appendString:EGClassResolutionReport()];
        [out appendFormat:@"  底栏钩子已装   = %@\n", gEGRulesHooksInstalled ? @"是" : @"否"];
        [out appendFormat:@"  底栏已收窄     = %@（累计移除 %lu 个）\n",
            gEGTabBarNarrowed ? @"是" : @"否", (unsigned long)gEGTabBarCutCount];
        [out appendFormat:@"  广告位已塌陷   = %lu 个 cell\n", (unsigned long)gEGAdCellHiddenCount];
        [out appendFormat:@"  行高钩子已装   = %@\n", gEGHeightHookInstalled ? @"是" : @"否"];
        [out appendFormat:@"  广告行号已登记 = %lu 条\n",
            (unsigned long)(gEGAdRowKeys ? gEGAdRowKeys.count : 0)];
        [out appendFormat:@"  行高已强制重排 = %lu 行  ← 空白有没有消掉就看这一项\n",
            (unsigned long)gEGAdReloadCount];
        [out appendFormat:@"  巡检轮次       = %lu\n", (unsigned long)gEGWatchRounds];
        [out appendString:@"\n"];

        [out appendString:@"\n===== 底栏取证 =====\n"];
        [out appendString:EGTabBarForensics()];

        [out appendString:@"\n===== 自绘底栏候选（类名扫描） =====\n"];
        [out appendString:EGScanTabBarLikeClasses()];

        [out appendString:@"\n===== 广告类名候选（只报告） =====\n"];
        [out appendString:EGScanClassNames(EG_SCAN_KEYWORDS_AD, 60)];

        [out appendString:@"\n===== 「我的」页 VC 类名候选（只报告） =====\n"];
        [out appendString:EGScanClassNames(EG_SCAN_KEYWORDS_MINE, 60)];

        [out appendString:@"\n===== 本会话出现过的 VC 类名 =====\n"];
        @synchronized (@"EGVCLive") {
            if (gEGSeenVCClasses.count) {
                for (NSString *n in [[gEGSeenVCClasses allObjects]
                                     sortedArrayUsingSelector:@selector(compare:)]) {
                    [out appendFormat:@"  %@\n", n];
                }
            } else {
                [out appendString:@"  (无)\n"];
            }
        }

        UIView *root = EGRootViewOfCurrentScreen();
        [out appendString:@"\n===== 当前页视图树 =====\n"];
        [out appendString:EGDumpViewTree(root, EG_DUMP_MAX_DEPTH, EG_DUMP_MAX_NODES)];

        [out appendString:@"\n===== 广告候选汇总 =====\n"];
        [out appendString:EGBannerCandidates(root)];

        [out appendString:@"\n===== 诊断缓冲 =====\n"];
        [out appendString:EGDiagSnapshot()];
        [out appendString:@"\n########## 诊断结束 ##########\n"];

        NSString *text = out;
        EGSetClipboard(text);
        EGFlashButton([NSString stringWithFormat:@"%.1fk", text.length / 1024.0]);
        EGDiag(@"[抓取] 完整诊断完成，%lu 字符，已写剪贴板", (unsigned long)text.length);
    }
}

// ============================== hook ==============================
//
// ★ v0.1.2：整段用 ENABLE_VIEWDIDAPPEAR_HOOK 包起来，**探针阶段默认关闭**。
//   收益≈0：探针的产出靠「点 EG」+ 启动后定时 dump，这个钩子只多一条「VC 首次出现」日志。
//   风险>0：要在宿主**最热的类**上换 IMP；宿主若有方法完整性校验，这是最显眼的一处。
//   顺带好处：关掉后这一整段不参与编译，也就不存在"未使用函数"这类告警。
#if ENABLE_VIEWDIDAPPEAR_HOOK

// 一个类、一个 selector、一个 shim、一个全局 orig IMP。
//   绝不装"每个实现类各一份"的通用安装器：共享 shim 无法区分直接调用与 [super] 调用
//   （[super viewDidAppear:] 会再进同一个 shim，而 shim 只能按对象类名查表，
//    查到的还是自己 -> 无限递归爆栈）。
//   代价：子类若覆写且不调 super，我们就看不见它 —— 对 viewDidAppear: 这种
//   Apple 要求必须调 super 的方法，这个损失可以接受。
static void EGViewDidAppearHook(id self, SEL _cmd, BOOL animated) {
    IMP orig = gEGOrigViewDidAppear;
    if (orig) {
        ((void (*)(id, SEL, BOOL))orig)(self, _cmd, animated);
    }
    @try {
        if (![self isKindOfClass:[UIViewController class]]) return;
        UIViewController *vc = (UIViewController *)self;
        gEGLastVC = vc;
        NSString *cls = NSStringFromClass([vc class]);
        BOOL isNew = NO;
        @synchronized (@"EGVCLive") {
            if (!gEGVCLive) gEGVCLive = [NSHashTable weakObjectsHashTable];
            [gEGVCLive addObject:vc];
            if (!gEGSeenVCClasses) gEGSeenVCClasses = [NSMutableSet set];
            if (cls && ![gEGSeenVCClasses containsObject:cls]) {
                [gEGSeenVCClasses addObject:cls];
                isNew = YES;
            }
        }
        if (isNew) EGDiag(@"[VC] 首次出现 %@", cls);
    } @catch (NSException *e) {
        EGDiag(@"[VC hook] 异常: %@", e.reason);
    }
}

static void EGInstallViewDidAppearHook(void) {
    if (gEGVDAInstalled) return;
    Class vc = objc_getClass("UIViewController");
    if (!vc) { EGDiag(@"[hook] 找不到 UIViewController"); return; }
    SEL sel = @selector(viewDidAppear:);
    Method own = EGOwnMethod(vc, sel);
    if (!own) {
        EGDiag(@"[hook] UIViewController 没有自己的 viewDidAppear: —— 放弃（不猜）");
        return;
    }
    IMP cur = method_getImplementation(own);
    if (cur == (IMP)EGViewDidAppearHook) {   // 幂等：装过就不再装
        gEGVDAInstalled = YES;
        return;
    }
    gEGOrigViewDidAppear = method_setImplementation(own, (IMP)EGViewDidAppearHook);
    gEGVDAInstalled = YES;
    EGDiag(@"[hook] 已装 UIViewController.viewDidAppear:（单类单 shim，orig=%p）",
           (void *)gEGOrigViewDidAppear);
}

#else   // !ENABLE_VIEWDIDAPPEAR_HOOK

// 关掉时给一个**有日志**的空实现，让 EGEnsureStarted 的调用点不必再包 #if（少一处出错机会）。
// 关键：不写"完全空"，而是写明确日志 —— 这样看诊断的人一眼能区分
//   「钩子被主动关掉了」 与 「钩子装了但没生效」。
// 这两种情况在诊断文本里必须能分开，否则会得出相反结论。
static void EGInstallViewDidAppearHook(void) {
    EGDiag(@"[hook] viewDidAppear: 钩子**主动关闭**（ENABLE_VIEWDIDAPPEAR_HOOK=0）");
}

#endif  // ENABLE_VIEWDIDAPPEAR_HOOK

// ============================== 启动 ==============================

static void EGEnsureStarted(void) {
    if (gEGStarted) return;
    gEGStarted = YES;

    // ★ 判读上一次启动是否异常结束 —— **必须在写本次 ensure-start 之前**
    //   （原因见 EGLastLaunchUnclean 的注释：先写就会把本次这一行当成"上一次"）。
    BOOL lastUnclean = EGLastLaunchUnclean();

    // 流水第一行：能走到这里，说明「%ctor 的 dispatch_async 块」真的被主队列执行了。
    // 这一行是整个判定链的锚点 —— 如果崩溃后流水里连它都没有，就说明崩在它之前。
    EGJournal("ensure-start");

    // ---- 以下三件事在 v0.1 里是 %ctor（dyld 阶段）做的，v0.1.1 全部挪到这里 ----
    // 现在跑在主队列上：runloop 已起来，Foundation / 文件系统 / 信号都安全，
    // 而且宿主自己的 +load 已经跑完了 —— 完整依据见 %ctor 上方那段。
    EGInitCrashLogPath();
    EGJournalRotate();
    EGJournal("paths-ok");
#if ENABLE_CRASH_HANDLERS
    EGInstallCrashHandlers();
#else
    // 不装：避免在宿主的初始化链里覆盖它自己的信号处理器（见配置区的说明）
#endif
    int guardCount = EGLaunchGuardCheck();
    if (guardCount != 0) gEGGuardTripped = YES;
    EGJournal(gEGGuardTripped ? "guard-TRIPPED" : "guard-ok");

    EGStageSet("启动完成");
    EGDiag(@"[启动] %@ %@ 已加载（变体=%s bundle=%s）",
           @EG_TAG, @EG_VERSION, EG_VARIANT_TAG, EG_BUNDLE_ID);
#if !ENABLE_CRASH_HANDLERS
    EGDiag(@"[启动] 信号处理器未装（ENABLE_CRASH_HANDLERS=0）—— 不覆盖宿主自己的");
#endif

    @synchronized (@"EGVCLive") {
        if (!gEGVCLive) gEGVCLive = [NSHashTable weakObjectsHashTable];
        if (!gEGSeenVCClasses) gEGSeenVCClasses = [NSMutableSet set];
    }

    EGReadBackCrashLog();
    if (gEGCrashReport.length) {
        EGDiag(@"[崩溃回读] 上次运行留下了 %lu 字符的崩溃记录（长按 EG 可完整查看）",
               (unsigned long)gEGCrashReport.length);
    }

    if (gEGGuardTripped) {
        EGDiag(@"[自愈] 本次启动不装任何钩子 —— 只有悬浮球可用（长按可看崩溃回读）");
    } else {
        // 开关关闭时这个函数自身就是"写日志说明被关掉"的实现，调用点不必再包 #if
        EGInstallViewDidAppearHook();

        // ★ v0.2：装规则钩子（底栏收窄 + 广告位塌陷）
        EGInstallRulesHooks();
        EGJournal(gEGRulesHooksInstalled ? "rules-hooks-ok" : "rules-hooks-skip");
    }

#if ENABLE_FLOAT_BUTTON
    EGInstallOverlay();
    EGJournal(gEGButton ? "overlay-ok" : "overlay-FAILED");
#else
    EGJournal("overlay-skip");
#endif

    // 启动后自动 dump 一次底栏 —— 用户没点按钮也能拿到数据
#if ENABLE_AUTO_DUMP
    EGAfterOnMain(3.0, ^{
        EGStageSet("自动 dump 底栏 +3s");
        EGJournal("dump+3s");
        EGDiag(@"[自动 dump·3s] 底栏取证：\n%@", EGTabBarForensics());
        EGDiag(@"[自动 dump·3s] 自绘底栏候选：\n%@", EGScanTabBarLikeClasses());
    });
    EGAfterOnMain(8.0, ^{
        EGStageSet("自动 dump 底栏 +8s");
        EGJournal("dump+8s");
        EGDiag(@"[自动 dump·8s] 底栏取证：\n%@", EGTabBarForensics());
    });
#endif

#if ENABLE_CLASS_SCAN
    EGAfterOnMain(6.0, ^{
        EGStageSet("类名扫描");
        EGJournal("class-scan");
        EGDiag(@"[类名扫描] 广告相关：\n%@", EGScanClassNames(EG_SCAN_KEYWORDS_AD, 60));
        EGDiag(@"[类名扫描] 「我的」页相关：\n%@", EGScanClassNames(EG_SCAN_KEYWORDS_MINE, 60));
    });
#endif

    // ★ v0.2 规则巡检：见 EGWatchMinePage 上方那段（钩子与巡检验互为兜底）。
    //   前 5 秒每 1 秒一次（覆盖启动期），之后每 5 秒一次，达成目标即自停。
    if (!gEGGuardTripped) {
        static dispatch_source_t sWatchTimer = NULL;
        EGAfterOnMain(2.0, ^{
            EGWatchMinePage();
            EGAfterOnMain(1.0, ^{ EGWatchMinePage(); });
            EGAfterOnMain(2.0, ^{ EGWatchMinePage(); });
            EGAfterOnMain(3.5, ^{ EGWatchMinePage(); });
        });
        if (!sWatchTimer) {
            dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                         dispatch_get_main_queue());
            if (t) {
                dispatch_source_set_timer(t,
                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                    (uint64_t)(5.0 * NSEC_PER_SEC), (uint64_t)(0.5 * NSEC_PER_SEC));
                dispatch_source_set_event_handler(t, ^{ EGWatchMinePage(); });
                sWatchTimer = t;
                dispatch_resume(t);
            }
        }
    }

    EGJournal("timers-armed");

#if EG_JOURNAL_MIRROR
    // 上一次启动没走完 → 大概率崩过 → 把流水镜像到系统剪贴板。
    // 这是崩溃后唯一不需要文件系统就能取证的通道：App 崩了悬浮球也没了，
    // 而剪贴板跨进程存活，直接粘贴即可。
    if (lastUnclean) {
        NSString *jt = EGJournalTail(4000);
        if (jt.length) {
            EGSetClipboard([NSString stringWithFormat:
                @"【%@ 上次启动未正常结束，以下是启动流水】\n%@", @EG_TAG, jt]);
            EGDiag(@"[流水镜像] 上次启动未确认结束 → 已把流水写入剪贴板（%lu 字符）",
                   (unsigned long)jt.length);
        }
    }
#endif

    // 启动确认完成 -> 自愈计数归零
    EGAfterOnMain(12.0, ^{
        EGLaunchGuardClear();
        EGJournal("confirmed");
        EGDiag(@"[自愈] 启动确认完成，计数已归零");
    });
}

// ============================== 入口 ==============================
//
// ★★ v0.1.1 的关键改动：%ctor 里**只留一次 dispatch_async**，别的什么都不做。
//
// 依据 = 2026-09-30 23:21:29 真机 .ips（Shawn 提供，e高速 5.10.7 / iOS 16.6.1）：
//   exception  EXC_CRASH / SIGBUS（Bus error: 10）
//   启动→崩溃  0.18 秒
//   栈        #0 e高速 +0x51f21e8
//             #1 e高速 +0x59c1d40
//             #2 load_images                        [libobjc.A.dylib]
//             #3 dyld4::RuntimeState::notifyObjCInit
//             #4 dyld4::Loader::runInitializersBottomUp
//             ...
//             #8 dyld4::APIs::runAllInitializersForMain
//   —— 即**某个 image 的 +load 正在执行时**崩的。
//
// 归属判定（这一条必须说清楚，不能含糊）：
//   我们 dylib 的 imageIndex=43、base=0x111ef0000、size=0x18000；
//   而崩溃帧 #0/#1 的 imageIndex=0 = **主二进制 e高速**
//   （base=0x104588000、size=0x7c70000，偏移 0x51f21e8 确实落在其范围内）。
//   → **栈上没有任何一帧属于我们的 dylib。**
//
// 但"不在栈上" ≠ "无责任"。v0.1 的 %ctor 在 **dyld 初始化阶段**做了三件有副作用的事：
//   ① 调 Foundation（NSSearchPathForDirectoriesInDomains）—— 在别人的初始化链里触发 lazy init
//   ② 用 sigaction 覆盖宿主 6 个信号处理器 + sigaltstack 覆盖备用信号栈
//   ③ 文件 IO（读 / 写 Caches 下的启动计数文件）
// 这些全都发生在**宿主自己的初始化过程之中**。宿主若在 +load 里用信号做自检 / 反调试 /
// 崩溃收集（国产 App 常见），我们的覆盖会把它的"自检"变成"真崩溃"，而崩溃点自然落在
// 它的代码上 —— 与这份 .ips 的形状完全吻合。
//
// dyld 阶段是**别人的地盘**。我们唯一该做的是尽快让开：
// 把 Foundation 调用、文件 IO、信号处理器全部推迟到主队列（runloop 已起来）执行。
//
// 代价（如实记录）：如果在主队列块执行之前宿主就崩了，我们的崩溃取证抓不到那一次。
// 但那种情况下系统 .ips 本来就有完整记录 —— 本次这个崩溃正是靠 .ips 定位的，
// 不是靠我们的取证，所以不算净损失。
//
// 另：日志顺序改为"先 EGEnsureStarted，再由它自己初始化崩溃日志路径"，
// 因为 EGInitCrashLogPath 要调 Foundation。
//
// ---------------------------------------------------------------------------
// ★ v0.1.2：23:39:19 的**第二份** .ips —— v0.1.1 仍然崩，但形状完全不同
// ---------------------------------------------------------------------------
//   exception  EXC_BAD_ACCESS / SIGBUS，subtype UNKNOWN_0x101 at 0xf7
//   启动→崩溃  0.48 秒（v0.1 那次是 0.18 秒）
//   触发线程  thread 1 = **com.apple.root.default-qos**（全局并发队列），不是主线程
//   帧        **只有 1 帧**：imageOffset=247、imageIndex=54
//             —— 而 usedImages[54] 是全零条目（base=0 size=0 uuid=0000…），
//             即 pc=0xf7 **不属于任何已加载镜像**
//   寄存器    pc = lr = fp = **0xf7**（同一个值，且未对齐）
//             x1 = SEL "release"
//             x17 = -[__NSCFConstantString release]
//             x2/x14/x15/x16 = __CFConstantStringClassReference
//   另有 thread 2：dyld3::MachOLoaded::findClosestSymbol ← dyld4::APIs::dladdr
//             ← JMCodeProtectKit ×3 ← _dispatch_call_block_and_release
//             ← _dispatch_root_queue_drain
//
// 这份报告的判读（事实 / 推断分开写）：
//   事实 1：崩溃线程是**全局并发队列**上的一条，而我们的代码**只跑主队列**。
//   事实 2：崩溃线程只有一帧，且那一帧**落在任何镜像之外**（全零 image 条目）。
//   事实 3：pc / lr / fp 三个寄存器是**同一个未对齐值 0xf7** —— 真实的指令地址不可能未对齐。
//          正常的内存访问越界会给出一个**指向我们代码的、合法的 pc** 和一条可读的栈。
//          三个寄存器同时被写成同一个垃圾值，说明**线程上下文本身是坏的**
//          （内存被破坏，或被主动覆写），不是"简单的野指针解引用"。
//   推断：第三方加固 SDK `JMCodeProtectKit` 在启动 0.48 秒时正在后台队列上走
//          `dladdr` 遍历镜像列表做符号化 —— 这是一个**完整性校验 / 反注入扫描**的典型形状。
//
//   ★ 结论（这一条必须说清楚）：**没有任何证据表明这次崩溃由我们的代码引起。**
//     但也没有证据**排除**"我们的镜像被加载"是触发条件 —— 两者是不同的问题。
//     这正是 v0.1.2 做成四个变体台阶的原因：一次问完，不再一轮一轮猜。
//     详见配置区「构建变体」那一节。
%ctor {
#if EG_MINIMAL_CTOR
    // ===== 台阶 1「minimal」：完全空的构造函数 =====
    // 连 NSLog 都不调 —— NSLog 本身会碰 CF/Foundation，那已经算"做了事"。
    // 这一版只回答一个问题：**"我们的镜像被 dyld 加载"这件事本身**，
    // 是否足以让宿主崩溃（反注入 / 完整性校验）。
    // 判读：这一版还崩、而不注入 dylib 不崩 → 宿主在检测外来镜像。
#else
#if EG_JOURNAL_IN_CTOR
    // 只有 dispatchonly 变体打开（见 EG_JOURNAL_IN_CTOR 的说明）。
    // 纯 POSIX 三个 syscall，用来确认"我们的构造函数到底跑了没有"。
    EGJournal("ctor");
#endif
    dispatch_async(dispatch_get_main_queue(), ^{
#if EG_VARIANT_DISPATCHONLY
        // ===== 台阶 2「dispatchonly」：%ctor 里只碰一次 libdispatch，块里什么都不做 =====
        // 这一版只回答一个问题：**在 %ctor 里调用 dispatch_async 本身**是否安全
        // （libdispatch 在 constructor 阶段的初始化顺序是个真实风险点）。
        EGJournal("main-block");
#else
        EGEnsureStarted();
#endif
    });
#endif
}
