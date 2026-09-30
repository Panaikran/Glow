ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GlowNavDiagnostics
GlowNavDiagnostics_FILES = Tweak.xm
GlowNavDiagnostics_CFLAGS = -fobjc-arc
GlowNavDiagnostics_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
