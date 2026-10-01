ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GlowCompat
GlowCompat_FILES = Tweak.mm
GlowCompat_CFLAGS = -fobjc-arc
GlowCompat_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/library.mk
