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

        public List<AppItem> getFavoriteAppsList() {
            try {
                java.lang.reflect.Field field = MainActivity.class.getDeclaredField("favoriteApps");
                field.setAccessible(true);
                return (List<AppItem>) field.get(this);
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }

        public List<AppItem> getAllAppsList() {
            try {
                java.lang.reflect.Field field = MainActivity.class.getDeclaredField("allApps");
                field.setAccessible(true);
                return (List<AppItem>) field.get(this);
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

    public static void testSingleOnKeyListenerWiringWithFocusLoss() {
        System.out.println("\nTest 1.8: Cablaggio Reale View con Singolo OnKeyListener (P0 Risolto)");
        MockActivityHarness harness = new MockActivityHarness();
        MainActivity.AppItem testItem = new MainActivity.AppItem("VLC", "org.videolan.vlc", "MainActivity", null);
        View card = new View();

        final MainActivity.CardKeyHandler keyHandler = new MainActivity.CardKeyHandler(harness, testItem, MainActivity.SECTION_STREAMING, 0);
        card.setOnKeyListener(keyHandler);
        card.setOnFocusChangeListener(new View.OnFocusChangeListener() {
            @Override
            public void onFocusChange(View v, boolean hasFocus) {
                if (!hasFocus) {
                    keyHandler.reset();
                }
            }
        });

        // 1. Simula DOWN sulla View (l'utente preme il tasto)
        boolean downDispatched = card.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 0));
        assertTrue("DOWN deve essere consumato dalla card", downDispatched);
        assertTrue("downReceived deve essere true nel keyHandler associato", keyHandler.isDownReceived());

        // 2. Simula perdita focus della card prima del rilascio
        card.setFocused(false);
        assertFalse("downReceived deve essere resettato a false via onFocusChange", keyHandler.isDownReceived());

        // 3. Simula UP sulla View
        boolean upDispatched = card.dispatchKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_CENTER, 0));
        assertTrue("UP orfano dopo focus loss deve essere consumato", upDispatched);
        assertEquals("ZERO lanci app: il listener associato alla View ha resettato correttamente!", 0, harness.launchAppCalls);
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

    public static void testReorderFavoritesWithHiddenOemApps() {
        System.out.println("\nTest 2.4: Riordino Preferiti con App Tecniche OEM Nascoste (P1 Risolto)");
        MockActivityHarness harness = new MockActivityHarness();
        harness.invokeLoadPreferences();

        // favoritePackages persistenti: 1 OEM nascosta e 2 visibili (YouTube e RaiPlay)
        List<String> favPkgs = harness.getFavoritePackagesList();
        favPkgs.clear();
        favPkgs.add("com.cultraview.launcher"); // OEM nascosta (index 0)
        favPkgs.add("com.google.android.youtube.tv"); // Visibile 1 (vIndex 0)
        favPkgs.add("it.rainet.androidtv"); // Visibile 2 (vIndex 1)

        // favoriteApps visibili: solo YouTube e RaiPlay
        List<MainActivity.AppItem> favApps = harness.getFavoriteAppsList();
        favApps.clear();
        favApps.add(new MainActivity.AppItem("YouTube TV", "com.google.android.youtube.tv", "MainActivity", null));
        favApps.add(new MainActivity.AppItem("RaiPlay", "it.rainet.androidtv", "RaiPlayActivity", null));

        // Popola allApps così che updateFavoritesList() possa ricostruire favoriteApps preservando i dati
        List<MainActivity.AppItem> allAppsList = harness.getAllAppsList();
        allAppsList.clear();
        allAppsList.add(new MainActivity.AppItem("YouTube TV", "com.google.android.youtube.tv", "MainActivity", null));
        allAppsList.add(new MainActivity.AppItem("RaiPlay", "it.rainet.androidtv", "RaiPlayActivity", null));

        // L'utente preme "Sposta a destra" su YouTube
        boolean moveRightSuccess = harness.moveVisibleFavorite("com.google.android.youtube.tv", true);
        assertTrue("Spostamento a destra del preferito visibile riuscito", moveRightSuccess);

        // Verifica che l'OEM nascosta sia rimasta INTATTA all'indice 0, e YouTube/RaiPlay si siano scambiati
        assertEquals("OEM Cultraview DEVE rimanere all'indice 0", "com.cultraview.launcher", favPkgs.get(0));
        assertEquals("RaiPlay ora deve essere all'indice 1", "it.rainet.androidtv", favPkgs.get(1));
        assertEquals("YouTube ora deve essere all'indice 2", "com.google.android.youtube.tv", favPkgs.get(2));

        // Ora l'utente preme "Sposta a sinistra" su YouTube
        boolean moveLeftSuccess = harness.moveVisibleFavorite("com.google.android.youtube.tv", false);
        assertTrue("Spostamento a sinistra del preferito visibile riuscito", moveLeftSuccess);

        assertEquals("OEM Cultraview rimane sempre all'indice 0", "com.cultraview.launcher", favPkgs.get(0));
        assertEquals("YouTube torna all'indice 1", "com.google.android.youtube.tv", favPkgs.get(1));
        assertEquals("RaiPlay torna all'indice 2", "it.rainet.androidtv", favPkgs.get(2));
    }

    // -------------------------------------------------------------------------
    // TEST DIFFING NON DISTRUTTIVO, FOCUS E SCROLL (P1)
    // -------------------------------------------------------------------------

    public static void testAppListsEqualDiffing() {
        System.out.println("\nTest 3.1: Algoritmo di Diffing per Refresh Non Distruttivo e Null-Safety (P1)");
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

        List<MainActivity.AppItem> listDifferentLabel = new ArrayList<MainActivity.AppItem>();
        listDifferentLabel.add(new MainActivity.AppItem("App 1 Nuova", "com.test.app1", "Act1", null));
        listDifferentLabel.add(new MainActivity.AppItem("App 2", "com.test.app2", "Act2", null));
        assertFalse("Liste con etichetta modificata devono risultare differenti (PACKAGE_REPLACED)", MainActivity.areAppListsEqual(listA, listDifferentLabel));

        List<MainActivity.AppItem> listDifferentActivity = new ArrayList<MainActivity.AppItem>();
        listDifferentActivity.add(new MainActivity.AppItem("App 1", "com.test.app1", "NewActivity", null));
        listDifferentActivity.add(new MainActivity.AppItem("App 2", "com.test.app2", "Act2", null));
        assertFalse("Liste con activity name modificata devono risultare differenti", MainActivity.areAppListsEqual(listA, listDifferentActivity));

        // 1. Confronto simmetrico null-safe per activityName e label (Review 4)
        List<MainActivity.AppItem> listNullOldActivity = new ArrayList<MainActivity.AppItem>();
        listNullOldActivity.add(new MainActivity.AppItem("App 1", "com.test.app1", null, null));
        assertFalse("Vecchio record con activityName null vs nuovo non-null deve risultare differente", MainActivity.areAppListsEqual(listNullOldActivity, listA.subList(0, 1)));
        assertFalse("Vecchio record non-null vs nuovo activityName null deve risultare differente", MainActivity.areAppListsEqual(listA.subList(0, 1), listNullOldActivity));

        List<MainActivity.AppItem> listNullOldLabel = new ArrayList<MainActivity.AppItem>();
        listNullOldLabel.add(new MainActivity.AppItem(null, "com.test.app1", "Act1", null));
        assertFalse("Vecchio record con label null vs nuovo non-null deve risultare differente", MainActivity.areAppListsEqual(listNullOldLabel, listA.subList(0, 1)));
        assertFalse("Vecchio record non-null vs nuovo label null deve risultare differente", MainActivity.areAppListsEqual(listA.subList(0, 1), listNullOldLabel));

        List<MainActivity.AppItem> listBothNull = new ArrayList<MainActivity.AppItem>();
        listBothNull.add(new MainActivity.AppItem(null, "com.test.app1", null, null));
        List<MainActivity.AppItem> listBothNull2 = new ArrayList<MainActivity.AppItem>();
        listBothNull2.add(new MainActivity.AppItem(null, "com.test.app1", null, null));
        assertTrue("Entrambi i record con campi null devono risultare uguali", MainActivity.areAppListsEqual(listBothNull, listBothNull2));

        // 2. Prevenzione rebuild spuri e stabilità istanze Drawable (Review 5)
        android.graphics.drawable.Drawable icon1 = new android.graphics.drawable.Drawable();
        android.graphics.drawable.Drawable icon2 = new android.graphics.drawable.Drawable();
        List<MainActivity.AppItem> listIcon1 = new ArrayList<MainActivity.AppItem>();
        listIcon1.add(new MainActivity.AppItem("App 1", "com.test.app1", "Act1", icon1, 1, 1000L));
        List<MainActivity.AppItem> listIcon2 = new ArrayList<MainActivity.AppItem>();
        listIcon2.add(new MainActivity.AppItem("App 1", "com.test.app1", "Act1", icon2, 1, 1000L));
        assertTrue("Istanze distinte di Drawable con metadati e versioni identici NON devono innescare rebuild (Review 5)", MainActivity.areAppListsEqual(listIcon1, listIcon2));

        // Test helper areIconsEqual
        assertFalse("areIconsEqual rileva drawables diversi", MainActivity.areIconsEqual(icon1, icon2));
        assertFalse("areIconsEqual rileva drawable vs null", MainActivity.areIconsEqual(icon1, null));
        assertTrue("areIconsEqual riconosce medesima istanza", MainActivity.areIconsEqual(icon1, icon1));

        // 3. Rilevazione aggiornamento app tramite versionCode e lastUpdateTime (Review 4)
        List<MainActivity.AppItem> listV1 = new ArrayList<MainActivity.AppItem>();
        listV1.add(new MainActivity.AppItem("App 1", "com.test.app1", "Act1", icon1, 1, 1000L));
        List<MainActivity.AppItem> listV2 = new ArrayList<MainActivity.AppItem>();
        listV2.add(new MainActivity.AppItem("App 1", "com.test.app1", "Act1", icon1, 2, 1000L));
        assertFalse("Variazione di versionCode deve essere rilevata come aggiornamento", MainActivity.areAppListsEqual(listV1, listV2));

        List<MainActivity.AppItem> listTimeUpdated = new ArrayList<MainActivity.AppItem>();
        listTimeUpdated.add(new MainActivity.AppItem("App 1", "com.test.app1", "Act1", icon1, 1, 2000L));
        assertFalse("Variazione di lastUpdateTime deve essere rilevata come aggiornamento", MainActivity.areAppListsEqual(listV1, listTimeUpdated));

        List<MainActivity.AppItem> listV1Clone = new ArrayList<MainActivity.AppItem>();
        listV1Clone.add(new MainActivity.AppItem("App 1", "com.test.app1", "Act1", icon1, 1, 1000L));
        assertTrue("Versione e timestamp identici devono risultare uguali", MainActivity.areAppListsEqual(listV1, listV1Clone));
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

    // =========================================================================
    // SUITE 6: AkaiMenuHomeService (Tasto MENU -> Home v8 e Anti-Collisione OEM)
    // =========================================================================

    private static void testMenuKeyOnThirdPartyAppTriggersGlobalHome() {
        System.out.println("\nTest 6.1: Pressione Tasto MENU su App Terze (YouTube/Netflix/RaiPlay) -> Trigger GLOBAL_ACTION_HOME");
        AkaiMenuHomeService service = new AkaiMenuHomeService();
        service.onServiceConnected();

        // Simula foreground YouTube
        service.setCurrentPackageForTest("com.google.android.youtube.tv");

        KeyEvent down = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MENU);
        boolean downConsumed = service.onKeyEvent(down);
        assertTrue("MENU DOWN su app streaming deve essere consumato (return true)", downConsumed);
        assertEquals("Nessuna azione globale eseguita su ACTION_DOWN", 0, service.getGlobalActionsPerformed());

        KeyEvent up = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU);
        boolean upConsumed = service.onKeyEvent(up);
        assertTrue("MENU UP su app streaming deve essere consumato (return true)", upConsumed);
        assertEquals("Esattamente 1 azione globale eseguita su ACTION_UP", 1, service.getGlobalActionsPerformed());
        assertEquals("Azione globale eseguita deve essere GLOBAL_ACTION_HOME", 2, service.getLastGlobalAction());

        // Simula foreground Netflix
        service.setCurrentPackageForTest("com.netflix.ninja");
        service.resetGlobalActionsCount();
        service.onKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU));
        assertEquals("MENU UP su Netflix deve attivare GLOBAL_ACTION_HOME", 1, service.getGlobalActionsPerformed());

        // Simula foreground RaiPlay
        service.setCurrentPackageForTest("it.rainet.raiplay");
        service.resetGlobalActionsCount();
        service.onKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU));
        assertEquals("MENU UP su RaiPlay deve attivare GLOBAL_ACTION_HOME", 1, service.getGlobalActionsPerformed());

        // Simula foreground Mediaset Infinity reale sulla TV (it.mediaset.infinitytv)
        service.setCurrentPackageForTest("it.mediaset.infinitytv");
        service.resetGlobalActionsCount();
        service.onKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU));
        assertEquals("MENU UP su Mediaset Infinity TV (it.mediaset.infinitytv) deve attivare GLOBAL_ACTION_HOME", 1, service.getGlobalActionsPerformed());

        // Simula foreground Browser Ufficiale TV Bro (com.phlox.tvwebbrowser)
        service.setCurrentPackageForTest("com.phlox.tvwebbrowser");
        service.resetGlobalActionsCount();
        service.onKeyEvent(new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU));
        assertEquals("MENU UP su Browser TV Bro ufficiale deve attivare GLOBAL_ACTION_HOME", 1, service.getGlobalActionsPerformed());
    }

    private static void testMenuKeyOnOemDtvAppPassesThrough() {
        System.out.println("\nTest 6.2: Pressione Tasto MENU su App OEM TV Digitale -> Passthrough Trasparente (Zero Intercettazione)");
        AkaiMenuHomeService service = new AkaiMenuHomeService();
        service.onServiceConnected();

        // 1. Live TV Digitale terrestre
        service.setCurrentPackageForTest("cn.cultraview.tv");
        KeyEvent down = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MENU);
        boolean downConsumed = service.onKeyEvent(down);
        assertFalse("MENU DOWN su TV Digitale NON deve essere consumato (pass-through OEM)", downConsumed);

        KeyEvent up = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU);
        boolean upConsumed = service.onKeyEvent(up);
        assertFalse("MENU UP su TV Digitale NON deve essere consumato (pass-through OEM)", upConsumed);
        assertEquals("ZERO azioni globali eseguite su app TV OEM", 0, service.getGlobalActionsPerformed());

        // 2. MStar TV Player
        service.setCurrentPackageForTest("com.mstar.tv.tvplayer");
        assertFalse("MENU su com.mstar.tv.tvplayer deve passare all'OEM", service.onKeyEvent(up));
        assertEquals("ZERO azioni globali eseguite su MStar player", 0, service.getGlobalActionsPerformed());

        // 3. Technical Open Launcher
        service.setCurrentPackageForTest("cn.cultraview.launcher.technical.open");
        assertFalse("MENU su impostazioni tecniche OEM deve passare all'OEM", service.onKeyEvent(up));
        assertEquals("ZERO azioni globali eseguite su menu tecnico OEM", 0, service.getGlobalActionsPerformed());
    }

    private static void testNonMenuKeysPassThrough() {
        System.out.println("\nTest 6.3: Altri Tasti (DPAD, OK, BACK, VOLUME) -> Nessuna Intercettazione");
        AkaiMenuHomeService service = new AkaiMenuHomeService();
        service.onServiceConnected();
        service.setCurrentPackageForTest("com.google.android.youtube.tv");

        KeyEvent dpadCenter = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER);
        assertFalse("DPAD_CENTER non deve essere intercettato dal servizio", service.onKeyEvent(dpadCenter));

        KeyEvent back = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_BACK);
        assertFalse("BACK non deve essere intercettato dal servizio", service.onKeyEvent(back));

        KeyEvent volUp = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_VOLUME_UP);
        assertFalse("VOLUME_UP non deve essere intercettato dal servizio", service.onKeyEvent(volUp));
        assertEquals("ZERO azioni globali su tasti non-MENU", 0, service.getGlobalActionsPerformed());
    }

    private static void testWindowStateChangedUpdatesPackage() {
        System.out.println("\nTest 6.4: Eventi TYPE_WINDOW_STATE_CHANGED -> Aggiornamento Sicuro Package Corrente");
        AkaiMenuHomeService service = new AkaiMenuHomeService();
        service.onServiceConnected();

        android.view.accessibility.AccessibilityEvent event1 =
                new android.view.accessibility.AccessibilityEvent(android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, "com.disney.disneyplus");
        service.onAccessibilityEvent(event1);
        assertEquals("Package aggiornato a Disney+", "com.disney.disneyplus", service.getCurrentPackage());

        android.view.accessibility.AccessibilityEvent event2 =
                new android.view.accessibility.AccessibilityEvent(android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, "cn.cultraview.tv");
        service.onAccessibilityEvent(event2);
        assertEquals("Package aggiornato a TV OEM", "cn.cultraview.tv", service.getCurrentPackage());
        assertTrue("cn.cultraview.tv correttamente riconosciuto come OEM", service.isOemPassthroughPackage(service.getCurrentPackage()));
    }

    private static void testMenuKeyFailOpenOnNullAndEmptyPackage() {
        System.out.println("\nTest 6.5: Rigoroso Fail-Open su Package Sconosciuto/Null/Vuoto (P1 Risolto)");
        AkaiMenuHomeService service = new AkaiMenuHomeService();
        service.onServiceConnected();

        // 1. Stato iniziale / null package
        service.setCurrentPackageForTest(null);
        assertFalse("shouldInterceptMenu con null DEVE ritornare false (Fail-Open)", service.shouldInterceptMenu(null));
        KeyEvent upNull = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU);
        assertFalse("MENU UP con null package NON deve essere consumato (passa all'OEM)", service.onKeyEvent(upNull));
        assertEquals("ZERO azioni globali su null package", 0, service.getGlobalActionsPerformed());

        // 2. Stringa vuota ""
        service.setCurrentPackageForTest("");
        assertFalse("shouldInterceptMenu con stringa vuota DEVE ritornare false (Fail-Open)", service.shouldInterceptMenu(""));
        assertFalse("MENU UP con stringa vuota NON deve essere consumato", service.onKeyEvent(upNull));
        assertEquals("ZERO azioni globali su stringa vuota", 0, service.getGlobalActionsPerformed());

        // 3. Stringa di soli spazi
        service.setCurrentPackageForTest("   ");
        assertFalse("shouldInterceptMenu con soli spazi DEVE ritornare false (Fail-Open)", service.shouldInterceptMenu("   "));
        assertFalse("MENU UP con soli spazi NON deve essere consumato", service.onKeyEvent(upNull));
        assertEquals("ZERO azioni globali su soli spazi", 0, service.getGlobalActionsPerformed());
    }

    private static void testMenuKeyFailOpenOnSystemAndOemPackages() {
        System.out.println("\nTest 6.6: Rigoroso Fail-Open su Pacchetti OEM, DTV e Sistema AOSP (P1 Risolto)");
        AkaiMenuHomeService service = new AkaiMenuHomeService();
        service.onServiceConnected();

        String[] protectedPackages = new String[]{
                "com.mediatek.wwtv.tvcenter",           // DTV TV Digitale Terrestre
                "com.mediatek.tvinput",                 // Gestore Ingressi HDMI / Source
                "com.mediatek.wwtv.setupwizard",        // Wizard prima configurazione
                "mediatek.factorymenu.ui",              // Menu Fabbrica TV
                "com.cultraview.SwipeService",          // Servizio gesture Cultraview
                "com.cultraview.newfilemanager",        // File manager OEM
                "cn.cultraview.launcher.technical.open",// Launcher tecnico di servizio
                "com.mstar.tv.tvplayer",                // MStar TV player
                "com.ctv.android.tvboot",               // Servizio avvio CTV
                "com.android.tv.settings",              // Impostazioni TV
                "com.android.systemui",                 // SystemUI / dialoghi volume / notifiche
                "com.android.packageinstaller",         // Installatore pacchetti
                "android",                              // Sistema Android framework
                "it.akai.customhome.v8",                // Launcher Custom Home v8 stesso
                "it.akai.customremote"                  // JARVIS telecomando
        };

        KeyEvent menuUp = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU);
        for (String pkg : protectedPackages) {
            service.setCurrentPackageForTest(pkg);
            assertTrue("Pacchetto protetto OEM/Sistema: " + pkg, service.isOemOrSystemPackage(pkg));
            assertFalse("shouldInterceptMenu DEVE ritornare false per: " + pkg, service.shouldInterceptMenu(pkg));
            boolean consumed = service.onKeyEvent(menuUp);
            assertFalse("MENU su pacchetto protetto (" + pkg + ") NON deve essere consumato", consumed);
        }
        assertEquals("ZERO azioni globali eseguite su pacchetti protetti OEM/Sistema", 0, service.getGlobalActionsPerformed());
    }

    private static void testMenuKeyRepeatsAndLongPress() {
        System.out.println("\nTest 6.7: Pressione Prolungata / Repeat Tasto MENU in App Streaming");
        AkaiMenuHomeService service = new AkaiMenuHomeService();
        service.onServiceConnected();
        service.setCurrentPackageForTest("com.google.android.youtube.tv");

        // Primo DOWN (premuto)
        KeyEvent down1 = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MENU);
        assertTrue("Primo DOWN deve essere consumato", service.onKeyEvent(down1));
        assertEquals("Nessuna azione globale su DOWN", 0, service.getGlobalActionsPerformed());

        // Repeat DOWN 1..3 (tasto tenuto premuto sul telecomando)
        KeyEvent repeat1 = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MENU);
        assertTrue("Repeat 1 deve essere consumato", service.onKeyEvent(repeat1));
        KeyEvent repeat2 = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_MENU);
        assertTrue("Repeat 2 deve essere consumato", service.onKeyEvent(repeat2));
        assertEquals("ZERO azioni globali durante il repeat del tasto", 0, service.getGlobalActionsPerformed());

        // ACTION_UP al rilascio del tasto
        KeyEvent up = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU);
        assertTrue("UP finale deve essere consumato", service.onKeyEvent(up));
        assertEquals("Esattamente 1 azione globale eseguita al rilascio", 1, service.getGlobalActionsPerformed());
    }

    private static void testMenuKeyServiceDisabled() {
        System.out.println("\nTest 6.8: Disattivazione Dinamica di Emergenza del Servizio (Kill-Switch)");
        AkaiMenuHomeService service = new AkaiMenuHomeService();
        service.onServiceConnected();
        service.setCurrentPackageForTest("com.netflix.ninja");

        // Servizio disabilitato
        service.setServiceEnabled(false);
        assertFalse("isServiceEnabled deve essere false", service.isServiceEnabled());

        KeyEvent menuUp = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU);
        assertFalse("MENU UP quando disabilitato NON deve essere consumato (passa interamente)", service.onKeyEvent(menuUp));
        assertEquals("ZERO azioni globali quando il servizio e disabilitato", 0, service.getGlobalActionsPerformed());

        // Riabilitazione
        service.setServiceEnabled(true);
        assertTrue("isServiceEnabled deve essere true", service.isServiceEnabled());
        assertTrue("MENU UP dopo riabilitazione deve essere consumato", service.onKeyEvent(menuUp));
        assertEquals("1 azione globale eseguita dopo riabilitazione", 1, service.getGlobalActionsPerformed());
    }

    private static void testWindowStateChangedNullOrBlankResetsToFailOpen() {
        System.out.println("\nTest 6.9: Evento Transitorio Privo di Package -> Reset Automatico a Fail-Open");
        AkaiMenuHomeService service = new AkaiMenuHomeService();
        service.onServiceConnected();

        // 1. Prima impostiamo un'app streaming
        service.setCurrentPackageForTest("com.netflix.ninja");
        assertTrue("Netflix deve essere intercettato", service.shouldInterceptMenu(service.getCurrentPackage()));

        // 2. Arriva evento con package null (es. finestra di dialogo di sistema/overlay transitorio)
        android.view.accessibility.AccessibilityEvent nullEvent =
                new android.view.accessibility.AccessibilityEvent(android.view.accessibility.AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED, null);
        service.onAccessibilityEvent(nullEvent);

        assertEquals("currentPackage deve essere resettato a stringa vuota", "", service.getCurrentPackage());
        assertFalse("shouldInterceptMenu su stato transitorio DEVE ritornare false (Fail-Open)", service.shouldInterceptMenu(service.getCurrentPackage()));

        KeyEvent up = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU);
        assertFalse("MENU su stato transitorio NON deve essere consumato", service.onKeyEvent(up));
        assertEquals("ZERO azioni globali durante stato transitorio", 0, service.getGlobalActionsPerformed());
    }

    private static void testMenuKeyFailOpenOnUnknownVendorsAndOverlays() {
        System.out.println("\nTest 6.10: Rigoroso Fail-Open per Vendor Ignoti e Overlay (com.vendor.unknownmenu / com.example.overlay)");
        AkaiMenuHomeService service = new AkaiMenuHomeService();
        service.onServiceConnected();

        String[] unknownPackages = new String[]{
                "com.vendor.unknownmenu",
                "com.example.overlay",
                "org.unknown.dialog",
                "com.custom.oem.overlay",
                "it.random.unknownapp"
        };

        KeyEvent menuUp = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_MENU);
        for (String pkg : unknownPackages) {
            service.setCurrentPackageForTest(pkg);
            assertFalse("Pacchetto ignoto non deve essere riconosciuto come verified app: " + pkg, AkaiMenuHomeService.isVerifiedUserApp(pkg));
            assertFalse("shouldInterceptMenu DEVE ritornare false (Fail-Open) per: " + pkg, service.shouldInterceptMenu(pkg));
            boolean consumed = service.onKeyEvent(menuUp);
            assertFalse("MENU su pacchetto ignoto (" + pkg + ") NON deve essere consumato (pass-through OEM)", consumed);
        }
        assertEquals("ZERO azioni globali eseguite su pacchetti o overlay ignoti", 0, service.getGlobalActionsPerformed());
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
            testSingleOnKeyListenerWiringWithFocusLoss();

            // Preferiti & P0 OEM Regression
            testEmptyFavoritesPersistenceAcrossReboot();
            testFirstRunSeedsDefaultFavorites();
            testOemTechnicalAppInFavoritesPreservedAcrossFilterToggle();
            testReorderFavoritesWithHiddenOemApps();

            // Diffing e Focus
            testAppListsEqualDiffing();
            testCardTagPackageAndSectionAssociation();

            // OEM Blacklist & Streaming
            testOemTechnicalAppsFilter();
            testStreamingCategorization();

            // WCAG Contrast
            testColorContrastWCAG();

            // Suite 6: AkaiMenuHomeService (Tasto MENU -> Home v8, Fail-Open e Anti-Collisione OEM)
            testMenuKeyOnThirdPartyAppTriggersGlobalHome();
            testMenuKeyOnOemDtvAppPassesThrough();
            testNonMenuKeysPassThrough();
            testWindowStateChangedUpdatesPackage();
            testMenuKeyFailOpenOnNullAndEmptyPackage();
            testMenuKeyFailOpenOnSystemAndOemPackages();
            testMenuKeyRepeatsAndLongPress();
            testMenuKeyServiceDisabled();
            testWindowStateChangedNullOrBlankResetsToFailOpen();
            testMenuKeyFailOpenOnUnknownVendorsAndOverlays();

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
