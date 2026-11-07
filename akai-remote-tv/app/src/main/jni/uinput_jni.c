#include <jni.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <android/log.h>

#define TAG "AKAI_UINPUT_JNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static const int SUPPORTED_KEYS[] = {
    KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_ENTER,
    KEY_BACK, KEY_HOMEPAGE, KEY_MENU,
    KEY_VOLUMEUP, KEY_VOLUMEDOWN, KEY_MUTE,
    KEY_POWER, KEY_SLEEP,
    KEY_0, KEY_1, KEY_2, KEY_3, KEY_4,
    KEY_5, KEY_6, KEY_7, KEY_8, KEY_9,
    KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G,
    KEY_H, KEY_I, KEY_J, KEY_K, KEY_L, KEY_M, KEY_N,
    KEY_O, KEY_P, KEY_Q, KEY_R, KEY_S, KEY_T, KEY_U,
    KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z,
    KEY_SPACE, KEY_BACKSPACE, KEY_DOT, KEY_MINUS, KEY_SLASH
};

JNIEXPORT jint JNICALL
Java_it_akai_customremote_UInputDriver_nativeInit(JNIEnv *env, jobject thiz) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        LOGE("Failed to open /dev/uinput: %s (errno %d)", strerror(errno), errno);
        return -1;
    }

    // Enable key event types
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_SYN) < 0) {
        LOGE("Failed to set event bits on /dev/uinput: %s", strerror(errno));
        close(fd);
        return -1;
    }

    // Register all supported remote keycodes
    int num_keys = sizeof(SUPPORTED_KEYS) / sizeof(SUPPORTED_KEYS[0]);
    for (int i = 0; i < num_keys; i++) {
        if (ioctl(fd, UI_SET_KEYBIT, SUPPORTED_KEYS[i]) < 0) {
            LOGE("Failed to enable keybit %d: %s", SUPPORTED_KEYS[i], strerror(errno));
        }
    }

    // Configure uinput virtual device
    struct uinput_user_dev uidev;
    memset(&uidev, 0, sizeof(uidev));
    snprintf(uidev.name, UINPUT_MAX_NAME_SIZE, "AKAI Custom Virtual Remote");
    uidev.id.bustype = BUS_VIRTUAL;
    uidev.id.vendor  = 0x1856; // Akai custom vendor ID
    uidev.id.product = 0x5037; // 5037 model ID
    uidev.id.version = 1;

    if (write(fd, &uidev, sizeof(uidev)) < 0) {
        LOGE("Failed to write uinput_user_dev: %s", strerror(errno));
        close(fd);
        return -1;
    }

    if (ioctl(fd, UI_DEV_CREATE) < 0) {
        LOGE("Failed to create uinput device: %s", strerror(errno));
        close(fd);
        return -1;
    }

    LOGI("AKAI Custom Virtual Remote device created successfully! (fd: %d)", fd);
    return fd;
}

static int emit(int fd, int type, int code, int val) {
    struct input_event ie;
    memset(&ie, 0, sizeof(ie));
    ie.type = type;
    ie.code = code;
    ie.value = val;
    return write(fd, &ie, sizeof(ie));
}

JNIEXPORT jboolean JNICALL
Java_it_akai_customremote_UInputDriver_nativeSendKey(JNIEnv *env, jobject thiz, jint fd, jint linux_keycode) {
    if (fd < 0) return JNI_FALSE;

    // Key Press
    if (emit(fd, EV_KEY, linux_keycode, 1) < 0 ||
        emit(fd, EV_SYN, SYN_REPORT, 0) < 0) {
        LOGE("Failed to send key press %d: %s", linux_keycode, strerror(errno));
        return JNI_FALSE;
    }

    // 25ms tactile delay
    usleep(25000);

    // Key Release
    if (emit(fd, EV_KEY, linux_keycode, 0) < 0 ||
        emit(fd, EV_SYN, SYN_REPORT, 0) < 0) {
        LOGE("Failed to send key release %d: %s", linux_keycode, strerror(errno));
        return JNI_FALSE;
    }

    return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_it_akai_customremote_UInputDriver_nativeClose(JNIEnv *env, jobject thiz, jint fd) {
    if (fd >= 0) {
        ioctl(fd, UI_DEV_DESTROY);
        close(fd);
        LOGI("AKAI Custom Virtual Remote device destroyed and closed.");
    }
}
