ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DudeHack

DudeHack_FILES = Tweak.mm
DudeHack_FRAMEWORKS = Foundation UIKit QuartzCore
DudeHack_CFLAGS = -fobjc-arc -Wno-error=deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
