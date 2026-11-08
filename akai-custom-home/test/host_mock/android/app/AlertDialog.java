package android.app;
import android.content.Context;
import android.content.DialogInterface;
public class AlertDialog {
    public static class Builder {
        public Builder(Context c, int t) {}
        public Builder setTitle(CharSequence t) { return this; }
        public Builder setItems(CharSequence[] i, DialogInterface.OnClickListener l) { return this; }
        public Builder setSingleChoiceItems(CharSequence[] i, int c, DialogInterface.OnClickListener l) { return this; }
        public Builder setNegativeButton(CharSequence t, DialogInterface.OnClickListener l) { return this; }
        public AlertDialog show() { return new AlertDialog(); }
    }
    public void dismiss() {}
}
