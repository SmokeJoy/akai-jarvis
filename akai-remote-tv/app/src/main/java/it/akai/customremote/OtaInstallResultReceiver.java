package it.akai.customremote;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.os.Build;
import android.util.Log;

import it.akai.customremote.ai.OtaAndroidArchiveInspector;

/**
 * Non-exported, explicit status receiver for an owner-authorized Android 9
 * PackageInstaller session. Never issues an install or installs silently.
 *
 * STATUS_PENDING_USER_ACTION opens only the OS-supplied installer confirmation
 * screen on the TV; the owner must accept or decline there. STATUS_SUCCESS
 * is checked against the actual installed package/signing certificate.
 */
public final class OtaInstallResultReceiver extends BroadcastReceiver {
    public static final String ACTION_OTA_INSTALL_RESULT =
            "it.akai.customremote.action.OTA_INSTALL_RESULT";
    public static final String EXTRA_EXPECTED_SESSION_ID =
            "it.akai.customremote.extra.EXPECTED_OTA_SESSION_ID";
    public static final String EXTRA_EXPECTED_VERSION_CODE =
            "it.akai.customremote.extra.EXPECTED_OTA_VERSION";
    private static final String PREFS = "jarvis_ota_result";
    private static final String TAG = "JARVIS_OTA";

    public static String lastResult(Context context) {
        if (context == null) return "OTA_STATUS_UNKNOWN";
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString("status", "NOT_INSTALLED");
    }

    private static void record(Context context, String result) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString("status", result).apply();
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        if (context == null || intent == null ||
                !ACTION_OTA_INSTALL_RESULT.equals(intent.getAction()) ||
                Build.VERSION.SDK_INT != Build.VERSION_CODES.P)
            return;

        int expectedSessionId = intent.getIntExtra(EXTRA_EXPECTED_SESSION_ID, -1);
        int actualSessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1);
        int expectedVersion = intent.getIntExtra(EXTRA_EXPECTED_VERSION_CODE, -1);
        // Android OS supplies EXTRA_SESSION_ID; never act on a forged or
        // mismatched callback. Receiver is additionally exported=false.
        if (expectedSessionId < 0 || actualSessionId != expectedSessionId ||
                expectedVersion < 1) {
            Log.w(TAG, "Ignoring mismatched OTA session callback");
            return;
        }

        int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS,
                PackageInstaller.STATUS_FAILURE);
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            Intent userIntent = intent.getParcelableExtra(Intent.EXTRA_INTENT);
            if (userIntent == null) {
                record(context, "OS_USER_ACTION_INTENT_MISSING");
                return;
            }
            try {
                // Android 9 background activity launch is permitted here;
                // never start another installer without the OS prompt.
                userIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                record(context, "WAITING_FOR_ANDROID_USER_CONFIRMATION");
                context.startActivity(userIntent);
            } catch (Exception osUiFailed) {
                record(context, "OS_CONFIRMATION_UI_UNAVAILABLE");
                Log.w(TAG, "Android install confirmation could not be displayed");
            }
        } else if (status == PackageInstaller.STATUS_SUCCESS) {
            OtaAndroidArchiveInspector.InstalledIdentity now =
                    OtaAndroidArchiveInspector.readInstalledIdentity(context);
            if (now != null && now.versionCode >= expectedVersion) {
                record(context, "ANDROID_APPLIED_NOT_SMOKE_TESTED");
                Log.i(TAG, "OTA package version/signing verified; hardware smoke test outstanding");
            } else {
                record(context, "ANDROID_REPORTED_SUCCESS_IDENTITY_NOT_VERIFIED");
                Log.w(TAG, "OTA success callback but installed signer/version not verified");
            }
        } else {
            // Do not persist the OS status message: it may include sensitive
            // paths and is not needed for the on-TV diagnostic.
            record(context, "ANDROID_INSTALL_FAILED_STATUS_" + status);
            Log.w(TAG, "Android OTA install failed with status " + status);
        }
    }
}
