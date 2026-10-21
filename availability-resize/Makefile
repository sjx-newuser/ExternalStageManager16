ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.1
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ExternalStageManager16
ExternalStageManager16_FILES = Tweak.xm
ExternalStageManager16_CFLAGS = -fobjc-arc -Wall -Wextra
ExternalStageManager16_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
