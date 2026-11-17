package it.akai.customremote;

import it.akai.customremote.ai.VisualObservationProvider;

public final class VisualObservationProviderTest {
    private static int checks;
    private static final String UI = "{\"active_package\":\"it.mediaset.infinitytv\"}";
    private static final String PKG = "it.mediaset.infinitytv";
    private static final long TIME = 1_700_000_000_000L;

    private static void verify(boolean condition, String label) {
        checks++;
        if (!condition) throw new AssertionError(label);
    }

    public static void main(String[] args) {
        verify(!VisualObservationProvider.active(), "no implicit capture");
        verify(!VisualObservationProvider.observe("deepseek", PKG, UI, null).success,
                "cannot capture without session");
        final int[] calls = {0};
        VisualObservationProvider.Session fake = new VisualObservationProvider.Session() {
            @Override public VisualObservationProvider.Result observe(String provider,
                    String expectedPackage, String expectedUi, VisualObservationProvider.Cancellation cancel) {
                calls[0]++;
                return VisualObservationProvider.Result.observed(
                        provider, expectedPackage, expectedUi,
                        "Schermata TV: Diretta", TIME, 45, 0.01);
            }
        };
        verify(VisualObservationProvider.install(fake), "owner-enabled session installed");
        verify(VisualObservationProvider.active(), "session now visible");
        verify(!VisualObservationProvider.install(fake), "no second concurrent session");
        verify(!VisualObservationProvider.observe("local", PKG, UI, null).success,
                "no on-device LLM");
        verify(!VisualObservationProvider.observe("openai", PKG, UI, null).success,
                "no third AI provider");
        verify(!VisualObservationProvider.observe("deepseek", PKG, UI,
                () -> true).success, "cancellation checked before capture");
        verify(calls[0] == 0, "blocked requests never reach service");
        VisualObservationProvider.Result good =
                VisualObservationProvider.observe("deepseek", PKG, UI, () -> false);
        verify(good.success && good.description.contains("Diretta") && calls[0] == 1,
                "valid consented DeepSeek result");
        verify(VisualObservationProvider.observe("kimi", PKG, UI, null).success,
                "Kimi is equally allowed");

        VisualObservationProvider.clear(fake);
        verify(!VisualObservationProvider.active(), "teardown unregisters session");
        VisualObservationProvider.Session spoof = new VisualObservationProvider.Session() {
            @Override public VisualObservationProvider.Result observe(String provider,
                    String expectedPackage, String expectedUi, VisualObservationProvider.Cancellation cancel) {
                return VisualObservationProvider.Result.observed("kimi", expectedPackage,
                        expectedUi, "Wrong provider reply", TIME, 0, 0);
            }
        };
        verify(VisualObservationProvider.install(spoof), "spoof fixture installed");
        verify(!VisualObservationProvider.observe("deepseek", PKG, UI, null).success,
                "cannot cross provider");
        VisualObservationProvider.clear(spoof);

        VisualObservationProvider.Session stale = new VisualObservationProvider.Session() {
            @Override public VisualObservationProvider.Result observe(String provider,
                    String expectedPackage, String expectedUi, VisualObservationProvider.Cancellation cancel) {
                return VisualObservationProvider.Result.observed(provider,
                        expectedPackage, "{\"active_package\":\"changed\"}",
                        "Stale", TIME, 0, 0);
            }
        };
        verify(VisualObservationProvider.install(stale), "stale fixture installed");
        verify(!VisualObservationProvider.observe("kimi", PKG, UI, null).success,
                "UI fingerprint provenance must match");
        VisualObservationProvider.clear(stale);
        verify(!VisualObservationProvider.observe("kimi", PKG, UI, null).success,
                "after teardown, no capture possible");
        System.out.println("VisualObservationProviderTest PASS: " + checks + " assertions");
    }
}
