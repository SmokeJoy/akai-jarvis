package it.akai.customhome;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ComponentName;
import android.content.Context;
import android.content.DialogInterface;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.StateListDrawable;
import android.net.Uri;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.Bundle;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.KeyEvent;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.AdapterView;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.GridView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

public class MainActivity extends Activity {

    public static class AppItem implements Comparable<AppItem> {
        public final String label;
        public final String packageName;
        public final String activityName;
        public final Drawable icon;

        public AppItem(String label, String packageName, String activityName, Drawable icon) {
            this.label = label;
            this.packageName = packageName;
            this.activityName = activityName;
            this.icon = icon;
        }

        @Override
        public int compareTo(AppItem other) {
            return this.label.compareToIgnoreCase(other.label);
        }
    }

    private static final String PREFS_NAME = "akai_custom_home_prefs";
    private static final String KEY_FAVORITES_ORDERED = "user_favorites_ordered";
    private static final String KEY_FAVORITES_LEGACY = "user_favorites";
    private static final String KEY_THEME_BG = "theme_bg_index";
    private static final String KEY_THEME_ACCENT = "theme_accent_index";
    private static final String KEY_LAYOUT_ORDER = "theme_layout_order";

    // Theme Palettes
    private static final int[] BG_COLORS = {
        0xFF0A0B10, // 0: Midnight Dark (Originale)
        0xFF081225, // 1: Deep Navy Blue
        0xFF0F172A, // 2: Carbon Slate
        0xFF000000, // 3: Pure OLED Black
        0xFF18080C  // 4: Ruby Dark
    };

    private static final int[] SURFACE_COLORS = {
        0xFF141B2D,
        0xFF0F2244,
        0xFF1E293B,
        0xFF121212,
        0xFF2D1016
    };

    private static final int[] FOCUSED_SURFACE_COLORS = {
        0xFF1E3A8A,
        0xFF1E40AF,
        0xFF334155,
        0xFF262626,
        0xFF4C1D24
    };

    private static final int[] ACCENT_COLORS = {
        0xFFF59E0B, // 0: Oro AKAI
        0xFF00E5FF, // 1: Ciano Neon
        0xFFE50914, // 2: Rosso AKAI
        0xFF10B981  // 3: Smeraldo
    };

    private static final String[] ACCENT_NAMES = {
        "Oro AKAI (#F59E0B)",
        "Ciano Neon (#00E5FF)",
        "Rosso AKAI (#E50914)",
        "Smeraldo (#10B981)"
    };

    private static final String[] BG_NAMES = {
        "Midnight Dark (Default)",
        "Deep Navy Blue (Blu Notte)",
        "Carbon Slate (Ardesia Scuro)",
        "Pure OLED Black (Nero Assoluto)",
        "Ruby Dark (Rosso Notturno)"
    };

    private LinearLayout layoutMainRoot;
    private LinearLayout sectionInputsContainer;
    private LinearLayout sectionFavoritesContainer;
    private LinearLayout sectionAllAppsContainer;

    private TextView tvTitleFavorites;
    private Button btnWifi;
    private Button btnFavReorder;
    private Button btnTheme;
    private GridView gvApps;
    private LinearLayout llFavContainer;
    private View layoutFavHeader;

    private List<AppItem> allApps = new ArrayList<AppItem>();
    private List<AppItem> favoriteApps = new ArrayList<AppItem>();
    private List<String> favoritePackages = new ArrayList<String>();
    private SharedPreferences prefs;

    private int currentBgIndex = 0;
    private int currentAccentIndex = 0;
    private int currentLayoutOrder = 0; // 0: Ingressi prima, 1: Preferiti prima

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        loadPreferences();

        layoutMainRoot = (LinearLayout) findViewById(R.id.layout_main_root);
        sectionInputsContainer = (LinearLayout) findViewById(R.id.section_inputs_container);
        sectionFavoritesContainer = (LinearLayout) findViewById(R.id.section_favorites_container);
        sectionAllAppsContainer = (LinearLayout) findViewById(R.id.section_all_apps_container);

