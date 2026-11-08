package android.view;
import java.util.ArrayList;
import java.util.List;

public class ViewGroup extends View {
    protected final List<View> children = new ArrayList<View>();
    public void addView(View v) { children.add(v); }
    public void addView(View v, int i) { children.add(i, v); }
    public void removeView(View v) { children.remove(v); }
    public void removeAllViews() { children.clear(); }
    public int getChildCount() { return children.size(); }
    public View getChildAt(int i) { return (i >= 0 && i < children.size()) ? children.get(i) : null; }
}
