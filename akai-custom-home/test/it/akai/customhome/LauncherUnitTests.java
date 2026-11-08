package it.akai.customhome;

import android.view.KeyEvent;
import android.view.View;
import android.content.SharedPreferences;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.HashMap;
import java.util.Set;
import java.util.HashSet;

public class LauncherUnitTests {

    private static int testsRun = 0;
    private static int testsPassed = 0;

    private static void assertEquals(String message, Object expected, Object actual) {
        testsRun++;
        if (expected == null && actual == null) {
            testsPassed++;
            System.out.println("  [PASS] " + message);
            return;
        }
        if (expected != null && expected.equals(actual)) {
            testsPassed++;
            System.out.println("  [PASS] " + message);
        } else {
            System.err.println("  [FAIL] " + message + " - Atteso: <" + expected + ">, Ottenuto: <" + actual + ">");
            throw new AssertionError(message);
        }
    }

    private static void assertTrue(String message, boolean condition) {
        assertEquals(message, true, condition);
    }

    private static void assertFalse(String message, boolean condition) {
        assertEquals(message, false, condition);
    }

    // Mock SharedPreferences in memoria per test di persistenza
    public static class MockSharedPreferences implements SharedPreferences {
        public final Map<String, Object> data = new HashMap<String, Object>();

        public void put(String k, Object v) { data.put(k, v); }

        @Override public String getString(String k, String d) { Object v = data.get(k); return (v instanceof String) ? (String) v : d; }
        @Override public Set<String> getStringSet(String k, Set<String> d) { Object v = data.get(k); return (v instanceof Set) ? (Set<String>) v : d; }
        @Override public int getInt(String k, int d) { Object v = data.get(k); return (v instanceof Integer) ? (Integer) v : d; }
        @Override public boolean getBoolean(String k, boolean d) { Object v = data.get(k); return (v instanceof Boolean) ? (Boolean) v : d; }
        @Override public boolean contains(String k) { return data.containsKey(k); }

        @Override
        public Editor edit() {
            return new Editor() {
                public Editor putString(String k, String v) { data.put(k, v); return this; }
                public Editor putStringSet(String k, Set<String> v) { data.put(k, v); return this; }
                public Editor putInt(String k, int v) { data.put(k, v); return this; }
                public Editor putBoolean(String k, boolean v) { data.put(k, v); return this; }
                public void apply() {}
            };
        }
    }

    // Mock Activity Harness per intercettare chiamate D-Pad, dialoghi e lifecycle
    public static class MockActivityHarness extends MainActivity {
        int launchAppCalls = 0;
        int showFavDialogCalls = 0;
        int showAppDialogCalls = 0;
        AppItem lastLaunchedItem = null;
        public final MockSharedPreferences mockPrefs = new MockSharedPreferences();

        public MockActivityHarness() {
            // Inizializza lista preferiti vuota
        }

