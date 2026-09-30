TARGET := iphone:clang:latest:16.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TOOL_NAME = SceneOcclusionProbe
SceneOcclusionProbe_FILES = ../scene_occlusion_introspect.m
SceneOcclusionProbe_CFLAGS = -fobjc-arc
SceneOcclusionProbe_FRAMEWORKS = Foundation UIKit
SceneOcclusionProbe_CODESIGN_FLAGS = -S../../entitlements.plist

include $(THEOS_MAKE_PATH)/tool.mk
