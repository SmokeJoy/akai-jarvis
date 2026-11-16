package android.view;
import java.util.ArrayList;
import java.util.List;

public class ViewGroup extends View {
    public static class LayoutParams {
        public int width;
        public int height;
        public LayoutParams(int width, int height) { this.width = width; this.height = height; }
    }
    public static class MarginLayoutParams extends LayoutParams {
        public int rightMargin;
        public MarginLayoutParams(int width, int height) { super(width, height); }
    }

    protected final List<View> children = new ArrayList<View>();
    public void addView(View v) { children.add(v); }
    public void addView(View v, int i) { children.add(i, v); }
    public void removeView(View v) { children.remove(v); }
    public void removeAllViews() { children.clear(); }
    public int getChildCount() { return children.size(); }
    public View getChildAt(int i) { return (i >= 0 && i < children.size()) ? children.get(i) : null; }
}
