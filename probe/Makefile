# Same target/arch as the real tweak: armv7, iOS 6.1 SDK, 6.0 deployment target.
# Rootful layout (THEOS_PACKAGE_SCHEME intentionally unset).
TARGET = iphone:clang:6.1:6.0
ARCHS = armv7

INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = UsageGuardProbe
UsageGuardProbe_FILES = Tweak.x
UsageGuardProbe_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
