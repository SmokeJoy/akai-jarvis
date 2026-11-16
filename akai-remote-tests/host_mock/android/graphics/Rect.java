package android.graphics;

public class Rect {
    public int left;
    public int top;
    public int right;
    public int bottom;

    public Rect() {}

    public Rect(int left, int top, int right, int bottom) {
        this.left = left;
        this.top = top;
        this.right = right;
        this.bottom = bottom;
    }

    public int centerX() { return (left + right) / 2; }
    public int centerY() { return (top + bottom) / 2; }
    public boolean isEmpty() { return left >= right || top >= bottom; }
}
