TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES := TikTok

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TikTokBro
TikTokBro_FILES = Tweak/Tweak.xm
TikTokBro_CFLAGS = -fobjc-arc
TikTokBro_FRAMEWORKS = UIKit AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
