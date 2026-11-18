# Preference bundle for Usage Guard, built as an aggregate subproject so one
# `make package` produces a single deb with the tweak, its filter plist and the
# settings pane.
#
# TARGET and ARCHS are repeated here because makefile-scoped variables are not
# exported to sub-makes; a command-line TARGET=/ARCHS= (as CI passes) overrides
# these defaults.
TARGET ?= iphone:clang:6.1:6.0
ARCHS ?= armv7

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = UsageGuardPrefs
UsageGuardPrefs_FILES = UGPreferencesController.m UGSettingsIPC.m ../src/UGPrefs.m ../src/UGGuardCore.c
UsageGuardPrefs_INSTALL_PATH = /Library/PreferenceBundles
UsageGuardPrefs_CFLAGS = -fobjc-arc -I../src
UsageGuardPrefs_FRAMEWORKS = UIKit Foundation Security
UsageGuardPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
