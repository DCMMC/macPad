TARGET := iphone:clang:latest:14.0
ARCHS = arm64
include ../config/production.mk
include $(THEOS)/makefiles/common.mk

TOOL_NAME = mountdevfs

mountdevfs_FILES = main.c
# Use the same narrow identity as the Dopamine-compatible bindfs helper. The
# helper's mount authority itself comes from main.c's bounded libjailbreak
# credential transaction; never sign it with the broad macOS-process profile.
mountdevfs_CODESIGN_FLAGS = -Sentitlements.plist
mountdevfs_INSTALL_PATH = /usr/macOS/bin

include $(THEOS_MAKE_PATH)/tool.mk