        tvTitleFavorites = (TextView) findViewById(R.id.tv_title_favorites);
        btnWifi = (Button) findViewById(R.id.btn_home_wifi);
        btnFavReorder = (Button) findViewById(R.id.btn_fav_reorder);
        btnTheme = (Button) findViewById(R.id.btn_home_theme);
        gvApps = (GridView) findViewById(R.id.gv_apps);
        llFavContainer = (LinearLayout) findViewById(R.id.ll_fav_container);
        layoutFavHeader = findViewById(R.id.layout_fav_header);

        setupTopBar();
        setupHardwareInputs();
        loadInstalledApps();
        applyTheme();
    }

    @Override
    protected void onResume() {
        super.onResume();
        updateWifiStatus();
    }

    @Override
    public void onBackPressed() {
        Toast.makeText(this, "Premi HOME sul telecomando per tornare a LTvLauncher", Toast.LENGTH_SHORT).show();
    }

    private void loadPreferences() {
        currentBgIndex = prefs.getInt(KEY_THEME_BG, 0);
        if (currentBgIndex < 0 || currentBgIndex >= BG_COLORS.length) currentBgIndex = 0;

        currentAccentIndex = prefs.getInt(KEY_THEME_ACCENT, 0);
        if (currentAccentIndex < 0 || currentAccentIndex >= ACCENT_COLORS.length) currentAccentIndex = 0;

        currentLayoutOrder = prefs.getInt(KEY_LAYOUT_ORDER, 0);

        favoritePackages.clear();
        String savedOrdered = prefs.getString(KEY_FAVORITES_ORDERED, null);
        if (savedOrdered != null && !savedOrdered.trim().isEmpty()) {
            String[] parts = savedOrdered.split(",");
            for (String p : parts) {
                String trimmed = p.trim();
                if (!trimmed.isEmpty() && !favoritePackages.contains(trimmed)) {
                    favoritePackages.add(trimmed);
                }
            }
        } else {
            Set<String> legacy = prefs.getStringSet(KEY_FAVORITES_LEGACY, null);
            if (legacy != null && !legacy.isEmpty()) {
                favoritePackages.addAll(legacy);
            } else {
                favoritePackages.add("com.google.android.youtube.tv");
                favoritePackages.add("it.rainet.androidtv");
                favoritePackages.add("com.android.vending");
                favoritePackages.add("com.mediatek.wwtv.tvcenter");
            }
            saveFavoritePreferences();
        }

        if (!favoritePackages.contains("it.rainet.androidtv")) {
            favoritePackages.add("it.rainet.androidtv");
            saveFavoritePreferences();
        }
        if (!favoritePackages.contains("it.mediaset.infinitytv")) {
            favoritePackages.add("it.mediaset.infinitytv");
            saveFavoritePreferences();
        }
        if (!favoritePackages.contains("com.disney.disneyplus")) {
            favoritePackages.add("com.disney.disneyplus");
            saveFavoritePreferences();
        }
    }

    private void saveFavoritePreferences() {
        SharedPreferences.Editor editor = prefs.edit();
        editor.putString(KEY_FAVORITES_ORDERED, TextUtils.join(",", favoritePackages));
        editor.putStringSet(KEY_FAVORITES_LEGACY, new HashSet<String>(favoritePackages));
        editor.apply();
    }

    private void saveThemePreferences() {
        SharedPreferences.Editor editor = prefs.edit();
        editor.putInt(KEY_THEME_BG, currentBgIndex);
        editor.putInt(KEY_THEME_ACCENT, currentAccentIndex);
        editor.putInt(KEY_LAYOUT_ORDER, currentLayoutOrder);
        editor.apply();
    }

    private void applyTheme() {
        int bg = BG_COLORS[currentBgIndex];
        int accent = ACCENT_COLORS[currentAccentIndex];

        if (layoutMainRoot != null) {
            layoutMainRoot.setBackgroundColor(bg);
        }
        if (tvTitleFavorites != null) {
            tvTitleFavorites.setTextColor(accent);
        }
        if (btnFavReorder != null) {
            btnFavReorder.setTextColor(accent);
        }

        applySectionOrder(currentLayoutOrder == 1);
        updateFavoritesList();
        if (gvApps != null && gvApps.getAdapter() != null) {
            ((BaseAdapter) gvApps.getAdapter()).notifyDataSetChanged();
        }
    }

    private void applySectionOrder(boolean favsFirst) {
        if (layoutMainRoot == null || sectionInputsContainer == null || sectionFavoritesContainer == null) return;
        layoutMainRoot.removeView(sectionInputsContainer);
        layoutMainRoot.removeView(sectionFavoritesContainer);

        if (favsFirst) {
            layoutMainRoot.addView(sectionFavoritesContainer, 1);
            layoutMainRoot.addView(sectionInputsContainer, 2);
        } else {
            layoutMainRoot.addView(sectionInputsContainer, 1);
            layoutMainRoot.addView(sectionFavoritesContainer, 2);
        }
    }

    private StateListDrawable createDynamicCardSelector() {
        float density = getResources().getDisplayMetrics().density;
        int cornerPx = (int) (14 * density);
        int strokeWidthPx = (int) (3 * density);

        int normalBg = SURFACE_COLORS[currentBgIndex];
        int focusedBg = FOCUSED_SURFACE_COLORS[currentBgIndex];
        int accent = ACCENT_COLORS[currentAccentIndex];

        StateListDrawable sld = new StateListDrawable();

        // Focused state
        GradientDrawable focused = new GradientDrawable();
        focused.setColor(focusedBg);
        focused.setCornerRadius(cornerPx);
        focused.setStroke(strokeWidthPx, accent);
        sld.addState(new int[]{android.R.attr.state_focused}, focused);

        // Pressed state
        GradientDrawable pressed = new GradientDrawable();
        pressed.setColor(focusedBg);
        pressed.setCornerRadius(cornerPx);
        sld.addState(new int[]{android.R.attr.state_pressed}, pressed);

        // Normal state
        GradientDrawable normal = new GradientDrawable();
        normal.setColor(normalBg);
        normal.setCornerRadius(cornerPx);
        normal.setStroke((int) (1 * density), 0xFF1E293B);
        sld.addState(new int[]{}, normal);

        return sld;
    }

    private void setupTopBar() {
        btnWifi.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    startActivity(new Intent(Settings.ACTION_WIFI_SETTINGS));
                } catch (Exception e) {
                    try {
                        startActivity(new Intent(Settings.ACTION_SETTINGS));
                    } catch (Exception ignored) {}
                }
            }
        });

        Button btnRemote = (Button) findViewById(R.id.btn_home_remote);
        btnRemote.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                launchRemotePairing();
            }
        });

        if (btnTheme != null) {
            btnTheme.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    showThemeDialog();
                }
            });
        }

        Button btnSettings = (Button) findViewById(R.id.btn_home_settings);
        btnSettings.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                launchSettings();
            }
        });

        if (btnFavReorder != null) {
            btnFavReorder.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    showReorderAllDialog();
                }
            });
        }

        updateWifiStatus();
    }

    private void showThemeDialog() {
        AlertDialog.Builder builder = new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert);
        builder.setTitle("🎨 Personalizzazione AKAI Home v7");

        String[] options = {
            "🎨 Scegli Sfondo (" + BG_NAMES[currentBgIndex] + ")",
            "✨ Colore Evidenziazione Focus (" + ACCENT_NAMES[currentAccentIndex] + ")",
            "📐 Disposizione Sezioni (" + (currentLayoutOrder == 0 ? "Ingressi prima" : "Preferiti prima") + ")",
            "🔄 Ripristina Impostazioni Predefinite"
        };

        builder.setItems(options, new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int which) {
                if (which == 0) {
                    showBackgroundSelectorDialog();
                } else if (which == 1) {
                    showAccentSelectorDialog();
                } else if (which == 2) {
                    showLayoutOrderSelectorDialog();
                } else if (which == 3) {
                    currentBgIndex = 0;
                    currentAccentIndex = 0;
                    currentLayoutOrder = 0;
                    saveThemePreferences();
                    applyTheme();
                    Toast.makeText(MainActivity.this, "Tema ripristinato", Toast.LENGTH_SHORT).show();
                }
            }
        });
        builder.setNegativeButton("Chiudi", null);
        builder.show();
    }

    private void showBackgroundSelectorDialog() {
        AlertDialog.Builder builder = new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert);
        builder.setTitle("🎨 Scegli Sfondo TV");

        builder.setSingleChoiceItems(BG_NAMES, currentBgIndex, new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int which) {
                currentBgIndex = which;
                saveThemePreferences();
                applyTheme();
                Toast.makeText(MainActivity.this, "Sfondo: " + BG_NAMES[which], Toast.LENGTH_SHORT).show();
                dialog.dismiss();
            }
        });
        builder.setNegativeButton("Annulla", null);
        builder.show();
    }

    private void showAccentSelectorDialog() {
        AlertDialog.Builder builder = new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert);
        builder.setTitle("✨ Scegli Colore Evidenziazione (Focus)");

        builder.setSingleChoiceItems(ACCENT_NAMES, currentAccentIndex, new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int which) {
                currentAccentIndex = which;
                saveThemePreferences();
                applyTheme();
                Toast.makeText(MainActivity.this, "Accento: " + ACCENT_NAMES[which], Toast.LENGTH_SHORT).show();
                dialog.dismiss();
            }
        });
        builder.setNegativeButton("Annulla", null);
        builder.show();
    }

    private void showLayoutOrderSelectorDialog() {
        AlertDialog.Builder builder = new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert);
        builder.setTitle("📐 Disposizione Sezioni Home");

        String[] layoutNames = {
            "1. Ingressi Hardware prima (Standard)",
            "2. App Preferite prima (Focus Multimediale)"
        };

        builder.setSingleChoiceItems(layoutNames, currentLayoutOrder, new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int which) {
                currentLayoutOrder = which;
                saveThemePreferences();
                applyTheme();
                Toast.makeText(MainActivity.this, "Disposizione: " + layoutNames[which], Toast.LENGTH_SHORT).show();
                dialog.dismiss();
            }
        });
        builder.setNegativeButton("Annulla", null);
        builder.show();
    }

    private void launchRemotePairing() {
        try {
            Intent pairIntent = new Intent("it.akai.customremote.ACTION_PAIR");
            pairIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(pairIntent);
        } catch (Exception e1) {
            try {
                Intent fallbackIntent = new Intent();
                fallbackIntent.setComponent(new ComponentName("it.akai.customremote", "it.akai.customremote.PinActivity"));
                fallbackIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(fallbackIntent);
            } catch (Exception e2) {
                Toast.makeText(MainActivity.this, "AKAI Remote non trovato sulla TV", Toast.LENGTH_SHORT).show();
            }
        }
    }

    private void launchSettings() {
        try {
            Intent intent = new Intent();
            intent.setComponent(new ComponentName("com.android.tv.settings", "com.android.tv.settings.MainSettings"));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
        } catch (Exception e1) {
            try {
                startActivity(new Intent(Settings.ACTION_SETTINGS));
            } catch (Exception e2) {
                Toast.makeText(MainActivity.this, "Impossibile aprire impostazioni", Toast.LENGTH_SHORT).show();
            }
        }
    }

    private String getLocalIpAddress() {
        try {
            for (Enumeration<NetworkInterface> en = NetworkInterface.getNetworkInterfaces(); en.hasMoreElements();) {
                NetworkInterface intf = en.nextElement();
                for (Enumeration<InetAddress> enumIpAddr = intf.getInetAddresses(); enumIpAddr.hasMoreElements();) {
                    InetAddress inetAddress = enumIpAddr.nextElement();
                    if (!inetAddress.isLoopbackAddress() && inetAddress instanceof Inet4Address) {
                        return inetAddress.getHostAddress();
                    }
                }
            }
        } catch (Exception ignored) {}
        return "192.168.1.8";
    }

    private void updateWifiStatus() {
        try {
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            String ssid = "Wi-Fi";
            if (wm != null && wm.isWifiEnabled()) {
                WifiInfo info = wm.getConnectionInfo();
                if (info != null && info.getSSID() != null) {
                    String cleanSsid = info.getSSID().replace("\"", "");
                    if (!cleanSsid.equals("<unknown ssid>") && !cleanSsid.isEmpty()) {
                        ssid = cleanSsid;
                    }
                }
            }
            String ip = getLocalIpAddress();
            btnWifi.setText("📶 " + ssid + " (" + ip + ")");
        } catch (Exception e) {
            btnWifi.setText("📶 Rete");
        }
    }

    private void setupHardwareInputs() {
        // DTV - Digitale Terrestre
        Button btnDtv = (Button) findViewById(R.id.btn_src_dtv);
        btnDtv.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                launchDtv();
            }
        });

        // Request initial focus on DTV button
        btnDtv.requestFocus();

        // HDMI 1 - Amazon Fire TV (con passthrough codificato)
        Button btnHdmi1 = (Button) findViewById(R.id.btn_src_hdmi1);
        btnHdmi1.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                launchHdmiInput("HW6", "Fire TV (HDMI 1)");
            }
        });

        // HDMI 2
        Button btnHdmi2 = (Button) findViewById(R.id.btn_src_hdmi2);
        btnHdmi2.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                launchHdmiInput("HW7", "HDMI 2");
            }
        });

        // HDMI 3
        Button btnHdmi3 = (Button) findViewById(R.id.btn_src_hdmi3);
        if (btnHdmi3 != null) {
            btnHdmi3.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    launchHdmiInput("HW8", "HDMI 3");
                }
            });
        }

        // Ingressi Completi (Drawer nativo Android TV)
        Button btnAll = (Button) findViewById(R.id.btn_src_all);
        btnAll.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                try {
                    Intent intent = new Intent("com.android.tv.action.VIEW_INPUTS");
                    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                    startActivity(intent);
                } catch (Exception e1) {
                    try {
                        Intent intent = new Intent();
                        intent.setComponent(new ComponentName("com.mediatek.wwtv.tvcenter", "com.mediatek.wwtv.tvcenter.nav.inputpanel.InputsPanelActivity"));
                        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                        startActivity(intent);
                    } catch (Exception e2) {
                        sendBroadcast(new Intent("com.mediatek.select.source"));
                    }
                }
            }
        });
    }

    private void launchDtv() {
        try {
            Intent intent = new Intent(Intent.ACTION_MAIN);
            intent.addCategory(Intent.CATEGORY_DEFAULT);
            intent.setComponent(new ComponentName("com.mediatek.wwtv.tvcenter", "com.mediatek.wwtv.tvcenter.nav.TurnkeyUiMainActivity"));
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
        } catch (Exception e) {
            try {
                Uri uri = Uri.parse("content://android.media.tv/passthrough/" + Uri.encode("com.mediatek.tvinput/.tuner.TunerInputService/HW0"));
                Intent pass = new Intent(Intent.ACTION_VIEW, uri);
                pass.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(pass);
            } catch (Exception ignored) {
                sendBroadcast(new Intent("com.mediatek.select.DTV"));
            }
        }
    }

    private void launchHdmiInput(String hwId, String label) {
        try {
            String fullInputId = "com.mediatek.tvinput/.hdmi.HDMIInputService/" + hwId;
            Uri uri = Uri.parse("content://android.media.tv/passthrough/" + Uri.encode(fullInputId));
            Intent intent = new Intent(Intent.ACTION_VIEW, uri);
            intent.setPackage("com.mediatek.wwtv.tvcenter");
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
        } catch (Exception e1) {
            try {
                String fullInputId = "com.mediatek.tvinput/.hdmi.HDMIInputService/" + hwId;
                Uri uri = Uri.parse("content://android.media.tv/passthrough/" + Uri.encode(fullInputId));
                Intent intent = new Intent(Intent.ACTION_VIEW, uri);
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(intent);
            } catch (Exception e2) {
                sendBroadcast(new Intent("com.mediatek.select." + label));
                Toast.makeText(this, "Passaggio a " + label + "...", Toast.LENGTH_SHORT).show();
            }
        }
    }

    private void showFavoriteOptionsDialog(final AppItem fav, final int index) {
        AlertDialog.Builder builder = new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert);
        builder.setTitle(fav.label + " (Preferiti)");

        List<String> options = new ArrayList<String>();
        final List<Integer> actions = new ArrayList<Integer>();

        if (index > 0) {
            options.add("⬅️ Sposta a sinistra");
            actions.add(1);
        }
        if (index < favoritePackages.size() - 1) {
            options.add("➡️ Sposta a destra");
            actions.add(2);
        }
        options.add("❌ Rimuovi dai Preferiti");
        actions.add(3);
        options.add("ℹ️ Informazioni Applicazione");
        actions.add(4);

        CharSequence[] items = options.toArray(new CharSequence[options.size()]);
        builder.setItems(items, new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int which) {
                int action = actions.get(which);
                if (action == 1) {
                    Collections.swap(favoritePackages, index, index - 1);
                    saveFavoritePreferences();
                    updateFavoritesList();
                    Toast.makeText(MainActivity.this, fav.label + " spostato a sinistra", Toast.LENGTH_SHORT).show();
                } else if (action == 2) {
                    Collections.swap(favoritePackages, index, index + 1);
                    saveFavoritePreferences();
                    updateFavoritesList();
                    Toast.makeText(MainActivity.this, fav.label + " spostato a destra", Toast.LENGTH_SHORT).show();
                } else if (action == 3) {
                    favoritePackages.remove(fav.packageName);
                    saveFavoritePreferences();
                    updateFavoritesList();
                    Toast.makeText(MainActivity.this, fav.label + " rimosso dai Preferiti", Toast.LENGTH_SHORT).show();
                } else if (action == 4) {
                    try {
                        Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                        intent.setData(Uri.parse("package:" + fav.packageName));
                        startActivity(intent);
                    } catch (Exception e) {
                        Toast.makeText(MainActivity.this, "Impossibile aprire dettagli", Toast.LENGTH_SHORT).show();
                    }
                }
            }
        });
        builder.setNegativeButton("Chiudi", null);
        builder.show();
    }

    private void showAppOptionsDialog(final AppItem item) {
        AlertDialog.Builder builder = new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert);
        builder.setTitle(item.label);

        final boolean isFav = favoritePackages.contains(item.packageName);
        List<String> options = new ArrayList<String>();
        if (isFav) {
            options.add("❌ Rimuovi dai Preferiti");
        } else {
            options.add("⭐ Aggiungi ai Preferiti");
        }
        options.add("ℹ️ Informazioni Applicazione");

        CharSequence[] items = options.toArray(new CharSequence[options.size()]);
        builder.setItems(items, new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int which) {
                if (which == 0) {
                    if (isFav) {
                        favoritePackages.remove(item.packageName);
                        Toast.makeText(MainActivity.this, item.label + " rimosso dai Preferiti", Toast.LENGTH_SHORT).show();
                    } else {
                        favoritePackages.add(item.packageName);
                        Toast.makeText(MainActivity.this, item.label + " aggiunto ai Preferiti", Toast.LENGTH_SHORT).show();
                    }
                    saveFavoritePreferences();
                    updateFavoritesList();
                } else if (which == 1) {
                    try {
                        Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                        intent.setData(Uri.parse("package:" + item.packageName));
                        startActivity(intent);
                    } catch (Exception e) {
                        Toast.makeText(MainActivity.this, "Impossibile aprire dettagli", Toast.LENGTH_SHORT).show();
                    }
                }
            }
        });
        builder.setNegativeButton("Chiudi", null);
        builder.show();
    }

    private void showReorderAllDialog() {
        if (favoriteApps.isEmpty()) {
            Toast.makeText(this, "Nessuna app nei preferiti", Toast.LENGTH_SHORT).show();
            return;
        }

        List<String> names = new ArrayList<String>();
        for (int i = 0; i < favoriteApps.size(); i++) {
            names.add((i + 1) + ". " + favoriteApps.get(i).label);
        }

        AlertDialog.Builder builder = new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert);
        builder.setTitle("Seleziona app da riordinare");
        builder.setItems(names.toArray(new CharSequence[names.size()]), new DialogInterface.OnClickListener() {
            @Override
            public void onClick(DialogInterface dialog, int which) {
                if (which >= 0 && which < favoriteApps.size()) {
                    showFavoriteOptionsDialog(favoriteApps.get(which), which);
                }
            }
        });
        builder.setNegativeButton("Chiudi", null);
        builder.show();
    }

    private void loadInstalledApps() {
        PackageManager pm = getPackageManager();
        Set<String> seen = new HashSet<String>();
        allApps.clear();

        // 1. Leanback Apps
        Intent lbIntent = new Intent(Intent.ACTION_MAIN, null);
        lbIntent.addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER);
        List<ResolveInfo> lbList = pm.queryIntentActivities(lbIntent, 0);

        // 2. Standard Launcher Apps
        Intent stdIntent = new Intent(Intent.ACTION_MAIN, null);
        stdIntent.addCategory(Intent.CATEGORY_LAUNCHER);
        List<ResolveInfo> stdList = pm.queryIntentActivities(stdIntent, 0);

        List<ResolveInfo> combined = new ArrayList<ResolveInfo>();
        if (lbList != null) combined.addAll(lbList);
        if (stdList != null) combined.addAll(stdList);

        for (ResolveInfo ri : combined) {
            String pkg = ri.activityInfo.packageName;
            String act = ri.activityInfo.name;

            // Skip OEM internal factory / diagnostic packages
            if (pkg.equals("it.akai.customhome") ||
                pkg.equals("it.akai.customremote") ||
                pkg.startsWith("com.airoha.") ||
                pkg.startsWith("com.cultraview.") ||
                pkg.equals("com.mediatek.TimeMeasurementAgent") ||
                pkg.equals("com.android.traceur") ||
                pkg.equals("com.mediatek.wwtv.factory")) {
                continue;
            }

            if (!seen.contains(pkg)) {
                seen.add(pkg);
                String label = ri.loadLabel(pm).toString();
                if (label == null || label.trim().isEmpty()) {
                    label = pkg;
                }
                Drawable icon = ri.loadIcon(pm);
                allApps.add(new AppItem(label, pkg, act, icon));
            }
        }

        Collections.sort(allApps);

        updateFavoritesList();

        gvApps.setAdapter(new AllAppsAdapter());
        gvApps.setOnItemClickListener(new AdapterView.OnItemClickListener() {
            @Override
            public void onItemClick(AdapterView<?> parent, View view, int position, long id) {
                AppItem item = allApps.get(position);
                launchApp(item);
            }
        });

        gvApps.setOnKeyListener(new View.OnKeyListener() {
            @Override
            public boolean onKey(View v, int keyCode, KeyEvent event) {
                if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER) {
                    int pos = gvApps.getSelectedItemPosition();
                    if (pos >= 0 && pos < allApps.size()) {
                        final AppItem item = allApps.get(pos);
                        if (event.getAction() == KeyEvent.ACTION_DOWN) {
                            if (event.getRepeatCount() == 0) {
                                event.startTracking();
                                return true;
                            } else if (event.isLongPress()) {
                                showAppOptionsDialog(item);
                                return true;
                            }
                        } else if (event.getAction() == KeyEvent.ACTION_UP) {
                            if (!event.isCanceled()) {
                                launchApp(item);
                                return true;
                            }
                        }
                    }
                }
                return false;
            }
        });

        gvApps.setOnItemLongClickListener(new AdapterView.OnItemLongClickListener() {
            @Override
            public boolean onItemLongClick(AdapterView<?> parent, View view, int position, long id) {
                AppItem item = allApps.get(position);
                showAppOptionsDialog(item);
                return true;
            }
        });
    }

    private void updateFavoritesList() {
        favoriteApps.clear();
        for (String pkg : favoritePackages) {
            for (AppItem app : allApps) {
                if (app.packageName.equals(pkg)) {
                    favoriteApps.add(app);
                    break;
                }
            }
        }

        llFavContainer.removeAllViews();
        if (favoriteApps.isEmpty()) {
            layoutFavHeader.setVisibility(View.GONE);
            llFavContainer.setVisibility(View.GONE);
            return;
        }

        layoutFavHeader.setVisibility(View.VISIBLE);
        llFavContainer.setVisibility(View.VISIBLE);

        LayoutInflater inflater = LayoutInflater.from(this);
        for (int i = 0; i < favoriteApps.size(); i++) {
            final int index = i;
            final AppItem fav = favoriteApps.get(i);
            View card = inflater.inflate(R.layout.item_fav_card, llFavContainer, false);

            card.setBackground(createDynamicCardSelector());

            ImageView iv = (ImageView) card.findViewById(R.id.iv_fav_icon);
            TextView tv = (TextView) card.findViewById(R.id.tv_fav_label);

            iv.setImageDrawable(fav.icon);
            tv.setText(fav.label);

            card.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    launchApp(fav);
                }
            });

            card.setOnKeyListener(new View.OnKeyListener() {
                @Override
                public boolean onKey(View v, int keyCode, KeyEvent event) {
                    if (keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER) {
                        if (event.getAction() == KeyEvent.ACTION_DOWN) {
                            if (event.getRepeatCount() == 0) {
                                event.startTracking();
                                return true;
                            } else if (event.isLongPress()) {
                                showFavoriteOptionsDialog(fav, index);
                                return true;
                            }
                        } else if (event.getAction() == KeyEvent.ACTION_UP) {
                            if (!event.isCanceled()) {
                                launchApp(fav);
                                return true;
                            }
                        }
                    }
                    return false;
                }
            });

            card.setOnLongClickListener(new View.OnLongClickListener() {
                @Override
                public boolean onLongClick(View v) {
                    showFavoriteOptionsDialog(fav, index);
                    return true;
                }
            });

            llFavContainer.addView(card);
        }
    }

    private void launchApp(AppItem item) {
        try {
            PackageManager pm = getPackageManager();
            Intent intent = pm.getLeanbackLaunchIntentForPackage(item.packageName);
            if (intent == null) {
                intent = pm.getLaunchIntentForPackage(item.packageName);
            }
            if (intent == null && item.activityName != null && !item.activityName.isEmpty()) {
                intent = new Intent(Intent.ACTION_MAIN);
                intent.setComponent(new ComponentName(item.packageName, item.activityName));
            }
            if (intent != null) {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(intent);
            } else {
                Toast.makeText(this, "Impossibile aprire " + item.label, Toast.LENGTH_SHORT).show();
            }
        } catch (Exception e) {
            Toast.makeText(this, "Errore: " + e.getMessage(), Toast.LENGTH_SHORT).show();
        }
    }

    private class AllAppsAdapter extends BaseAdapter {
        @Override
        public int getCount() {
            return allApps.size();
        }

        @Override
        public Object getItem(int position) {
            return allApps.get(position);
        }

        @Override
        public long getItemId(int position) {
            return position;
        }

        @Override
        public View getView(int position, View convertView, ViewGroup parent) {
            View v = convertView;
            if (v == null) {
                v = LayoutInflater.from(MainActivity.this).inflate(R.layout.item_app_card, parent, false);
            }

            v.setBackground(createDynamicCardSelector());

            AppItem item = allApps.get(position);
            ImageView iv = (ImageView) v.findViewById(R.id.iv_app_icon);
            TextView tv = (TextView) v.findViewById(R.id.tv_app_label);

            iv.setImageDrawable(item.icon);
            tv.setText(item.label);

            return v;
        }
    }
}
