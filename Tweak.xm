// ============================================================================
// Tweak.xm — e高速 (com.sdhs.easy.high.road) 界面精简 Tweak
// v0.1-probe —— **纯探针：只取证，不改任何界面行为**
// ============================================================================
//
// 目标（Shawn 提出，2026-09-30）：
//   1) 底栏 5 个 tab（首页 / 车主服务 / 会员服务 / 商城 / 我的）→ **只保留「我的」**；
//   2) 「我的」页中，「我的订单」与「我的服务」之间的**图片广告**
//      （「移动积分兑高速通行券」横幅）一并去掉。
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
//     · **长按**   = 完整诊断（含启动期自动 dump、崩溃日志回读、类名扫描）→ 写入剪贴板
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
//   · %ctor 只做三件事：算崩溃日志路径、装崩溃处理器、把其余全部 dispatch 到主队列。
//     诊断钩子绝不放在启动路径上 —— 一次"在 dyld 阶段全进程扫类"曾把目标 App
//     打到**完全打不开**（且 @try/@catch 救不了：异常在 dispatch_once 里被 libdispatch
//     边界吞成 std::terminate）。
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

// 不依赖 substrate / ellekit 头文件：直接用 Objective-C runtime 替换方法实现。
// TrollFools 注入的进程内同样可用，同时消掉一类"头文件找不到"的构建失败。

// ============================== 配置 ==============================

#define EG_TAG              "EGaosuTidy"
#define EG_VERSION          "0.1.1-probe"
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

// 类名扫描关键词（只用来**报告**，不用来改行为）
#define EG_SCAN_KEYWORDS_TAB   @[@"TabBar", @"Tabbar", @"TabItem", @"TabButton", @"TabView", @"TabController", @"BottomBar", @"MainTab"]
#define EG_SCAN_KEYWORDS_AD    @[@"Banner", @"Advert", @"AdView", @"Promot", @"Popup", @"Splash", @"Market", @"Operat"]
#define EG_SCAN_KEYWORDS_MINE  @[@"Mine", @"MyCenter", @"Personal", @"UserCenter", @"Member", @"Profile"]

// ============================== 全局（全部前置，避免"先用后定义"） ==============================

static char gEGCrashLogPath[512] = {0};
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
static NSString *EGTextOfView(UIView *v);
static NSString *EGNodeTagOf(UIView *v);
static NSString *EGDescribeNode(UIView *v, NSString *indent);
static void EGWalkNode(UIView *v, NSUInteger depth, NSUInteger maxDepth,
                       NSUInteger *budget, NSMutableString *s);
static NSString *EGDumpViewTree(UIView *root, NSUInteger maxDepth, NSUInteger maxNodes);
static NSString *EGBannerCandidates(UIView *root);
static NSString *EGTextIndex(UIView *root);

static void EGCollectTabBarControllers(UIViewController *vc, NSMutableArray *out, NSUInteger depth);
static NSArray *EGFindTabBarControllers(void);
static NSString *EGDescribeVCArray(NSArray *arr);
static NSString *EGDescribeTabBar(UITabBar *tb);
static NSString *EGDescribeTabBarController(UITabBarController *tbc);
static NSString *EGTabBarForensics(void);
static NSString *EGScanTabBarLikeClasses(void);

static BOOL EGClassNameMatchesAny(NSString *n, NSArray<NSString *> *kws);
static NSString *EGScanClassNames(NSArray<NSString *> *keywords, NSUInteger maxOut);

static void EGSetClipboard(NSString *text);
static void EGFlashButton(NSString *text);
static void EGInstallOverlay(void);

static void EGViewDidAppearHook(id self, SEL _cmd, BOOL animated);
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
                [out appendString:@"  (还没记录到任何 VC —— hook 可能尚未生效)\n"];
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
        [out appendFormat:@"版本 = %@   构建令牌 = %s\n", @EG_VERSION, EGBuildToken()];
        [out appendFormat:@"阶段 = %s\n", EGStageText()];

        [out appendString:@"\n===== 上次崩溃回读 =====\n"];
        EGReadBackCrashLog();
        [out appendFormat:@"%@\n", gEGCrashReport.length ? gEGCrashReport : @"(无崩溃记录)\n"];

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

// ============================== 启动 ==============================

static void EGEnsureStarted(void) {
    if (gEGStarted) return;
    gEGStarted = YES;

    // ---- 以下三件事在 v0.1 里是 %ctor（dyld 阶段）做的，v0.1.1 全部挪到这里 ----
    // 现在跑在主队列上：runloop 已起来，Foundation / 文件系统 / 信号都安全，
    // 而且宿主自己的 +load 已经跑完了 —— 完整依据见 %ctor 上方那段。
    EGInitCrashLogPath();
#if ENABLE_CRASH_HANDLERS
    EGInstallCrashHandlers();
#else
    // 不装：避免在宿主的初始化链里覆盖它自己的信号处理器（见配置区的说明）
#endif
    int guardCount = EGLaunchGuardCheck();
    if (guardCount != 0) gEGGuardTripped = YES;

    EGStageSet("启动完成");
    EGDiag(@"[启动] %@ %@ 已加载（bundle=%s）", @EG_TAG, @EG_VERSION, EG_BUNDLE_ID);
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
        EGInstallViewDidAppearHook();
    }

#if ENABLE_FLOAT_BUTTON
    EGInstallOverlay();
#endif

    // 启动后自动 dump 一次底栏 —— 用户没点按钮也能拿到数据
#if ENABLE_AUTO_DUMP
    EGAfterOnMain(3.0, ^{
        EGStageSet("自动 dump 底栏 +3s");
        EGDiag(@"[自动 dump·3s] 底栏取证：\n%@", EGTabBarForensics());
        EGDiag(@"[自动 dump·3s] 自绘底栏候选：\n%@", EGScanTabBarLikeClasses());
    });
    EGAfterOnMain(8.0, ^{
        EGStageSet("自动 dump 底栏 +8s");
        EGDiag(@"[自动 dump·8s] 底栏取证：\n%@", EGTabBarForensics());
    });
#endif

#if ENABLE_CLASS_SCAN
    EGAfterOnMain(6.0, ^{
        EGStageSet("类名扫描");
        EGDiag(@"[类名扫描] 广告相关：\n%@", EGScanClassNames(EG_SCAN_KEYWORDS_AD, 60));
        EGDiag(@"[类名扫描] 「我的」页相关：\n%@", EGScanClassNames(EG_SCAN_KEYWORDS_MINE, 60));
    });
#endif

    // 启动确认完成 -> 自愈计数归零
    EGAfterOnMain(12.0, ^{
        EGLaunchGuardClear();
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
%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
#if EG_MINIMAL_CTOR
        // 最小验证模式（对照实验）：本次启动什么都不做 —— 见 EG_MINIMAL_CTOR 的说明
        NSLog(@"[%@] minimal ctor —— 本次启动不做任何事", @EG_TAG);
#else
        EGEnsureStarted();
#endif
    });
}
