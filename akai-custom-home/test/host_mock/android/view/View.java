package android.view;

import android.graphics.drawable.Drawable;

public class View {
    public static final int VISIBLE = 0;
    public static final int INVISIBLE = 4;
    public static final int GONE = 8;

    public interface OnClickListener {
        void onClick(View v);
    }

    public interface OnLongClickListener {
        boolean onLongClick(View v);
    }

    public interface OnKeyListener {
        boolean onKey(View v, int keyCode, KeyEvent event);
    }

    public interface OnFocusChangeListener {
        void onFocusChange(View v, boolean hasFocus);
    }

    private OnClickListener onClickListener;
    private OnLongClickListener onLongClickListener;
    private OnKeyListener onKeyListener;
    private OnFocusChangeListener onFocusChangeListener;
    private boolean focused;
    private int visibility = VISIBLE;
    private Drawable background;
    private Object tag;
    private int id = -1;
    private int scrollX = 0;
    private int scrollY = 0;

    public void setBackgroundResource(int resid) {}
    public int getTop() { return 0; }
    public void setTag(Object tag) { this.tag = tag; }
    public Object getTag() { return tag; }

    public void setId(int id) { this.id = id; }
    public int getId() { return id; }

    public boolean isFocusable() { return true; }
    public boolean requestFocus() { setFocused(true); return true; }

    public int getScrollX() { return scrollX; }
    public int getScrollY() { return scrollY; }
    public void scrollTo(int x, int y) { this.scrollX = x; this.scrollY = y; }
    public boolean post(Runnable r) { if (r != null) r.run(); return true; }

    public void setOnClickListener(OnClickListener l) { this.onClickListener = l; }
    public void setOnLongClickListener(OnLongClickListener l) { this.onLongClickListener = l; }
    public void setOnKeyListener(OnKeyListener l) { this.onKeyListener = l; }
    public void setOnFocusChangeListener(OnFocusChangeListener l) { this.onFocusChangeListener = l; }

    public boolean performClick() {
        if (onClickListener != null) {
            onClickListener.onClick(this);
            return true;
        }
        return false;
    }

    public boolean performLongClick() {
        if (onLongClickListener != null) {
            return onLongClickListener.onLongClick(this);
        }
        return false;
    }

    public boolean dispatchKeyEvent(KeyEvent event) {
        if (onKeyListener != null) {
            return onKeyListener.onKey(this, event.getKeyCode(), event);
        }
        return false;
    }

    public void setFocused(boolean focused) {
        this.focused = focused;
        if (onFocusChangeListener != null) {
            onFocusChangeListener.onFocusChange(this, focused);
        }
    }

    public boolean isFocused() { return focused; }

    public void setVisibility(int v) { this.visibility = v; }
    public int getVisibility() { return visibility; }

    public void setBackgroundColor(int c) {}
    public void setBackground(Drawable d) { this.background = d; }
    public Drawable getBackground() { return background; }

    public View findViewById(int id) { return this; }

    public ViewPropertyAnimator animate() { return new ViewPropertyAnimator(); }
}
