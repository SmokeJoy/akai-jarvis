LOCAL_PATH := $(call my-dir)

include $(CLEAR_VARS)
LOCAL_MODULE := akai_uinput
LOCAL_SRC_FILES := uinput_jni.c
LOCAL_LDLIBS := -llog
include $(BUILD_SHARED_LIBRARY)
