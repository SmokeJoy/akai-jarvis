package it.akai.customremote.ai;

import java.nio.ByteBuffer;

/**
 * Packs Android RGBA_8888 ImageReader plane rows without trusting final-row
 * padding. Pure Java for deterministic host tests; no image persistence.
 */
public final class RgbaFramePacker {
    private RgbaFramePacker() {}

    public static ByteBuffer pack(ByteBuffer plane, int width, int height,
                                  int rowStride, int pixelStride) {
        if (plane == null || !VisionCapturePolicy.withinBudget(width, height, 0)
                || pixelStride != 4 || rowStride < width * 4) {
            throw new IllegalArgumentException("Invalid RGBA frame layout");
        }
        int bytesPerRow = width * 4;
        int bytesTotal = bytesPerRow * height;
        ByteBuffer source = plane.duplicate();
        int originalLimit = source.limit();
        ByteBuffer result = ByteBuffer.allocateDirect(bytesTotal);
        for (int y = 0; y < height; y++) {
            long rowStart = (long) y * rowStride;
            if (rowStart < 0 || rowStart + bytesPerRow > originalLimit) {
                throw new IllegalArgumentException("RGBA row outside source buffer");
            }
            source.position((int) rowStart);
            source.limit((int) (rowStart + bytesPerRow));
            result.put(source);
            source.limit(originalLimit);
        }
        result.flip();
        return result;
    }
}
