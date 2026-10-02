ARCHS = arm64
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = GlowNavDiagnostics
GlowNavDiagnostics_FILES = Tweak.mm
GlowNavDiagnostics_CFLAGS = -fobjc-arc
GlowNavDiagnostics_FRAMEWORKS = UIKit QuartzCore

include $(THEOS_MAKE_PATH)/library.mk
