TARGET = iphone:clang:latest:15.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DudeTheftWarsMod

DudeTheftWarsMod_FILES = Tweak.xm
DudeTheftWarsMod_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
DudeTheftWarsMod_CFLAGS = -fobjc-arc -Wno-error -Wno-unused-variable -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk
