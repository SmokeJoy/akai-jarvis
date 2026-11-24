package android.os;

public final class Looper {
    private static final Looper MAIN_LOOPER = new Looper();
    private static final ThreadLocal<Looper> THREAD_LOOPER = new ThreadLocal<>();

    private Looper() {}

    public static Looper getMainLooper() {
        return MAIN_LOOPER;
    }

    public static Looper myLooper() {
        return THREAD_LOOPER.get();
    }

    public static void setCurrentAsMainLooperForTest(boolean isMain) {
        if (isMain) {
            THREAD_LOOPER.set(MAIN_LOOPER);
        } else {
            THREAD_LOOPER.remove();
        }
    }
}
