# Companion app for Usage Guard, built as an aggregate subproject so the same
# deb carries the tweak, the settings bundle and this configuration host.
#
# The app is a second host for the very same UGPreferencesController the
# PreferenceLoader pane uses; it exists because the pane cannot be opened on the
# device. It is installed into /Applications (the Theos `application` target
# default) so it runs unsandboxed on iOS 6 and can reach the tweak's preferences
# file and notify(3) names, just like the pane does inside Preferences.app.
#
# TARGET and ARCHS are repeated here because makefile-scoped variables are not
# exported to sub-makes; a command-line TARGET=/ARCHS= (as CI passes) overrides
# these defaults.
TARGET ?= iphone:clang:6.1:6.0
ARCHS ?= armv7

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = UsageGuard
UsageGuard_FILES = main.m UGAppDelegate.m ../prefs/UGPreferencesController.m ../prefs/UGSettingsIPC.m ../prefs/UGTrace.m ../src/UGPrefs.m ../src/UGGuardCore.c
UsageGuard_INSTALL_PATH = /Applications
UsageGuard_CFLAGS = -fobjc-arc -I../src -I../prefs -DUG_HOST_APP=1
UsageGuard_FRAMEWORKS = UIKit Foundation Security
UsageGuard_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/application.mk
