# The on-device lld emits arm64e Objective-C metadata that traps in
# libobjc readClass() before main (runtime-confirmed on iPad13,6 / iOS 16.3.1).
# An arm64 application runs natively on this arm64e CPU and avoids that broken
# fixup ABI; do not paper over it with the libobjc autda diagnostic patch.
ARCHS = arm64
TARGET = iphone:clang:latest:16.0
INSTALL_TARGET_PROCESSES = MacWSHost

include ../config/production.mk
include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = MacWSHost

MacWSHost_FILES = main.m MacWSControlClient.m MacWSStreamClient.m \
	MacWSPerformanceMonitor.m \
	Testing/MacWSPerformanceGestureScenario.m \
	Testing/MacWSCatalystDrawableProbe.m \
	Input/MacWSKeyMapping.m \
	Support/MacWSHostDiagnostics.m \
	Support/MacWSHostRuntime.m \
	Rendering/MacWSMetalView.m \
	Transport/MacWSCatalystDrawableReceiver.m \
	Rendering/MacWSCatalystDrawableCompositor.m \
	Launch/MacWSCatalystLaunchCoordinator.m \
	Compatibility/MacWSMappedFrame.m \
	MacWSMenuClient.m \
	MacWSInteropClient.m ../misc/iosclear_ref.m
MacWSHost_FRAMEWORKS = UIKit Metal MetalKit QuartzCore CoreGraphics Foundation \
	AVFoundation ImageIO IOKit IOSurface UniformTypeIdentifiers GameController
MacWSHost_LIBRARIES = bsm
MacWSHost_CFLAGS = -fobjc-arc -Wall -Wextra -I$(CURDIR)/../include \
	-I$(CURDIR) -I$(CURDIR)/Support -I$(CURDIR)/Testing -I$(CURDIR)/Transport \
	-I$(CURDIR)/Input -I$(CURDIR)/Rendering -I$(CURDIR)/Launch \
	-I$(CURDIR)/Compatibility \
	-isystem $(CURDIR)/../vendor/ios-xpc -DIOSCLEAR_LIBRARY_MODE=1
MacWSHost_CODESIGN_FLAGS = -Sentitlements.plist
MacWSHost_RESOURCE_FILES = Resources/AppIcon.png

# Procursus currently pairs clang 16 with LLD 14.  That linker does not
# resolve the iOS 16.5 TBD-v4 objc-classes/objc-ivars entries used by the Host
# (runtime build witness: UIButtonConfiguration and
# UIWindowSceneActivationRequestOptions remained undefined even though both
# are present in the selected UIKit.tbd).  Prefer the installed Apple
# ld-classic on-device when that exact capability exists.  This is deliberately
# scoped to the arm64 Host: the SpringBoard tweak still comes only from the
# separately manifested Mac Apple-ld64 cross-build.
ifneq ($(wildcard /var/jb/usr/bin/ld64),)
MacWSHost_LDFLAGS += -fuse-ld=/var/jb/usr/bin/ld64
endif

include $(THEOS_MAKE_PATH)/application.mk
