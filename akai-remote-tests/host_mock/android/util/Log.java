package android.util;

import java.util.ArrayList;
import java.util.List;

/** Host-only capture for privacy regression tests; Android runtime uses platform Log. */
public class Log {
    private static final List<String> captured = new ArrayList<>();
    private static final int LIMIT = 200;

    private static synchronized int record(String message) {
        if (captured.size() < LIMIT) captured.add(message == null ? "" : message);
        return 0;
    }

    public static synchronized void clearCapturedForTest() { captured.clear(); }

    public static synchronized List<String> capturedForTest() {
        return new ArrayList<>(captured);
    }

    public static int i(String tag, String msg) { return record(msg); }
    public static int w(String tag, String msg) { return record(msg); }
    public static int e(String tag, String msg) { return record(msg); }
    public static int e(String tag, String msg, Throwable tr) { return record(msg); }
    public static int d(String tag, String msg) { return record(msg); }
}
