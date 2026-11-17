package it.akai.customremote;

import it.akai.customremote.ai.FreeItalianTtsPolicy;

public final class FreeItalianTtsPolicyTest {
    private static int checks = 0;
    private static void check(boolean b, String detail) {
        checks++;
        if (!b) throw new AssertionError(detail);
    }

    public static void main(String[] args) {
        check(FreeItalianTtsPolicy.voiceAllowed("it-IT-DiegoNeural"), "male Italian");
        check(FreeItalianTtsPolicy.voiceAllowed("it-IT-IsabellaNeural"), "female Italian");
        check(!FreeItalianTtsPolicy.voiceAllowed("en-US-JennyNeural"), "no other language");
        check(!FreeItalianTtsPolicy.voiceAllowed("it-IT-DiegoNeural/../x"), "no voice injection");
        check(FreeItalianTtsPolicy.textAllowed("Buongiorno, ecco il meteo."), "simple Italian");
        check(!FreeItalianTtsPolicy.textAllowed("Il tuo password è ABC"), "no password");
        check(!FreeItalianTtsPolicy.textAllowed("La tua api key è abc"), "no API key");
        check(!FreeItalianTtsPolicy.textAllowed("Scrivi a nome@esempio.it"), "no email");
        check(!FreeItalianTtsPolicy.textAllowed("Il codice è 123456"), "no OTP/number");
        check(!FreeItalianTtsPolicy.textAllowed(""), "no empty text");
        check(!FreeItalianTtsPolicy.textAllowed(new String(new char[601]).replace('\0', 'a')),
                "no oversize request");
        check(FreeItalianTtsPolicy.fileIdAllowed("abc_0123-Q"), "safe ID");
        check(!FreeItalianTtsPolicy.fileIdAllowed("../private"), "no traversal");
        check(!FreeItalianTtsPolicy.fileIdAllowed("https://evil.test"), "no URL injection");
        check(!FreeItalianTtsPolicy.fileIdAllowed(""), "no empty ID");
        check(FreeItalianTtsPolicy.canReserve(202611, 0, 202611, 600), "first free request");
        check(FreeItalianTtsPolicy.canReserve(202611, 4900, 202611, 100), "boundary");
        check(!FreeItalianTtsPolicy.canReserve(202611, 4901, 202611, 100), "over budget");
        check(!FreeItalianTtsPolicy.canReserve(202612, 200, 202611, 10), "clock rollback");
        check(FreeItalianTtsPolicy.canReserve(202611, 4900, 202612, 600), "new month");
        check(!FreeItalianTtsPolicy.canReserve(202611, -1, 202611, 200), "corrupt usage");
        check(!FreeItalianTtsPolicy.canReserve(202611, 5001, 202611, 1), "corrupt cap");
        check(!FreeItalianTtsPolicy.canReserve(202611, 0, 202611, 0), "no free empty call");
        check(!FreeItalianTtsPolicy.canReserve(202611, 0, 202611, 601), "per-call limit");
        check(FreeItalianTtsPolicy.currentUtcMonth() > 202501, "valid utc time");
        System.out.println("FreeItalianTtsPolicyTest PASS (" + checks + " assertions)");
    }
}
