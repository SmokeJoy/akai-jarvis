package android.net;
public class Uri {
    private String uriString;
    public static Uri parse(String s) {
        Uri u = new Uri();
        u.uriString = s;
        return u;
    }
    public static String encode(String s) { return s; }
    public String getSchemeSpecificPart() {
        if (uriString != null && uriString.startsWith("package:")) {
            return uriString.substring(8);
        }
        return uriString;
    }
}
