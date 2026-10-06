TARGET := macosx:clang:latest:13.0
ARCHS = arm64

include ../config/production.mk
include $(THEOS)/makefiles/common.mk

# Avoid mixing Theos's legacy vendor IOKit types with the macOS SDK's AppKit
# dependency graph (IOPhysicalRange differs between those two headers).
_THEOS_INTERNAL_IFLAGS_BASE = -I$(THEOS_TARGET_INCLUDE_PATH) \
	-I$(THEOS_INCLUDE_PATH) -I$(THEOS_FALLBACK_INCLUDE_PATH)

TOOL_NAME = macwsworkspacectl

macwsworkspacectl_FILES = main.m
# The synchronous LaunchServices call and Carbon PSN activation/reopen route
# are deliberate compatibility contracts for short-lived and direct-chroot
# applications. Newer SDKs deprecate them but their replacements do not expose
# the same synchronous PID/PSN semantics used here.
macwsworkspacectl_CFLAGS = -fobjc-arc -Wall -Wextra \
	-Wno-deprecated-declarations
macwsworkspacectl_FRAMEWORKS = AppKit ApplicationServices Foundation QuickLookThumbnailing
macwsworkspacectl_CODESIGN_FLAGS = -S../layout/usr/macOS/bin/entitlements.plist
macwsworkspacectl_INSTALL_PATH = /usr/macOS/bin

include $(THEOS_MAKE_PATH)/tool.mk
