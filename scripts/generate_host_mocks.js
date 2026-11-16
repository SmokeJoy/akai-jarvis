const fs = require('fs');
const path = require('path');

const baseDir = path.resolve(__dirname, '..', 'akai-custom-home', 'test', 'host_mock');

const files = {
    'android/app/Activity.java': `package android.app;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.os.Bundle;
import android.view.View;
public class Activity extends Context {
    protected void onCreate(Bundle b) {}
    protected void onResume() {}
    protected void onPause() {}
    public void setContentView(int id) {}
    public View findViewById(int id) { return null; }
    public SharedPreferences getSharedPreferences(String n, int m) { return null; }
    public PackageManager getPackageManager() { return new PackageManager(); }
    public Context getApplicationContext() { return this; }
    public void startActivity(Intent i) {}
    public void sendBroadcast(Intent i) {}
    public void registerReceiver(BroadcastReceiver r, IntentFilter f) {}
    public void unregisterReceiver(BroadcastReceiver r) {}
    public Resources getResources() { return new Resources(); }
}`,

    'android/app/AlertDialog.java': `package android.app;
import android.content.Context;
import android.content.DialogInterface;
public class AlertDialog {
    public static class Builder {
        public Builder(Context c, int t) {}
        public Builder setTitle(CharSequence t) { return this; }
        public Builder setItems(CharSequence[] i, DialogInterface.OnClickListener l) { return this; }
        public Builder setSingleChoiceItems(CharSequence[] i, int c, DialogInterface.OnClickListener l) { return this; }
        public Builder setNegativeButton(CharSequence t, DialogInterface.OnClickListener l) { return this; }
        public AlertDialog show() { return new AlertDialog(); }
    }
    public void dismiss() {}
}`,

    'android/content/Context.java': `package android.content;
public class Context {
    public static final int MODE_PRIVATE = 0;
    public static final String WIFI_SERVICE = "wifi";
    public Object getSystemService(String name) { return null; }
}`,

    'android/content/ComponentName.java': `package android.content;
public class ComponentName {
    public ComponentName(String p, String c) {}
}`,

    'android/content/DialogInterface.java': `package android.content;
public interface DialogInterface {
    interface OnClickListener {
        void onClick(DialogInterface d, int w);
    }
    void dismiss();
}`,

    'android/content/Intent.java': `package android.content;
import android.net.Uri;
public class Intent {
    public static final String ACTION_MAIN = "android.intent.action.MAIN";
    public static final String ACTION_VIEW = "android.intent.action.VIEW";
    public static final String CATEGORY_DEFAULT = "android.intent.category.DEFAULT";
    public static final String CATEGORY_LAUNCHER = "android.intent.category.LAUNCHER";
    public static final String CATEGORY_LEANBACK_LAUNCHER = "android.intent.category.LEANBACK_LAUNCHER";
    public static final String ACTION_PACKAGE_ADDED = "android.intent.action.PACKAGE_ADDED";
    public static final String ACTION_PACKAGE_REMOVED = "android.intent.action.PACKAGE_REMOVED";
    public static final String ACTION_PACKAGE_REPLACED = "android.intent.action.PACKAGE_REPLACED";
    public static final int FLAG_ACTIVITY_NEW_TASK = 268435456;
    public Intent() {}
    public Intent(String a) {}
    public Intent(String a, Uri u) {}
    public Intent addCategory(String c) { return this; }
    public Intent addFlags(int f) { return this; }
    public Intent setComponent(ComponentName c) { return this; }
    public Intent setPackage(String p) { return this; }
    public Intent setData(Uri u) { return this; }
}`,

    'android/content/IntentFilter.java': `package android.content;
public class IntentFilter {
    public IntentFilter() {}
    public void addAction(String a) {}
    public void addDataScheme(String s) {}
}`,

    'android/content/BroadcastReceiver.java': `package android.content;
public abstract class BroadcastReceiver {
    public abstract void onReceive(Context c, Intent i);
}`,

    'android/content/SharedPreferences.java': `package android.content;
import java.util.Set;
public interface SharedPreferences {
    interface Editor {
        Editor putString(String k, String v);
        Editor putStringSet(String k, Set<String> v);
        Editor putInt(String k, int v);
        Editor putBoolean(String k, boolean v);
        void apply();
    }
    String getString(String k, String d);
    Set<String> getStringSet(String k, Set<String> d);
    int getInt(String k, int d);
    boolean getBoolean(String k, boolean d);
    Editor edit();
}`,

    'android/content/res/Resources.java': `package android.content.res;
import android.util.DisplayMetrics;
public class Resources {
    public DisplayMetrics getDisplayMetrics() { return new DisplayMetrics(); }
}`,

    'android/util/DisplayMetrics.java': `package android.util;
public class DisplayMetrics {
    public float density = 1.5f;
}`,

    'android/content/pm/PackageManager.java': `package android.content.pm;
import android.content.Intent;
import java.util.ArrayList;
import java.util.List;
public class PackageManager {
    public List<ResolveInfo> queryIntentActivities(Intent i, int f) { return new ArrayList<ResolveInfo>(); }
    public Intent getLaunchIntentForPackage(String p) { return new Intent(); }
    public Intent getLeanbackLaunchIntentForPackage(String p) { return new Intent(); }
}`,

    'android/content/pm/ResolveInfo.java': `package android.content.pm;
import android.graphics.drawable.Drawable;
public class ResolveInfo {
    public ActivityInfo activityInfo = new ActivityInfo();
    public CharSequence loadLabel(PackageManager pm) { return ""; }
    public Drawable loadIcon(PackageManager pm) { return null; }
}`,

    'android/content/pm/ActivityInfo.java': `package android.content.pm;
public class ActivityInfo {
    public String packageName = "";
    public String name = "";
}`,

    'android/graphics/drawable/Drawable.java': `package android.graphics.drawable;
public class Drawable {}`,

    'android/graphics/drawable/GradientDrawable.java': `package android.graphics.drawable;
public class GradientDrawable extends Drawable {
    public void setColor(int c) {}
    public void setCornerRadius(float r) {}
    public void setStroke(int w, int c) {}
}`,

    'android/graphics/drawable/StateListDrawable.java': `package android.graphics.drawable;
public class StateListDrawable extends Drawable {
    public void addState(int[] s, Drawable d) {}
}`,

    'android/net/Uri.java': `package android.net;
public class Uri {
    public static Uri parse(String s) { return new Uri(); }
    public static String encode(String s) { return s; }
}`,

    'android/net/wifi/WifiManager.java': `package android.net.wifi;
public class WifiManager {
    public boolean isWifiEnabled() { return true; }
    public WifiInfo getConnectionInfo() { return new WifiInfo(); }
}`,

    'android/net/wifi/WifiInfo.java': `package android.net.wifi;
public class WifiInfo {
    public String getSSID() { return "AKAI_HOME_WIFI"; }
}`,

    'android/os/Bundle.java': `package android.os;
public class Bundle {}`,

    'android/provider/Settings.java': `package android.provider;
public class Settings {
    public static final String ACTION_SETTINGS = "settings";
    public static final String ACTION_WIFI_SETTINGS = "wifi";
    public static final String ACTION_APPLICATION_DETAILS_SETTINGS = "app_details";
}`,

    'android/text/TextUtils.java': `package android.text;
public class TextUtils {
    public static String join(CharSequence d, Iterable t) {
        StringBuilder sb = new StringBuilder();
        boolean first = true;
        for (Object o : t) {
            if (!first) sb.append(d);
            sb.append(o);
            first = false;
        }
        return sb.toString();
    }
}`,

    'android/view/LayoutInflater.java': `package android.view;
import android.content.Context;
public class LayoutInflater {
    public static LayoutInflater from(Context c) { return new LayoutInflater(); }
    public View inflate(int r, ViewGroup p, boolean a) { return new View(); }
}`,

    'android/view/ViewGroup.java': `package android.view;
public class ViewGroup extends View {
    public void addView(View v) {}
    public void addView(View v, int i) {}
    public void removeView(View v) {}
    public void removeAllViews() {}
}`,

    'android/view/ViewPropertyAnimator.java': `package android.view;
public class ViewPropertyAnimator {
    public ViewPropertyAnimator scaleX(float s) { return this; }
    public ViewPropertyAnimator scaleY(float s) { return this; }
    public ViewPropertyAnimator setDuration(long d) { return this; }
    public void start() {}
}`,

    'android/widget/TextView.java': `package android.widget;
import android.view.View;
public class TextView extends View {
    public void setText(CharSequence s) {}
    public void setTextColor(int c) {}
}`,

    'android/widget/Button.java': `package android.widget;
public class Button extends TextView {
    public void requestFocus() {}
}`,

    'android/widget/ImageView.java': `package android.widget;
import android.graphics.drawable.Drawable;
import android.view.View;
public class ImageView extends View {
    public void setImageDrawable(Drawable d) {}
}`,

    'android/widget/LinearLayout.java': `package android.widget;
import android.view.ViewGroup;
public class LinearLayout extends ViewGroup {}`,

    'android/widget/ScrollView.java': `package android.widget;
import android.view.ViewGroup;
public class ScrollView extends ViewGroup {}`,

    'android/widget/HorizontalScrollView.java': `package android.widget;
import android.view.ViewGroup;
public class HorizontalScrollView extends ViewGroup {}`,

    'android/widget/Toast.java': `package android.widget;
import android.content.Context;
public class Toast {
    public static final int LENGTH_SHORT = 0;
    public static Toast makeText(Context c, CharSequence s, int d) { return new Toast(); }
    public void show() {}
}`,

    'it/akai/customhome/R.java': `package it.akai.customhome;
public class R {
    public static class layout {
        public static final int activity_main = 1;
        public static final int item_leanback_card = 2;
    }
    public static class id {
        public static final int layout_main_root = 1;
        public static final int scroll_main_body = 2;
        public static final int layout_sections_container = 3;
        public static final int section_inputs_container = 4;
        public static final int section_favorites_container = 5;
        public static final int section_streaming_container = 6;
        public static final int section_all_apps_container = 7;
        public static final int tv_title_inputs = 8;
        public static final int tv_title_favorites = 9;
        public static final int tv_title_streaming = 10;
        public static final int tv_title_all_apps = 11;
        public static final int btn_home_wifi = 12;
        public static final int btn_fav_reorder = 13;
        public static final int btn_home_theme = 14;
        public static final int btn_home_remote = 15;
        public static final int btn_home_settings = 16;
        public static final int btn_src_dtv = 17;
        public static final int btn_src_hdmi1 = 18;
        public static final int btn_src_hdmi2 = 19;
        public static final int btn_src_hdmi3 = 20;
        public static final int btn_src_all = 21;
        public static final int ll_inputs_container = 22;
        public static final int ll_fav_container = 23;
        public static final int ll_streaming_container = 24;
        public static final int ll_all_apps_container = 25;
        public static final int layout_fav_header = 26;
        public static final int layout_streaming_header = 27;
        public static final int layout_all_apps_header = 28;
        public static final int scroll_favs = 29;
        public static final int scroll_streaming = 30;
        public static final int scroll_all_apps = 31;
        public static final int iv_card_icon = 32;
        public static final int tv_card_label = 33;
    }
}`
};

for (const [relPath, content] of Object.entries(files)) {
    const fullPath = path.join(baseDir, relPath);
    fs.mkdirSync(path.dirname(fullPath), { recursive: true });
    fs.writeFileSync(fullPath, content.trim() + '\n', 'utf8');
}
console.log('Generated ' + Object.keys(files).length + ' host mock files successfully.');
