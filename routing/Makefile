ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.1
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

# Separate payloads keep UIKit out of backboardd. No install/restart target.
TWEAK_NAME = ESMSceneRouting ESMBackboardRouting
ESMSceneRouting_FILES = SceneEntry.mm SceneMenuRouting.mm SidebarScope.mm
ESMSceneRouting_FRAMEWORKS = Foundation UIKit
ESMSceneRouting_EXTRA_FRAMEWORKS = CydiaSubstrate
ESMSceneRouting_CFLAGS = -fobjc-arc -Wall -Wextra -Werror -fmodules-cache-path=$(THEOS_PROJECT_DIR)/.clang-module-cache
ESMSceneRouting_CCFLAGS = -std=c++17
ESMBackboardRouting_FILES = BackboardEntry.mm BackboardRouting.mm
ESMBackboardRouting_FRAMEWORKS = Foundation CoreGraphics
ESMBackboardRouting_CFLAGS = -fobjc-arc -Wall -Wextra -Werror -fmodules-cache-path=$(THEOS_PROJECT_DIR)/.clang-module-cache
ESMBackboardRouting_CCFLAGS = -std=c++17

include $(THEOS_MAKE_PATH)/tweak.mk
