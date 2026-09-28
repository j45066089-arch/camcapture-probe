ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CamCaptureProbe

CamCaptureProbe_FILES = Tweak.m
CamCaptureProbe_CFLAGS = -fobjc-arc -fobjc-arc-exceptions
CamCaptureProbe_LDFLAGS = -lobjc -Wl,-u,_ccp_init

include $(THEOS_MAKE_PATH)/tweak.mk
