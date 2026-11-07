package it.akai.customremote.qr;

import android.graphics.Bitmap;

public class QrBitmapUtil {
    public static Bitmap createQrBitmap(String text, int scale, int border) {
        if (text == null || text.isEmpty()) return null;
        try {
            QrCode qr = QrCode.encodeText(text, QrCode.Ecc.MEDIUM);
            int size = (qr.size + border * 2) * scale;
            Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.RGB_565);
            for (int y = 0; y < size; y++) {
                for (int x = 0; x < size; x++) {
                    int qrx = x / scale - border;
                    int qry = y / scale - border;
                    boolean black = (qrx >= 0 && qrx < qr.size && qry >= 0 && qry < qr.size) && qr.getModule(qrx, qry);
                    bitmap.setPixel(x, y, black ? 0xFF000000 : 0xFFFFFFFF);
                }
            }
            return bitmap;
        } catch (Exception e) {
            return null;
        }
    }
}
