ARCHS = armv7
TARGET = iphone:clang:6.1:6.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UsageGuard
UsageGuard_FILES = Tweak.x src/UGGuardCore.c src/UGPrefs.m src/UGOverlayWindow.m src/UGParentPanel.m src/UGRuntime.m
UsageGuard_CFLAGS = -fobjc-arc
UsageGuard_FRAMEWORKS = UIKit Foundation Security CoreTelephony CoreGraphics QuartzCore

include $(THEOS)/makefiles/tweak.mk

# Settings pane (Library/PreferenceBundles/UsageGuardPrefs.bundle). Its sources
# and its PreferenceLoader entry plist (layout/) are staged into the same deb.
SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
