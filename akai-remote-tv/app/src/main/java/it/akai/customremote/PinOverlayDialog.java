package it.akai.customremote;

import android.content.Context;

public class PinOverlayDialog {
    public static void show(Context context, String pin, int durationSeconds) {
        show(context, pin, durationSeconds, "http://192.168.1.8:8088");
    }

    public static void show(Context context, String pin, int durationSeconds, String serverUrl) {
        PinActivity.launch(context, pin, durationSeconds, serverUrl);
    }

    public static void dismiss() {
        PinActivity.dismiss();
    }
}
