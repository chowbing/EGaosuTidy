TARGET := iphone:clang:latest:14.0
ARCHS := arm64
TWEAK_NAME := EGaosuTidy

# ---------------------------------------------------------------------------
# ★ GO_EASY_ON_ME=1 —— 必须放在 include common.mk **之前**，否则不生效
# ---------------------------------------------------------------------------
# Theos 的 makefiles/common.mk 里有这么一段（2026-09-30 从上游源码核实）：
#
#     ifneq ($(GO_EASY_ON_ME),$(_THEOS_TRUE))
#         _THEOS_INTERNAL_LOGOSFLAGS += -c warnings=error
#         _THEOS_INTERNAL_CFLAGS += -Werror
#     endif
#
# 也就是说 -Werror 是 Theos 自己加的，而它加在**内部 CFLAGS** 里 ——
# 我们自己 CFLAGS 里的 -Wno-error 能不能压住它，取决于两者的先后顺序，
# 而那个顺序不写在项目文件里、随 Theos 版本可能变。**靠顺序赢是运气，不是设计。**
# 官方给的开关就是 GO_EASY_ON_ME=1：一行把 -Werror 和 logos 的 warnings=error 都关掉。
# 本机没有 macOS，每次验证都要走一轮 Actions，代价大，所以不留这种不确定性。
#
# 注意：**真正的 error（未声明函数、类型不匹配、语法错）照样会失败**，这个开关救不了。
GO_EASY_ON_ME := 1

EGaosuTidy_FILES := Tweak.xm

# ---------------------------------------------------------------------------
# 构建变体（EG_VARIANT）
# ---------------------------------------------------------------------------
# 一轮 CI 出 4 个 dylib，把「是不是我们的代码引起的」拆成互不重叠的台阶。
# 真机上按顺序注入，**第一个开始崩的台阶就是嫌疑层**。详见 Tweak.xm 配置区的说明。
#
#   minimal      %ctor 完全为空（连 NSLog 都不调）—— 测「镜像被 dyld 加载」本身
#   dispatchonly %ctor 只写一行流水 + 一次 dispatch_async，块里什么都不做
#   nofloat      完整启动流程，但不装悬浮球
#   normal       完整探针（默认，正式取数用）
#
# 用法：make EG_VARIANT=minimal
EG_VARIANT ?= normal

# -Wno-unused-function：变体机制的副作用 —— 关掉某个开关后，被它保护的整段函数
#   就成了"未使用"。例如 minimal / dispatchonly 变体下 EGEnsureStarted 不会被调用，
#   nofloat 变体下 EGInstallOverlay 不会被调用。这是**设计使然**，不是代码缺陷。
EG_COMMON_CFLAGS := -fobjc-arc -Wno-error -Wno-unused-function -Wno-unused-variable

ifeq ($(EG_VARIANT),minimal)
  EG_VARIANT_CFLAGS := -DEG_VARIANT_MINIMAL=1
else ifeq ($(EG_VARIANT),dispatchonly)
  EG_VARIANT_CFLAGS := -DEG_VARIANT_DISPATCHONLY=1
else ifeq ($(EG_VARIANT),nofloat)
  EG_VARIANT_CFLAGS := -DEG_VARIANT_NOFLOAT=1
else ifeq ($(EG_VARIANT),normal)
  EG_VARIANT_CFLAGS :=
else
  $(error 未知的 EG_VARIANT="$(EG_VARIANT)"，可选值：normal | minimal | dispatchonly | nofloat)
endif

EGaosuTidy_CFLAGS := $(EG_COMMON_CFLAGS) $(EG_VARIANT_CFLAGS)

EGaosuTidy_LDFLAGS := -framework UIKit -framework Foundation -framework QuartzCore

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk

# 走 TrollFools 注入，不需要 make install；这条留着只是为了将来真机 ssh 安装方便。
# after-install::
# 	install.exec "killall -9 EGaosu" || true
