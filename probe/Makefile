ARCHS := arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CamCaptureProbe

CamCaptureProbe_FILES = Tweak.x
CamCaptureProbe_CFLAGS = -fobjc-arc
CamCaptureProbe_LDFLAGS = -lobjc

include $(THEOS_MAKE_PATH)/tweak.mk
