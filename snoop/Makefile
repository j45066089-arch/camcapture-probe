ARCHS := arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TOOL_NAME = ccpsnoop
ccpsnoop_FILES = ccpsnoop.m
ccpsnoop_CODESIGN_FLAGS = -S

include $(THEOS_MAKE_PATH)/tool.mk