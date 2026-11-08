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
import android.widget.Button;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
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
import java.util.Locale;
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
    private static final String KEY_SHOW_SYSTEM_APPS = "pref_show_system_apps";

    private static final int SECTION_FAVORITES = 1;
    private static final int SECTION_STREAMING = 2;
    private static final int SECTION_ALL_APPS = 3;

    // Theme Palettes
    private static final int[] BG_COLORS = {
        0xFF0A0B10, // 0: Midnight Dark (Default)
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
        0xFFF59E0B, // 0: Oro AKAI (#F59E0B) - WCAG AAA 13.3:1
        0xFF00E5FF, // 1: Ciano Neon (#00E5FF)
        0xFFE50914, // 2: Rosso AKAI (#E50914)
        0xFF10B981  // 3: Smeraldo (#10B981)
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

    // Filtro applicazioni tecniche e diagnostiche OEM da nascondere di default
    private static final String[] SYSTEM_FILTER_PACKAGES = {
        "it.akai.customhome",
        "it.akai.customremote",
        "com.airoha.",
        "com.cultraview.",
        "com.mediatek.wwtv.factory",
        "com.mediatek.TimeMeasurementAgent",
        "com.android.traceur",
        "com.mediatek.engineermode",
        "com.mediatek.ygps",
        "com.mediatek.factorymode",
        "com.mstar.android.video"
    };

    private static final String[] SYSTEM_FILTER_LABELS = {
        "a2dpsinkplayer",
        "boot video",
        "cultraview",
        "factory menu",
        "engineermode",
        "factorymode",
        "open_launch"
    };

    // Keyword per identificare app di streaming e cinema
    private static final String[] STREAMING_PACKAGE_KEYWORDS = {
        "youtube", "netflix", "amazonvideo", "primevideo", "raiplay", "it.rai",
        "mediaset", "disney", "spotify", "kodi", "vlc", "pluto", "dazn",
        "timvision", "discovery", "crunchyroll", "twitch", "appletv", "paramount", "nowtv"
    };

    private static final String[] STREAMING_LABEL_KEYWORDS = {
        "youtube", "netflix", "prime video", "raiplay", "mediaset", "infinity",
        "disney", "spotify", "kodi", "vlc", "pluto tv", "dazn", "timvision",
        "discovery", "crunchyroll", "twitch", "apple tv", "paramount", "now tv"
    };

    // Layout Containers
    private LinearLayout layoutMainRoot;
    private ScrollView scrollMainBody;
    private LinearLayout layoutSectionsContainer;
    private LinearLayout sectionInputsContainer;
    private LinearLayout sectionFavoritesContainer;
    private LinearLayout sectionStreamingContainer;
    private LinearLayout sectionAllAppsContainer;

    // Headers & Buttons
    private TextView tvTitleInputs;
    private TextView tvTitleFavorites;
    private TextView tvTitleStreaming;
    private TextView tvTitleAllApps;
    private Button btnWifi;
    private Button btnFavReorder;
    private Button btnTheme;
    private Button btnHomeRemote;
    private Button btnHomeSettings;

    // Horizontal Row Containers
    private LinearLayout llInputsContainer;
    private LinearLayout llFavContainer;
    private LinearLayout llStreamingContainer;
    private LinearLayout llAllAppsContainer;

    private View layoutFavHeader;
    private View layoutStreamingHeader;
    private View layoutAllAppsHeader;
    private HorizontalScrollView scrollFavs;
    private HorizontalScrollView scrollStreaming;
    private HorizontalScrollView scrollAllApps;

    // Data lists
    private final List<AppItem> allApps = new ArrayList<AppItem>();
    private final List<AppItem> favoriteApps = new ArrayList<AppItem>();
    private final List<AppItem> streamingApps = new ArrayList<AppItem>();
    private final List<String> favoritePackages = new ArrayList<String>();
    private SharedPreferences prefs;

    private int currentBgIndex = 0;
    private int currentAccentIndex = 0;
    private int currentLayoutOrder = 0; // 0: Ingressi prima, 1: Preferiti prima
    private boolean showSystemApps = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        loadPreferences();

        layoutMainRoot = (LinearLayout) findViewById(R.id.layout_main_root);
        scrollMainBody = (ScrollView) findViewById(R.id.scroll_main_body);
        layoutSectionsContainer = (LinearLayout) findViewById(R.id.layout_sections_container);

        sectionInputsContainer = (LinearLayout) findViewById(R.id.section_inputs_container);
        sectionFavoritesContainer = (LinearLayout) findViewById(R.id.section_favorites_container);
        sectionStreamingContainer = (LinearLayout) findViewById(R.id.section_streaming_container);
        sectionAllAppsContainer = (LinearLayout) findViewById(R.id.section_all_apps_container);

        tvTitleInputs = (TextView) findViewById(R.id.tv_title_inputs);
        tvTitleFavorites = (TextView) findViewById(R.id.tv_title_favorites);
        tvTitleStreaming = (TextView) findViewById(R.id.tv_title_streaming);
        tvTitleAllApps = (TextView) findViewById(R.id.tv_title_all_apps);

        btnWifi = (Button) findViewById(R.id.btn_home_wifi);
        btnFavReorder = (Button) findViewById(R.id.btn_fav_reorder);
        btnTheme = (Button) findViewById(R.id.btn_home_theme);
        btnHomeRemote = (Button) findViewById(R.id.btn_home_remote);
        btnHomeSettings = (Button) findViewById(R.id.btn_home_settings);

        llInputsContainer = (LinearLayout) findViewById(R.id.ll_inputs_container);
        llFavContainer = (LinearLayout) findViewById(R.id.ll_fav_container);
        llStreamingContainer = (LinearLayout) findViewById(R.id.ll_streaming_container);
        llAllAppsContainer = (LinearLayout) findViewById(R.id.ll_all_apps_container);

        layoutFavHeader = findViewById(R.id.layout_fav_header);
        layoutStreamingHeader = findViewById(R.id.layout_streaming_header);
        layoutAllAppsHeader = findViewById(R.id.layout_all_apps_header);

        scrollFavs = (HorizontalScrollView) findViewById(R.id.scroll_favs);
        scrollStreaming = (HorizontalScrollView) findViewById(R.id.scroll_streaming);
        scrollAllApps = (HorizontalScrollView) findViewById(R.id.scroll_all_apps);

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
        Toast.makeText(this, "Premi HOME sul telecomando per la schermata principale", Toast.LENGTH_SHORT).show();
    }

    private void loadPreferences() {
        currentBgIndex = prefs.getInt(KEY_THEME_BG, 0);
        if (currentBgIndex < 0 || currentBgIndex >= BG_COLORS.length) currentBgIndex = 0;

        currentAccentIndex = prefs.getInt(KEY_THEME_ACCENT, 0);
        if (currentAccentIndex < 0 || currentAccentIndex >= ACCENT_COLORS.length) currentAccentIndex = 0;

        currentLayoutOrder = prefs.getInt(KEY_LAYOUT_ORDER, 0);
        showSystemApps = prefs.getBoolean(KEY_SHOW_SYSTEM_APPS, false);

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
                favoritePackages.add("it.mediaset.infinitytv");
                favoritePackages.add("com.disney.disneyplus");
            }
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
        editor.putBoolean(KEY_SHOW_SYSTEM_APPS, showSystemApps);
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
        updateStreamingList();
        updateAllAppsList();
    }

    private void applySectionOrder(boolean favsFirst) {
        if (layoutSectionsContainer == null || sectionInputsContainer == null || sectionFavoritesContainer == null) return;
        layoutSectionsContainer.removeView(sectionInputsContainer);
        layoutSectionsContainer.removeView(sectionFavoritesContainer);

        if (favsFirst) {
            layoutSectionsContainer.addView(sectionFavoritesContainer, 0);
            layoutSectionsContainer.addView(sectionInputsContainer, 1);
        } else {
            layoutSectionsContainer.addView(sectionInputsContainer, 0);
            layoutSectionsContainer.addView(sectionFavoritesContainer, 1);
        }
    }

    private StateListDrawable createDynamicCardSelector() {
        float density = getResources().getDisplayMetrics().density;
        int cornerPx = (int) (14 * density);
        int strokeWidthPx = (int) (3.5f * density);

        int normalBg = SURFACE_COLORS[currentBgIndex];
        int focusedBg = FOCUSED_SURFACE_COLORS[currentBgIndex];
        int accent = ACCENT_COLORS[currentAccentIndex];

        StateListDrawable sld = new StateListDrawable();

        // Focused state (bordo evidente con contrasto elevato WCAG AAA)
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
        if (btnWifi != null) {
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
            attachFocusScale(btnWifi, 1.05f);
        }

        if (btnHomeRemote != null) {
            btnHomeRemote.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    launchRemotePairing();
                }
            });
            attachFocusScale(btnHomeRemote, 1.05f);
        }

        if (btnTheme != null) {
            btnTheme.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    showThemeDialog();
                }
            });
            attachFocusScale(btnTheme, 1.05f);
        }

        if (btnHomeSettings != null) {
            btnHomeSettings.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    launchSettings();
                }
            });
            attachFocusScale(btnHomeSettings, 1.05f);
        }

        if (btnFavReorder != null) {
            btnFavReorder.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    showReorderAllDialog();
                }
            });
            attachFocusScale(btnFavReorder, 1.05f);
        }

        updateWifiStatus();
    }

    private void showThemeDialog() {
        AlertDialog.Builder builder = new AlertDialog.Builder(this, android.R.style.Theme_DeviceDefault_Dialog_Alert);
        builder.setTitle("🎨 Personalizzazione AKAI Home v8 Leanback");

        String[] options = {
            "🎨 Scegli Sfondo (" + BG_NAMES[currentBgIndex] + ")",
            "✨ Colore Evidenziazione Focus (" + ACCENT_NAMES[currentAccentIndex] + ")",
            "📐 Disposizione Sezioni (" + (currentLayoutOrder == 0 ? "Ingressi prima" : "Preferiti prima") + ")",
            "🛠️ App Tecniche OEM: " + (showSystemApps ? "Visibili" : "Nascoste (Consigliato)"),
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
                    showSystemApps = !showSystemApps;
                    saveThemePreferences();
                    loadInstalledApps();
                    Toast.makeText(MainActivity.this, "App tecniche: " + (showSystemApps ? "Visibili" : "Nascoste"), Toast.LENGTH_SHORT).show();
                } else if (which == 4) {
                    currentBgIndex = 0;
                    currentAccentIndex = 0;
                    currentLayoutOrder = 0;
                    showSystemApps = false;
                    saveThemePreferences();
                    loadInstalledApps();
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
        builder.setTitle("✨ Scegli Colore Evidenziazione Focus (WCAG AAA)");

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
                Toast.makeText(MainActivity.this, "AKAI Remote headless in esecuzione", Toast.LENGTH_SHORT).show();
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
        return "";
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
            if (ip != null && !ip.isEmpty()) {
                btnWifi.setText("📶 " + ssid + " (" + ip + ")");
            } else {
                btnWifi.setText("📶 " + ssid);
            }
        } catch (Exception e) {
            btnWifi.setText("📶 Rete");
        }
    }

    private void setupHardwareInputs() {
        Button btnDtv = (Button) findViewById(R.id.btn_src_dtv);
        if (btnDtv != null) {
            btnDtv.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    launchDtv();
                }
            });
            attachFocusScale(btnDtv, 1.05f);
            btnDtv.requestFocus();
        }

        Button btnHdmi1 = (Button) findViewById(R.id.btn_src_hdmi1);
        if (btnHdmi1 != null) {
            btnHdmi1.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    launchHdmiInput("HW6", "Fire TV (HDMI 1)");
                }
            });
            attachFocusScale(btnHdmi1, 1.05f);
        }

        Button btnHdmi2 = (Button) findViewById(R.id.btn_src_hdmi2);
        if (btnHdmi2 != null) {
            btnHdmi2.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    launchHdmiInput("HW7", "HDMI 2");
                }
            });
            attachFocusScale(btnHdmi2, 1.05f);
        }

        Button btnHdmi3 = (Button) findViewById(R.id.btn_src_hdmi3);
        if (btnHdmi3 != null) {
            btnHdmi3.setOnClickListener(new View.OnClickListener() {
                @Override
                public void onClick(View v) {
                    launchHdmiInput("HW8", "HDMI 3");
                }
            });
            attachFocusScale(btnHdmi3, 1.05f);
        }

        Button btnAll = (Button) findViewById(R.id.btn_src_all);
        if (btnAll != null) {
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
            attachFocusScale(btnAll, 1.05f);
        }
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

    private boolean isSystemOrTechnicalApp(ResolveInfo ri, PackageManager pm) {
        String pkg = ri.activityInfo.packageName != null ? ri.activityInfo.packageName.toLowerCase(Locale.ROOT) : "";
        String act = ri.activityInfo.name != null ? ri.activityInfo.name.toLowerCase(Locale.ROOT) : "";
        String label = "";
        try {
            CharSequence cs = ri.loadLabel(pm);
            if (cs != null) label = cs.toString().toLowerCase(Locale.ROOT);
        } catch (Exception ignored) {}

        for (String p : SYSTEM_FILTER_PACKAGES) {
            if (pkg.equals(p.toLowerCase(Locale.ROOT)) || pkg.startsWith(p.toLowerCase(Locale.ROOT))) {
                return true;
            }
        }

        for (String l : SYSTEM_FILTER_LABELS) {
            if (act.contains(l) || label.contains(l)) {
                return true;
            }
        }
        return false;
    }

    private boolean isStreamingApp(AppItem item) {
        String pkg = item.packageName != null ? item.packageName.toLowerCase(Locale.ROOT) : "";
        String label = item.label != null ? item.label.toLowerCase(Locale.ROOT) : "";

        for (String kw : STREAMING_PACKAGE_KEYWORDS) {
            if (pkg.contains(kw)) return true;
        }
        for (String kw : STREAMING_LABEL_KEYWORDS) {
            if (label.contains(kw)) return true;
        }
        return false;
    }

    private void loadInstalledApps() {
        PackageManager pm = getPackageManager();
        Set<String> seen = new HashSet<String>();
        allApps.clear();
        streamingApps.clear();

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

            // Filtro app tecniche e OEM di fabbrica se non abilitate esplicitamente
            if (!showSystemApps && isSystemOrTechnicalApp(ri, pm)) {
                continue;
            }

            if (!seen.contains(pkg)) {
                seen.add(pkg);
                String label = ri.loadLabel(pm).toString();
                if (label == null || label.trim().isEmpty()) {
                    label = pkg;
                }
                Drawable icon = ri.loadIcon(pm);
                AppItem item = new AppItem(label, pkg, act, icon);
                allApps.add(item);
                if (isStreamingApp(item)) {
                    streamingApps.add(item);
                }
            }
        }

        Collections.sort(allApps);
        Collections.sort(streamingApps);

        updateFavoritesList();
        updateStreamingList();
        updateAllAppsList();
    }

    private void attachFocusScale(final View view, final float scale) {
        view.setOnFocusChangeListener(new View.OnFocusChangeListener() {
            @Override
            public void onFocusChange(View v, boolean hasFocus) {
                if (hasFocus) {
                    v.animate().scaleX(scale).scaleY(scale).setDuration(120).start();
                } else {
                    v.animate().scaleX(1.0f).scaleY(1.0f).setDuration(120).start();
                }
            }
        });
    }

    private View createCardView(ViewGroup parent, final AppItem item, final int sectionType, final int index) {
        LayoutInflater inflater = LayoutInflater.from(this);
        View card = inflater.inflate(R.layout.item_leanback_card, parent, false);
        card.setBackground(createDynamicCardSelector());

        ImageView iv = (ImageView) card.findViewById(R.id.iv_card_icon);
        TextView tv = (TextView) card.findViewById(R.id.tv_card_label);

        if (iv != null) iv.setImageDrawable(item.icon);
        if (tv != null) tv.setText(item.label);

        attachFocusScale(card, 1.08f);

        card.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                launchApp(item);
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
                            if (sectionType == SECTION_FAVORITES) {
                                showFavoriteOptionsDialog(item, index);
                            } else {
                                showAppOptionsDialog(item);
                            }
                            return true;
                        }
                    } else if (event.getAction() == KeyEvent.ACTION_UP) {
                        if (!event.isCanceled()) {
                            launchApp(item);
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
                if (sectionType == SECTION_FAVORITES) {
                    showFavoriteOptionsDialog(item, index);
                } else {
                    showAppOptionsDialog(item);
                }
                return true;
            }
        });

        return card;
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

        if (llFavContainer == null) return;
        llFavContainer.removeAllViews();

        if (favoriteApps.isEmpty()) {
            if (layoutFavHeader != null) layoutFavHeader.setVisibility(View.GONE);
            if (scrollFavs != null) scrollFavs.setVisibility(View.GONE);
            return;
        }

        if (layoutFavHeader != null) layoutFavHeader.setVisibility(View.VISIBLE);
        if (scrollFavs != null) scrollFavs.setVisibility(View.VISIBLE);

        for (int i = 0; i < favoriteApps.size(); i++) {
            AppItem fav = favoriteApps.get(i);
            View card = createCardView(llFavContainer, fav, SECTION_FAVORITES, i);
            llFavContainer.addView(card);
        }
    }

    private void updateStreamingList() {
        if (llStreamingContainer == null) return;
        llStreamingContainer.removeAllViews();

        if (streamingApps.isEmpty()) {
            if (layoutStreamingHeader != null) layoutStreamingHeader.setVisibility(View.GONE);
            if (scrollStreaming != null) scrollStreaming.setVisibility(View.GONE);
            return;
        }

        if (layoutStreamingHeader != null) layoutStreamingHeader.setVisibility(View.VISIBLE);
        if (scrollStreaming != null) scrollStreaming.setVisibility(View.VISIBLE);

        for (int i = 0; i < streamingApps.size(); i++) {
            AppItem item = streamingApps.get(i);
            View card = createCardView(llStreamingContainer, item, SECTION_STREAMING, i);
            llStreamingContainer.addView(card);
        }
    }

    private void updateAllAppsList() {
        if (llAllAppsContainer == null) return;
        llAllAppsContainer.removeAllViews();

        if (allApps.isEmpty()) {
            if (layoutAllAppsHeader != null) layoutAllAppsHeader.setVisibility(View.GONE);
            if (scrollAllApps != null) scrollAllApps.setVisibility(View.GONE);
            return;
        }

        if (layoutAllAppsHeader != null) layoutAllAppsHeader.setVisibility(View.VISIBLE);
        if (scrollAllApps != null) scrollAllApps.setVisibility(View.VISIBLE);

        for (int i = 0; i < allApps.size(); i++) {
            AppItem item = allApps.get(i);
            View card = createCardView(llAllAppsContainer, item, SECTION_ALL_APPS, i);
            llAllAppsContainer.addView(card);
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
}
