package android.app;

import android.content.Context;
import android.content.Intent;
import android.content.IntentSender;

public final class PendingIntent {
    public static final int FLAG_UPDATE_CURRENT = 1 << 27;

    private final IntentSender sender = new IntentSender();

    private PendingIntent() {}

    public static PendingIntent getBroadcast(Context context, int requestCode,
                                             Intent intent, int flags) {
        return new PendingIntent();
    }

    public IntentSender getIntentSender() {
        return sender;
    }
}
