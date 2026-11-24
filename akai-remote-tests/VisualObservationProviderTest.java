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

        // Regression: owner STOP can arrive while a vision call is blocked.
        // Its late but otherwise well-formed answer must never reach planning.
        final int[] revokedStopCalls = {0};
        VisualObservationProvider.Session revokedMidFlight = new VisualObservationProvider.Session() {
            @Override public VisualObservationProvider.Result observe(String provider,
                    String expectedPackage, String expectedUi, VisualObservationProvider.Cancellation cancel) {
                VisualObservationProvider.stopAndRevoke();
                return VisualObservationProvider.Result.observed(
                        provider, expectedPackage, expectedUi, "Late cloud answer", TIME, 7, 0.01);
            }
            @Override public void stopByOwner() { revokedStopCalls[0]++; }
        };
        verify(VisualObservationProvider.install(revokedMidFlight), "in-flight cancellation fixture");
        VisualObservationProvider.Result revokedResult =
                VisualObservationProvider.observe("deepseek", PKG, UI, null);
        verify(!revokedResult.success
                && "SESSION_REVOKED_DURING_OBSERVATION".equals(revokedResult.reason),
                "STOP must invalidate an already started vision answer");
        verify(revokedStopCalls[0] == 1 && !VisualObservationProvider.active(),
                "STOP revokes only once and clears capture session");

        // A newly approved session cannot inherit observations from the old one.
        VisualObservationProvider.Session replacement = new VisualObservationProvider.Session() {
            @Override public VisualObservationProvider.Result observe(String provider,
                    String expectedPackage, String expectedUi, VisualObservationProvider.Cancellation cancel) {
                return VisualObservationProvider.Result.observed(
                        provider, expectedPackage, expectedUi, "Fresh answer", TIME, 8, 0.02);
            }
        };
        VisualObservationProvider.Session replacedMidFlight = new VisualObservationProvider.Session() {
            @Override public VisualObservationProvider.Result observe(String provider,
                    String expectedPackage, String expectedUi, VisualObservationProvider.Cancellation cancel) {
                VisualObservationProvider.clear(this);
                verify(VisualObservationProvider.install(replacement), "replacement session accepted");
                return VisualObservationProvider.Result.observed(
                        provider, expectedPackage, expectedUi, "Stale answer", TIME, 8, 0.02);
            }
        };
        verify(VisualObservationProvider.install(replacedMidFlight), "replacement fixture installed");
        VisualObservationProvider.Result staleSession =
                VisualObservationProvider.observe("kimi", PKG, UI, null);
        verify(!staleSession.success
                && "SESSION_REVOKED_DURING_OBSERVATION".equals(staleSession.reason),
                "old session result must not cross to replacement");
        verify(VisualObservationProvider.observe("kimi", PKG, UI, null).success,
                "new session can still serve fresh observations");
        VisualObservationProvider.clear(replacement);
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
        final int[] stopCalls = {0};
        VisualObservationProvider.Session stopping = new VisualObservationProvider.Session() {
            @Override public VisualObservationProvider.Result observe(String provider,
                    String pkg, String ui, VisualObservationProvider.Cancellation cancel) {
                return VisualObservationProvider.Result.unavailable("SESSION_REVOKED");
            }
            @Override public void stopByOwner() { stopCalls[0]++; }
        };
        verify(VisualObservationProvider.install(stopping), "new owner-approved session");
        VisualObservationProvider.stopAndRevoke();
        verify(stopCalls[0] == 1, "owner stop was sent exactly once");
        verify(!VisualObservationProvider.active(), "session revoked on stop");
        verify(!VisualObservationProvider.observe("deepseek", PKG, UI, null).success,
                "cannot observe after cancel");
        System.out.println("VisualObservationProviderTest PASS: " + checks + " assertions");
    }
}
