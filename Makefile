ARCHS = armv7
TARGET = iphone:clang:6.1:6.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UsageGuard
UsageGuard_FILES = Tweak.xm src/UGGuardCore.c src/UGPrefs.m src/UGOverlayWindow.m src/UGParentPanel.m src/UGRuntime.m
UsageGuard_CFLAGS = -fobjc-arc
UsageGuard_FRAMEWORKS = UIKit Foundation Security CoreTelephony

include $(THEOS)/makefiles/tweak.mk
