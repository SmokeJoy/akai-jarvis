package it.akai.customremote;

import android.util.Log;

public class UInputDriver {
    private static final String TAG = "UInputDriver";
    private int fd = -1;
    private boolean isAvailable = false;

    // Linux input keycodes from <linux/input.h>
    public static final int KEY_UP = 103;
    public static final int KEY_DOWN = 108;
    public static final int KEY_LEFT = 105;
    public static final int KEY_RIGHT = 106;
    public static final int KEY_ENTER = 28;
    public static final int KEY_BACK = 158;
    public static final int KEY_HOMEPAGE = 172;
    public static final int KEY_MENU = 139;
    public static final int KEY_VOLUMEUP = 115;
    public static final int KEY_VOLUMEDOWN = 114;
    public static final int KEY_MUTE = 113;
    public static final int KEY_POWER = 116;
    public static final int KEY_SLEEP = 142;
    public static final int KEY_CHANNELUP = 402;
    public static final int KEY_CHANNELDOWN = 403;
    public static final int KEY_LAST = 405; // Linux KEY_LAST (405): Recall Last Channel (Android KEYCODE_LAST_CHANNEL 229)
    public static final int KEY_PREVIOUS_CHANNEL = KEY_LAST; // Backward compatibility alias
    public static final int KEY_0 = 11;
    public static final int KEY_1 = 2;
    public static final int KEY_2 = 3;
    public static final int KEY_3 = 4;
    public static final int KEY_4 = 5;
    public static final int KEY_5 = 6;
    public static final int KEY_6 = 7;
    public static final int KEY_7 = 8;
    public static final int KEY_8 = 9;
    public static final int KEY_9 = 10;

    // Alphanumeric keys from <linux/input.h>
    public static final int KEY_SPACE = 57;
    public static final int KEY_BACKSPACE = 14;
    public static final int KEY_DOT = 52;
    public static final int KEY_MINUS = 12;
    public static final int KEY_SLASH = 53;

    private static boolean libraryLoaded = false;

    static {
        try {
            System.loadLibrary("akai_uinput");
            libraryLoaded = true;
            Log.i(TAG, "Native library libakai_uinput.so loaded successfully");
        } catch (UnsatisfiedLinkError e) {
            libraryLoaded = false;
            Log.e(TAG, "Native library libakai_uinput.so not found: " + e.getMessage());
        }
    }

    public static boolean isLibraryLoaded() {
        return libraryLoaded;
    }

    public int getFd() {
        return fd;
    }

    public synchronized boolean init() {
        if (isAvailable && fd >= 0) return true;
        try {
            fd = nativeInit();
            isAvailable = (fd >= 0);
            if (isAvailable) {
                Log.i(TAG, "UInput driver successfully initialized with fd=" + fd);
            } else {
                Log.w(TAG, "UInput driver could not be opened (permission denied or unsupported)");
            }
        } catch (Throwable t) {
            Log.e(TAG, "Failed calling nativeInit: " + t.getMessage());
            isAvailable = false;
        }
        return isAvailable;
    }

    public synchronized boolean sendKey(int keycode) {
        if (!isAvailable || fd < 0) return false;
        try {
            return nativeSendKey(fd, keycode);
        } catch (Throwable t) {
            Log.e(TAG, "Error sending keycode " + keycode + ": " + t.getMessage());
            return false;
        }
    }

    public synchronized void close() {
        if (isAvailable && fd >= 0) {
            try {
                nativeClose(fd);
            } catch (Throwable t) {
                Log.e(TAG, "Error closing uinput fd: " + t.getMessage());
            }
            fd = -1;
            isAvailable = false;
        }
    }

    public synchronized boolean typeString(String text) {
        if (!isAvailable || fd < 0 || text == null) return false;
        boolean allSent = true;
        for (char c : text.toCharArray()) {
            int code = charToLinuxKey(c);
            if (code > 0) {
                sendKey(code);
            } else {
                allSent = false;
            }
        }
        return allSent;
    }

    private static int charToLinuxKey(char c) {
        c = Character.toLowerCase(c);
        switch (c) {
            case 'a': return 30;
            case 'b': return 48;
            case 'c': return 46;
            case 'd': return 32;
            case 'e': return 18;
            case 'f': return 33;
            case 'g': return 34;
            case 'h': return 35;
            case 'i': return 23;
            case 'j': return 36;
            case 'k': return 37;
            case 'l': return 38;
            case 'm': return 50;
            case 'n': return 49;
            case 'o': return 24;
            case 'p': return 25;
            case 'q': return 16;
            case 'r': return 19;
            case 's': return 31;
            case 't': return 20;
            case 'u': return 22;
            case 'v': return 47;
            case 'w': return 17;
            case 'x': return 45;
            case 'y': return 21;
            case 'z': return 44;
            case '0': return KEY_0;
            case '1': return KEY_1;
            case '2': return KEY_2;
            case '3': return KEY_3;
            case '4': return KEY_4;
            case '5': return KEY_5;
            case '6': return KEY_6;
            case '7': return KEY_7;
            case '8': return KEY_8;
            case '9': return KEY_9;
            case ' ': return KEY_SPACE;
            case '.': return KEY_DOT;
            case '-': return KEY_MINUS;
            case '/': return KEY_SLASH;
            default: return -1;
        }
    }

    public boolean isAvailable() {
        return isAvailable;
    }

    private native int nativeInit();
    private native boolean nativeSendKey(int fd, int keycode);
    private native void nativeClose(int fd);
}