        public List<String> getFavoritePackagesList() {
            // Espone la lista interna per verifica
            try {
                java.lang.reflect.Field field = MainActivity.class.getDeclaredField("favoritePackages");
                field.setAccessible(true);
                return (List<String>) field.get(this);
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }

        public void invokeLoadPreferences() {
            try {
                java.lang.reflect.Field prefsField = MainActivity.class.getDeclaredField("prefs");
                prefsField.setAccessible(true);
                prefsField.set(this, mockPrefs);

                java.lang.reflect.Method method = MainActivity.class.getDeclaredMethod("loadPreferences");
                method.setAccessible(true);
                method.invoke(this);
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }

        public void invokeSaveFavoritePreferences() {
            try {
                java.lang.reflect.Field prefsField = MainActivity.class.getDeclaredField("prefs");
                prefsField.setAccessible(true);
                prefsField.set(this, mockPrefs);

                java.lang.reflect.Method method = MainActivity.class.getDeclaredMethod("saveFavoritePreferences");
                method.setAccessible(true);
                method.invoke(this);
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }

        @Override
        public void launchApp(AppItem item) {
            launchAppCalls++;
            lastLaunchedItem = item;
        }

        @Override
        public void showFavoriteOptionsDialog(AppItem fav, int index) {
            showFavDialogCalls++;
        }

        @Override
        public void showAppOptionsDialog(AppItem item) {
            showAppDialogCalls++;
        }
    }

    // -------------------------------------------------------------------------
    // TEST SUITE D-PAD KEY HANDLING & P0 REGRESSION
    // -------------------------------------------------------------------------

    public static void testP0ShortPressLaunchesApp() {
        System.out.println("\nTest 1.1: Sequenza D-Pad Pressione Breve (OK / CENTER) -> Avvio App");
        MockActivityHarness harness = new MockActivityHarness();
        MainActivity.AppItem testItem = new MainActivity.AppItem("YouTube TV", "com.google.android.youtube.tv", "MainActivity", null);
        MainActivity.CardKeyHandler handler = new MainActivity.CardKeyHandler(harness, testItem, MainActivity.SECTION_STREAMING, 0);
        View mockView = new View();

        KeyEvent downEvent = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 0);
        boolean downResult = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, downEvent);
        assertTrue("DOWN deve essere consumato (return true)", downResult);
        assertEquals("Nessun lancio dell'app durante il DOWN", 0, harness.launchAppCalls);
        assertEquals("Nessun dialogo durante il DOWN breve", 0, harness.showAppDialogCalls);
        assertTrue("downReceived deve essere true", handler.isDownReceived());
        assertFalse("longPressHandled deve essere false", handler.isLongPressHandled());

        KeyEvent upEvent = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_CENTER, 0);
        boolean upResult = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, upEvent);
        assertTrue("UP deve essere consumato (return true)", upResult);
        assertEquals("L'app deve essere lanciata esattamente 1 volta al rilascio", 1, harness.launchAppCalls);
        assertEquals("Nessun dialogo aperto", 0, harness.showAppDialogCalls);
        assertEquals("L'app lanciata deve essere YouTube TV", "com.google.android.youtube.tv", harness.lastLaunchedItem.packageName);
        assertFalse("downReceived resettato dopo UP", handler.isDownReceived());
    }

    public static void testP0LongPressOpensDialogAndPreventsAppLaunch() {
        System.out.println("\nTest 1.2: Sequenza D-Pad Pressione Prolungata (P0) -> Apre Dialogo ed ELIMINA Lancio App");
        MockActivityHarness harness = new MockActivityHarness();
        MainActivity.AppItem testItem = new MainActivity.AppItem("RaiPlay", "it.rainet.androidtv", "RaiPlayActivity", null);
        MainActivity.CardKeyHandler handler = new MainActivity.CardKeyHandler(harness, testItem, MainActivity.SECTION_FAVORITES, 2);
        View mockView = new View();

        KeyEvent down0 = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 0);
        handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, down0);

        KeyEvent downLong = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 1, true, false);
        boolean downLongResult = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, downLong);
        assertTrue("DOWN LongPress deve essere consumato", downLongResult);
        assertEquals("Dialogo opzioni preferiti aperto esattamente 1 volta", 1, harness.showFavDialogCalls);
        assertEquals("Nessun avvio app durante long press", 0, harness.launchAppCalls);
        assertTrue("longPressHandled deve essere true", handler.isLongPressHandled());

        KeyEvent upAfterLong = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_CENTER, 0);
        boolean upResult = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, upAfterLong);
        assertTrue("UP dopo long press deve essere consumato per non propagarsi", upResult);

        // VERIFICA CRITICA P0: ZERO AVVII DELL'APP AL RILASCIO!
        assertEquals("ZERO lanci dell'app al rilascio dopo long press (P0 Risolto!)", 0, harness.launchAppCalls);
        assertEquals("Dialoghi aperti rimangono 1", 1, harness.showFavDialogCalls);
        assertFalse("longPressHandled deve essere resettato a false per eventi successivi", handler.isLongPressHandled());
        assertFalse("downReceived deve essere resettato a false", handler.isDownReceived());
    }

    public static void testP0EnterKeyEquivalence() {
        System.out.println("\nTest 1.3: Equivalenza KeyEvent.KEYCODE_ENTER con DPAD_CENTER");
        MockActivityHarness harness = new MockActivityHarness();
        MainActivity.AppItem testItem = new MainActivity.AppItem("Netflix", "com.netflix.ninja", "MainActivity", null);
        MainActivity.CardKeyHandler handler = new MainActivity.CardKeyHandler(harness, testItem, MainActivity.SECTION_STREAMING, 0);
        View mockView = new View();

        KeyEvent down = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER, 0);
        KeyEvent up = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER, 0);
        handler.onKey(mockView, KeyEvent.KEYCODE_ENTER, down);
        handler.onKey(mockView, KeyEvent.KEYCODE_ENTER, up);
        assertEquals("KEYCODE_ENTER deve avviare l'app regolarmente", 1, harness.launchAppCalls);
    }

    public static void testP0CanceledEventDoesNotLaunch() {
        System.out.println("\nTest 1.4: Evento Canceled non deve avviare l'app");
        MockActivityHarness harness = new MockActivityHarness();
        MainActivity.AppItem testItem = new MainActivity.AppItem("Spotify", "com.spotify.tv.android", "MainActivity", null);
        MainActivity.CardKeyHandler handler = new MainActivity.CardKeyHandler(harness, testItem, MainActivity.SECTION_STREAMING, 0);
        View mockView = new View();

        KeyEvent down = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 0);
        KeyEvent upCanceled = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_CENTER, 0, false, true);
        handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, down);
        handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, upCanceled);
        assertEquals("Evento cancellato non deve avviare alcuna app", 0, harness.launchAppCalls);
    }

    public static void testOrphanedUpEventDoesNotLaunchApp() {
        System.out.println("\nTest 1.5: Evento ACTION_UP Orfano (senza previo DOWN) -> Ignora e Previene Avvio App");
        MockActivityHarness harness = new MockActivityHarness();
        MainActivity.AppItem testItem = new MainActivity.AppItem("Kodi", "org.xbmc.kodi", "MainActivity", null);
        MainActivity.CardKeyHandler handler = new MainActivity.CardKeyHandler(harness, testItem, MainActivity.SECTION_STREAMING, 0);
        View mockView = new View();

        // Invio diretto di ACTION_UP senza ACTION_DOWN (es. cambio rapido focus o evento orfano)
        KeyEvent orphanedUp = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_CENTER, 0);
        boolean handled = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, orphanedUp);
        assertTrue("UP orfano deve essere consumato", handled);
        assertEquals("ZERO lanci app su evento UP orfano", 0, harness.launchAppCalls);
        assertEquals("ZERO dialoghi aperti", 0, harness.showAppDialogCalls);
        assertFalse("downReceived deve restare false", handler.isDownReceived());
    }

    public static void testRepeatedDownOnlyTriggersDialogOnceAndConsumesRepeats() {
        System.out.println("\nTest 1.6: Ripetizioni Multiple ACTION_DOWN Long Press -> Apre Dialogo 1 Sola Volta e Consuma Repeat");
        MockActivityHarness harness = new MockActivityHarness();
        MainActivity.AppItem testItem = new MainActivity.AppItem("Disney+", "com.disney.disneyplus", "MainActivity", null);
        MainActivity.CardKeyHandler handler = new MainActivity.CardKeyHandler(harness, testItem, MainActivity.SECTION_FAVORITES, 1);
        View mockView = new View();

        // 1. Initial DOWN repeat 0
        handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 0));

        // 2. DOWN repeat 1 (scatta long press)
        KeyEvent longPress1 = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 1, true, false);
        boolean r1 = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, longPress1);
        assertTrue("Primo repeat long-press deve essere consumato", r1);
        assertEquals("Dialogo aperto 1 sola volta", 1, harness.showFavDialogCalls);

        // 3. DOWN repeat 2 e repeat 3 (l'utente tiene ancora premuto il tasto)
        KeyEvent longPress2 = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 2, true, false);
        boolean r2 = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, longPress2);
        assertTrue("Secondo repeat long-press deve essere consumato", r2);
        assertEquals("Dialogo NON deve essere riaperto al repeat 2", 1, harness.showFavDialogCalls);

        KeyEvent longPress3 = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 3, true, false);
        boolean r3 = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, longPress3);
        assertTrue("Terzo repeat long-press deve essere consumato", r3);
        assertEquals("Dialogo NON deve essere riaperto al repeat 3", 1, harness.showFavDialogCalls);

        // 4. ACTION_UP finale
        handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_CENTER, 0));
        assertEquals("ZERO lanci app dopo sequenza di repeat consumati", 0, harness.launchAppCalls);
        assertFalse("longPressHandled resettato a false", handler.isLongPressHandled());
    }

    public static void testFocusLossResetsCardKeyHandler() {
        System.out.println("\nTest 1.7: Perdita di Focus -> Reset Deterministico dello Stato Tasti");
        MockActivityHarness harness = new MockActivityHarness();
        MainActivity.AppItem testItem = new MainActivity.AppItem("Prime Video", "com.amazon.amazonvideo.livingroom", "MainActivity", null);
        MainActivity.CardKeyHandler handler = new MainActivity.CardKeyHandler(harness, testItem, MainActivity.SECTION_STREAMING, 0);
        View mockView = new View();

        // DOWN iniziato
        handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 0));
        assertTrue("downReceived deve essere true", handler.isDownReceived());

        // La card perde il focus (es. scorrimento o animazione)
        handler.reset();
        assertFalse("downReceived resettato dopo perdita focus", handler.isDownReceived());
        assertFalse("longPressHandled resettato dopo perdita focus", handler.isLongPressHandled());

        // Un UP successivo non deve lanciare l'app
        handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_CENTER, 0));
        assertEquals("ZERO lanci app dopo reset da focus loss", 0, harness.launchAppCalls);
    }

    // -------------------------------------------------------------------------
    // TEST PREFERITI VUOTI E REGRESSIONE OEM (P0 & P1)
    // -------------------------------------------------------------------------

    public static void testEmptyFavoritesPersistenceAcrossReboot() {
        System.out.println("\nTest 2.1: Persistenza Stato 'Nessun Preferito' al Riavvio (P1 Risolto)");
        MockActivityHarness harness = new MockActivityHarness();

        // L'utente ha rimosso intenzionalmente tutti i preferiti: salvata stringa vuota
        harness.mockPrefs.put("user_favorites_ordered", "");
        assertTrue("Chiave user_favorites_ordered presente nelle SharedPreferences", harness.mockPrefs.contains("user_favorites_ordered"));

        harness.invokeLoadPreferences();
        List<String> favs = harness.getFavoritePackagesList();
        assertEquals("La lista preferiti DEVE rimanere vuota e NON ripopolarsi con i default", 0, favs.size());
    }

    public static void testFirstRunSeedsDefaultFavorites() {
        System.out.println("\nTest 2.2: Primo Avvio Assoluto -> Inizializzazione 4 App Predefinite");
        MockActivityHarness harness = new MockActivityHarness();

        // Nessuna preferenza salvata (primo avvio)
        assertFalse("Nessuna chiave salvata", harness.mockPrefs.contains("user_favorites_ordered"));
        assertFalse("Nessun legacy salvato", harness.mockPrefs.contains("user_favorites"));

        harness.invokeLoadPreferences();
        List<String> favs = harness.getFavoritePackagesList();
        assertEquals("Primo avvio deve inizializzare 4 preferiti", 4, favs.size());
        assertEquals("Primo preferito deve essere YouTube TV", "com.google.android.youtube.tv", favs.get(0));
        assertEquals("Secondo preferito deve essere RaiPlay", "it.rainet.androidtv", favs.get(1));
        assertEquals("Terzo preferito deve essere Infinity+", "it.mediaset.infinitytv", favs.get(2));
        assertEquals("Quarto preferito deve essere Disney+", "com.disney.disneyplus", favs.get(3));
    }

    public static void testOemTechnicalAppInFavoritesPreservedAcrossFilterToggle() {
        System.out.println("\nTest 2.3: App Tecnica OEM nei Preferiti PRESERVATA al Cambio Filtro (P0 Risolto)");
        MockActivityHarness harness = new MockActivityHarness();

        // L'utente aggiunge nei preferiti un'app OEM e un'app utente
        List<String> favs = harness.getFavoritePackagesList();
        favs.add("com.cultraview.launcher");
        favs.add("com.google.android.youtube.tv");
        harness.invokeSaveFavoritePreferences();

        assertEquals("Preferiti salvati: 2 elementi", 2, favs.size());
        assertEquals("Primo elemento: cultraview", "com.cultraview.launcher", favs.get(0));
        assertEquals("Secondo elemento: youtube", "com.google.android.youtube.tv", favs.get(1));

        // Ricarica preferenze con showSystemApps = false (filtro attivo)
        harness.mockPrefs.put("pref_show_system_apps", false);
        harness.invokeLoadPreferences();

        List<String> loadedFavs = harness.getFavoritePackagesList();
        // VERIFICA CRITICA P0: l'app OEM DEVE rimanere in favoritePackages!
        assertEquals("favoritePackages NON deve essere purgato per via del filtro OEM", 2, loadedFavs.size());
        assertTrue("com.cultraview.launcher deve essere ancora presente nei preferiti", loadedFavs.contains("com.cultraview.launcher"));
        assertEquals("Posizione preferito OEM preservata all'indice 0", "com.cultraview.launcher", loadedFavs.get(0));
        assertEquals("Posizione preferito YouTube preservata all'indice 1", "com.google.android.youtube.tv", loadedFavs.get(1));
    }

    // -------------------------------------------------------------------------
    // TEST DIFFING NON DISTRUTTIVO, FOCUS E SCROLL (P1)
    // -------------------------------------------------------------------------

    public static void testAppListsEqualDiffing() {
        System.out.println("\nTest 3.1: Algoritmo di Diffing per Refresh Non Distruttivo");
        List<MainActivity.AppItem> listA = new ArrayList<MainActivity.AppItem>();
        listA.add(new MainActivity.AppItem("App 1", "com.test.app1", "Act1", null));
        listA.add(new MainActivity.AppItem("App 2", "com.test.app2", "Act2", null));

        List<MainActivity.AppItem> listB = new ArrayList<MainActivity.AppItem>();
        listB.add(new MainActivity.AppItem("App 1", "com.test.app1", "Act1", null));
        listB.add(new MainActivity.AppItem("App 2", "com.test.app2", "Act2", null));

        assertTrue("Due liste identiche per package devono risultare uguali (nessun rebuild)", MainActivity.areAppListsEqual(listA, listB));

        List<MainActivity.AppItem> listDifferentOrder = new ArrayList<MainActivity.AppItem>();
        listDifferentOrder.add(new MainActivity.AppItem("App 2", "com.test.app2", "Act2", null));
        listDifferentOrder.add(new MainActivity.AppItem("App 1", "com.test.app1", "Act1", null));
        assertFalse("Liste con ordine diverso devono risultare differenti (rebuild richiesto)", MainActivity.areAppListsEqual(listA, listDifferentOrder));

        List<MainActivity.AppItem> listDifferentSize = new ArrayList<MainActivity.AppItem>();
        listDifferentSize.add(new MainActivity.AppItem("App 1", "com.test.app1", "Act1", null));
        assertFalse("Liste con dimensioni diverse devono risultare differenti", MainActivity.areAppListsEqual(listA, listDifferentSize));
    }

    public static void testCardTagPackageAndSectionAssociation() {
        System.out.println("\nTest 3.2: Tag Card per Ripristino Focus Stabile");
        MainActivity.CardTag tag = new MainActivity.CardTag("com.google.android.youtube.tv", MainActivity.SECTION_STREAMING);
        assertEquals("Package name memorizzato nel tag", "com.google.android.youtube.tv", tag.packageName);
        assertEquals("Section type memorizzato nel tag", MainActivity.SECTION_STREAMING, tag.sectionType);
    }

    // -------------------------------------------------------------------------
    // TEST FILTRO OEM & CATEGORIZZAZIONE STREAMING
    // -------------------------------------------------------------------------

    public static void testOemTechnicalAppsFilter() {
        System.out.println("\nTest 4.1: Filtro / Blacklist Applicazioni Tecniche OEM");

        assertTrue("A2dpSinkPlayer deve essere filtrata",
            MainActivity.isSystemOrTechnicalApp("com.android.bluetooth", "com.android.bluetooth.a2dp.A2dpSinkPlayerActivity", "A2dpSinkPlayer"));
        assertTrue("Boot Video deve essere filtrata",
            MainActivity.isSystemOrTechnicalApp("com.mstar.android.video", "com.mstar.android.video.BootVideoActivity", "Boot Video"));
        assertTrue("Cultraview Launcher deve essere filtrata",
            MainActivity.isSystemOrTechnicalApp("com.cultraview.launcher", "com.cultraview.launcher.CULTRAVIEW_OPEN_LAUNCH_MAIN", "Cultraview Home"));
        assertTrue("Airoha test mode deve essere filtrata",
            MainActivity.isSystemOrTechnicalApp("com.airoha.test", "com.airoha.test.TestActivity", "Airoha Engineer"));
        assertTrue("MediaTek WWTV Factory menu deve essere filtrata",
            MainActivity.isSystemOrTechnicalApp("com.mediatek.wwtv.factory", "com.mediatek.wwtv.factory.FactoryActivity", "Factory Menu"));
        assertTrue("Android Traceur deve essere filtrata",
            MainActivity.isSystemOrTechnicalApp("com.android.traceur", "com.android.traceur.MainActivity", "System Tracing"));

        assertFalse("YouTube TV non deve essere filtrata",
            MainActivity.isSystemOrTechnicalApp("com.google.android.youtube.tv", "com.google.android.youtube.tv.MainActivity", "YouTube TV"));
        assertFalse("RaiPlay non deve essere filtrata",
            MainActivity.isSystemOrTechnicalApp("it.rainet.androidtv", "it.rainet.androidtv.MainActivity", "RaiPlay"));
        assertFalse("Netflix non deve essere filtrata",
            MainActivity.isSystemOrTechnicalApp("com.netflix.ninja", "com.netflix.ninja.MainActivity", "Netflix"));
        assertFalse("Disney+ non deve essere filtrata",
            MainActivity.isSystemOrTechnicalApp("com.disney.disneyplus", "com.disney.disneyplus.MainActivity", "Disney+"));
        assertFalse("Google Play Store non deve essere filtrata",
            MainActivity.isSystemOrTechnicalApp("com.android.vending", "com.android.vending.AssetBrowserActivity", "Google Play Store"));
    }

    public static void testStreamingCategorization() {
        System.out.println("\nTest 4.2: Categorizzazione Sezione STREAMING & CINEMA");

        assertTrue("YouTube è streaming", MainActivity.isStreamingApp("com.google.android.youtube.tv", "YouTube TV"));
        assertTrue("Netflix è streaming", MainActivity.isStreamingApp("com.netflix.ninja", "Netflix"));
        assertTrue("Prime Video è streaming", MainActivity.isStreamingApp("com.amazon.amazonvideo.livingroom", "Prime Video"));
        assertTrue("RaiPlay è streaming", MainActivity.isStreamingApp("it.rainet.androidtv", "RaiPlay"));
        assertTrue("Mediaset Infinity è streaming", MainActivity.isStreamingApp("it.mediaset.infinitytv", "Infinity+"));
        assertTrue("Disney+ è streaming", MainActivity.isStreamingApp("com.disney.disneyplus", "Disney+"));
        assertTrue("Spotify è streaming", MainActivity.isStreamingApp("com.spotify.tv.android", "Spotify"));
        assertTrue("Kodi è streaming", MainActivity.isStreamingApp("org.xbmc.kodi", "Kodi"));
        assertTrue("VLC è streaming", MainActivity.isStreamingApp("org.videolan.vlc", "VLC Player"));
        assertTrue("Pluto TV è streaming", MainActivity.isStreamingApp("tv.pluto.android", "Pluto TV"));

        assertFalse("File Manager non è streaming", MainActivity.isStreamingApp("com.android.documentsui", "File Manager"));
        assertFalse("Calcolatrice non è streaming", MainActivity.isStreamingApp("com.android.calculator2", "Calcolatrice"));
        assertFalse("Settings non è streaming", MainActivity.isStreamingApp("com.android.tv.settings", "Impostazioni TV"));
        assertFalse("Clock non è streaming", MainActivity.isStreamingApp("com.android.deskclock", "Orologio"));
    }

    // -------------------------------------------------------------------------
    // TEST CONTRASTO WCAG AAA (sRGB IEC 61966-2-1)
    // -------------------------------------------------------------------------

    public static void testColorContrastWCAG() {
        System.out.println("\nTest 5: Verifica Matematica Rapporto di Contrasto sRGB (WCAG AAA >= 7.0:1)");

        double lBgMidnight = calculateRelativeLuminance(0x0A, 0x0B, 0x10);
        double lSurfaceSapphire = calculateRelativeLuminance(0x1E, 0x3A, 0x8A);
        double lGoldAccent = calculateRelativeLuminance(0xF5, 0x9E, 0x0B);
        double lCyanAccent = calculateRelativeLuminance(0x00, 0xE5, 0xFF);
        double lTextWhite = calculateRelativeLuminance(0xFF, 0xFF, 0xFF);

        // 1. Testo Bianco su Sfondo Midnight
        double crTextMidnight = (lTextWhite + 0.05) / (lBgMidnight + 0.05);
        System.out.printf("  CR Testo Bianco / Sfondo Midnight: %.2f:1\n", crTextMidnight);
        assertTrue("Testo Bianco su Midnight >= 7.0:1 (WCAG AAA)", crTextMidnight >= 7.0);

        // 2. Bordo Focus Oro su Superficie Sapphire (card attiva)
        double crGoldSapphire = (lGoldAccent + 0.05) / (lSurfaceSapphire + 0.05);
        System.out.printf("  CR Bordo Focus Oro / Superficie Sapphire: %.2f:1\n", crGoldSapphire);
        assertTrue("Focus Oro su Sapphire >= 4.5:1 (Componente UI WCAG AAA)", crGoldSapphire >= 4.5);

        // 3. Focus Ciano su Sfondo Surface Dark
        double crCyanSurface = (lCyanAccent + 0.05) / (lBgMidnight + 0.05);
        System.out.printf("  CR Focus Ciano / Sfondo Midnight: %.2f:1\n", crCyanSurface);
        assertTrue("Focus Ciano su Midnight >= 7.0:1 (WCAG AAA)", crCyanSurface >= 7.0);
    }

    private static double calculateRelativeLuminance(int r, int g, int b) {
        double rs = r / 255.0;
        double gs = g / 255.0;
        double bs = b / 255.0;

        double rLin = (rs <= 0.03928) ? rs / 12.92 : Math.pow((rs + 0.055) / 1.055, 2.4);
        double gLin = (gs <= 0.03928) ? gs / 12.92 : Math.pow((gs + 0.055) / 1.055, 2.4);
        double bLin = (bs <= 0.03928) ? bs / 12.92 : Math.pow((bs + 0.055) / 1.055, 2.4);

        return 0.2126 * rLin + 0.7152 * gLin + 0.0722 * bLin;
    }

    public static void main(String[] args) {
        System.out.println("================================================================");
        System.out.println("  AKAI CUSTOM HOME v8 LEANBACK — SUITE DI TEST UNITARI");
        System.out.println("================================================================");

        try {
            // D-Pad Key Handling & P0
            testP0ShortPressLaunchesApp();
            testP0LongPressOpensDialogAndPreventsAppLaunch();
            testP0EnterKeyEquivalence();
            testP0CanceledEventDoesNotLaunch();
            testOrphanedUpEventDoesNotLaunchApp();
            testRepeatedDownOnlyTriggersDialogOnceAndConsumesRepeats();
            testFocusLossResetsCardKeyHandler();

            // Preferiti & P0 OEM Regression
            testEmptyFavoritesPersistenceAcrossReboot();
            testFirstRunSeedsDefaultFavorites();
            testOemTechnicalAppInFavoritesPreservedAcrossFilterToggle();

            // Diffing e Focus
            testAppListsEqualDiffing();
            testCardTagPackageAndSectionAssociation();

            // OEM Blacklist & Streaming
            testOemTechnicalAppsFilter();
            testStreamingCategorization();

            // WCAG Contrast
            testColorContrastWCAG();

            System.out.println("\n================================================================");
            System.out.println("  RISULTATO FINALE: " + testsPassed + "/" + testsRun + " TEST SUPERATI (100% PASS)");
            System.out.println("================================================================");
            if (testsPassed != testsRun) {
                System.exit(1);
            }
        } catch (Throwable t) {
            System.err.println("\nERRORE DURANTE L'ESECUZIONE DEI TEST:");
            t.printStackTrace();
            System.exit(1);
        }
    }
}
