package android.graphics;

public class Bitmap {
    public enum Config {
        ARGB_8888,
        RGB_565
    }

    private final int width;
    private final int height;

    protected Bitmap(int width, int height) {
        this.width = width;
        this.height = height;
    }

    public static Bitmap createBitmap(int width, int height, Config config) {
        return new Bitmap(width, height);
    }

    public void setPixel(int x, int y, int color) {
    }

    public int getWidth() {
        return width;
    }

    public int getHeight() {
        return height;
    }
}
