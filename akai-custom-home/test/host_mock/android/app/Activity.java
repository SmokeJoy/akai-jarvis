package android.app;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.os.Bundle;
import android.view.View;
public class Activity extends Context {
    protected void onCreate(Bundle b) {}
    protected void onResume() {}
    protected void onPause() {}
    public void onBackPressed() {}
    public void setContentView(int id) {}
    public View findViewById(int id) { return null; }
    public View getCurrentFocus() { return null; }
    public SharedPreferences getSharedPreferences(String n, int m) { return null; }
    public PackageManager getPackageManager() { return new PackageManager(); }
    public Context getApplicationContext() { return this; }
    public void startActivity(Intent i) {}
    public void sendBroadcast(Intent i) {}
    public void registerReceiver(BroadcastReceiver r, IntentFilter f) {}
    public void unregisterReceiver(BroadcastReceiver r) {}
    public Resources getResources() { return new Resources(); }
}
