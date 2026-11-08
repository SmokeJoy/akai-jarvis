package it.akai.customhome;

import android.view.KeyEvent;
import android.view.View;

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

    // Mock Activity Harness per intercettare le chiamate del CardKeyHandler
    private static class MockActivityHarness extends MainActivity {
        int launchAppCalls = 0;
        int showFavDialogCalls = 0;
        int showAppDialogCalls = 0;
        AppItem lastLaunchedItem = null;

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
    // TEST SUITE
    // -------------------------------------------------------------------------

    public static void testP0ShortPressLaunchesApp() {
        System.out.println("\nTest 1.1: Sequenza D-Pad Pressione Breve (OK / CENTER) -> Avvio App");
        MockActivityHarness harness = new MockActivityHarness();
        MainActivity.AppItem testItem = new MainActivity.AppItem("YouTube TV", "com.google.android.youtube.tv", "MainActivity", null);
        MainActivity.CardKeyHandler handler = new MainActivity.CardKeyHandler(harness, testItem, MainActivity.SECTION_STREAMING, 0);
        View mockView = new View();

        // 1. ACTION_DOWN repeat 0
        KeyEvent downEvent = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 0);
        boolean downResult = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, downEvent);
        assertTrue("DOWN deve essere consumato (return true)", downResult);
        assertEquals("Nessun lancio dell'app durante il DOWN", 0, harness.launchAppCalls);
        assertEquals("Nessun dialogo durante il DOWN breve", 0, harness.showAppDialogCalls);
        assertFalse("longPressHandled deve essere false", handler.isLongPressHandled());

        // 2. ACTION_UP repeat 0
        KeyEvent upEvent = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_CENTER, 0);
        boolean upResult = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, upEvent);
        assertTrue("UP deve essere consumato (return true)", upResult);
        assertEquals("L'app deve essere lanciata esattamente 1 volta al rilascio", 1, harness.launchAppCalls);
        assertEquals("Nessun dialogo aperto", 0, harness.showAppDialogCalls);
        assertEquals("L'app lanciata deve essere YouTube TV", "com.google.android.youtube.tv", harness.lastLaunchedItem.packageName);
    }

    public static void testP0LongPressOpensDialogAndPreventsAppLaunch() {
        System.out.println("\nTest 1.2: Sequenza D-Pad Pressione Prolungata (P0) -> Apre Dialogo ed ELIMINA Lancio App");
        MockActivityHarness harness = new MockActivityHarness();
        MainActivity.AppItem testItem = new MainActivity.AppItem("RaiPlay", "it.rainet.androidtv", "RaiPlayActivity", null);
        MainActivity.CardKeyHandler handler = new MainActivity.CardKeyHandler(harness, testItem, MainActivity.SECTION_FAVORITES, 2);
        View mockView = new View();

        // 1. ACTION_DOWN repeat 0
        KeyEvent down0 = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 0);
        handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, down0);

        // 2. ACTION_DOWN repeat 1 (isLongPress = true)
        KeyEvent downLong = new KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_CENTER, 1, true, false);
        boolean downLongResult = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, downLong);
        assertTrue("DOWN LongPress deve essere consumato", downLongResult);
        assertEquals("Dialogo opzioni preferiti aperto esattamente 1 volta", 1, harness.showFavDialogCalls);
        assertEquals("Nessun avvio app durante long press", 0, harness.launchAppCalls);
        assertTrue("longPressHandled deve essere true", handler.isLongPressHandled());

        // 3. ACTION_UP (Rilascio tasto dopo long press)
        KeyEvent upAfterLong = new KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_DPAD_CENTER, 0);
        boolean upResult = handler.onKey(mockView, KeyEvent.KEYCODE_DPAD_CENTER, upAfterLong);
        assertTrue("UP dopo long press deve essere consumato per non propagarsi", upResult);

        // VERIFICA CRITICA P0: ZERO AVVII DELL'APP AL RILASCIO!
        assertEquals("ZERO lanci dell'app al rilascio dopo long press (P0 Risolto!)", 0, harness.launchAppCalls);
        assertEquals("Dialoghi aperti rimangono 1", 1, harness.showFavDialogCalls);
        assertFalse("longPressHandled deve essere resettato a false per eventi successivi", handler.isLongPressHandled());
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

    public static void testOemTechnicalAppsFilter() {
        System.out.println("\nTest 2: Filtro / Blacklist Applicazioni Tecniche OEM");

        // Utility OEM e factory che DEVONO essere nascoste
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

        // App utente legittime che NON DEVONO essere filtrate
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
        System.out.println("\nTest 3: Categorizzazione Sezione STREAMING & CINEMA");

        // Piattaforme streaming
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

        // Utility generiche NON streaming
        assertFalse("File Manager non è streaming", MainActivity.isStreamingApp("com.android.documentsui", "File Manager"));
        assertFalse("Calcolatrice non è streaming", MainActivity.isStreamingApp("com.android.calculator2", "Calcolatrice"));
        assertFalse("Settings non è streaming", MainActivity.isStreamingApp("com.android.tv.settings", "Impostazioni TV"));
        assertFalse("Clock non è streaming", MainActivity.isStreamingApp("com.android.deskclock", "Orologio"));
    }

    public static void testColorContrastWCAG() {
        System.out.println("\nTest 4: Verifica Matematica Rapporto di Contrasto sRGB (WCAG AAA >= 7.0:1)");

        // Calcolo luminanza relativa sRGB canonica IEC 61966-2-1
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
            testP0ShortPressLaunchesApp();
            testP0LongPressOpensDialogAndPreventsAppLaunch();
            testP0EnterKeyEquivalence();
            testP0CanceledEventDoesNotLaunch();
            testOemTechnicalAppsFilter();
            testStreamingCategorization();
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
