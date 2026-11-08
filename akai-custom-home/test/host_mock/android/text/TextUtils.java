package android.text;
public class TextUtils {
    public static String join(CharSequence d, Iterable t) {
        StringBuilder sb = new StringBuilder();
        boolean first = true;
        for (Object o : t) {
            if (!first) sb.append(d);
            sb.append(o);
            first = false;
        }
        return sb.toString();
    }
}
