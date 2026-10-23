include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LiquidAssBackboardd

LiquidAssBackboardd_FILES     = $(wildcard *.mm)
LG_CA_CLOSED_PROFILE ?= 0
LiquidAssBackboardd_CFLAGS    = -fobjc-arc -std=c++17 -fno-objc-arc-exceptions -DLG_CA_CLOSED_PROFILE_COMPILED=$(LG_CA_CLOSED_PROFILE)
LiquidAssBackboardd_FRAMEWORKS = Metal QuartzCore CoreFoundation
ifeq ($(LG_CA_CLOSED_PROFILE),1)
LiquidAssBackboardd_FRAMEWORKS += IOSurface
endif
LiquidAssBackboardd_LDFLAGS   = -lc++
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
LiquidAssBackboardd_LIBRARIES += roothide
endif

include $(THEOS_MAKE_PATH)/tweak.mk
