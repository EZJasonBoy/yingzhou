package android.graphics;

import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.nio.Buffer;
import java.nio.ByteBuffer;
import java.nio.IntBuffer;

import javax.imageio.ImageIO;

/** Bitmap backed by a {@link BufferedImage} (headless AWT), enough for spiders that read captcha pixels. */
public final class Bitmap {

    public enum Config { ALPHA_8, RGB_565, ARGB_4444, ARGB_8888, RGBA_F16, HARDWARE }

    public enum CompressFormat { JPEG, PNG, WEBP, WEBP_LOSSY, WEBP_LOSSLESS }

    private BufferedImage image;
    private final Config config;
    private boolean mutable;

    Bitmap(BufferedImage image, Config config, boolean mutable) {
        this.image = image;
        this.config = config == null ? Config.ARGB_8888 : config;
        this.mutable = mutable;
    }

    static Bitmap decode(byte[] data) {
        try {
            BufferedImage img = ImageIO.read(new ByteArrayInputStream(data));
            if (img == null) return null;
            BufferedImage argb = new BufferedImage(img.getWidth(), img.getHeight(), BufferedImage.TYPE_INT_ARGB);
            argb.getGraphics().drawImage(img, 0, 0, null);
            return new Bitmap(argb, Config.ARGB_8888, false);
        } catch (Exception e) {
            return null;
        }
    }

    public static Bitmap createBitmap(int width, int height, Config config) {
        return new Bitmap(new BufferedImage(Math.max(1, width), Math.max(1, height), BufferedImage.TYPE_INT_ARGB), config, true);
    }

    public static Bitmap createBitmap(int[] colors, int width, int height, Config config) {
        Bitmap b = createBitmap(width, height, config);
        b.image.setRGB(0, 0, width, height, colors, 0, width);
        b.mutable = false;
        return b;
    }

    public static Bitmap createBitmap(Bitmap source) {
        return source.copy(source.config, false);
    }

    public static Bitmap createBitmap(Bitmap source, int x, int y, int width, int height) {
        BufferedImage sub = source.image.getSubimage(x, y, width, height);
        BufferedImage copy = new BufferedImage(width, height, BufferedImage.TYPE_INT_ARGB);
        copy.getGraphics().drawImage(sub, 0, 0, null);
        return new Bitmap(copy, source.config, false);
    }

    public static Bitmap createScaledBitmap(Bitmap src, int dstWidth, int dstHeight, boolean filter) {
        BufferedImage out = new BufferedImage(Math.max(1, dstWidth), Math.max(1, dstHeight), BufferedImage.TYPE_INT_ARGB);
        out.getGraphics().drawImage(src.image.getScaledInstance(dstWidth, dstHeight,
                filter ? java.awt.Image.SCALE_SMOOTH : java.awt.Image.SCALE_FAST), 0, 0, null);
        return new Bitmap(out, src.config, true);
    }

    public int getWidth() {
        return image.getWidth();
    }

    public int getHeight() {
        return image.getHeight();
    }

    public Config getConfig() {
        return config;
    }

    public boolean isMutable() {
        return mutable;
    }

    public int getPixel(int x, int y) {
        return image.getRGB(x, y);
    }

    public void setPixel(int x, int y, int color) {
        image.setRGB(x, y, color);
    }

    public void getPixels(int[] pixels, int offset, int stride, int x, int y, int width, int height) {
        image.getRGB(x, y, width, height, pixels, offset, stride);
    }

    public void setPixels(int[] pixels, int offset, int stride, int x, int y, int width, int height) {
        image.setRGB(x, y, width, height, pixels, offset, stride);
    }

    public int getByteCount() {
        return getWidth() * getHeight() * 4;
    }

    public int getRowBytes() {
        return getWidth() * 4;
    }

    public void copyPixelsToBuffer(Buffer dst) {
        int[] px = image.getRGB(0, 0, getWidth(), getHeight(), null, 0, getWidth());
        if (dst instanceof IntBuffer) {
            ((IntBuffer) dst).put(px);
        } else if (dst instanceof ByteBuffer) {
            ByteBuffer b = (ByteBuffer) dst;
            for (int p : px) {
                b.put((byte) (p >> 16)).put((byte) (p >> 8)).put((byte) p).put((byte) (p >>> 24));
            }
        }
    }

    public boolean compress(CompressFormat format, int quality, OutputStream stream) {
        try {
            String type = format == CompressFormat.JPEG ? "jpg" : "png";
            BufferedImage img = image;
            if (format == CompressFormat.JPEG) {
                img = new BufferedImage(getWidth(), getHeight(), BufferedImage.TYPE_INT_RGB);
                img.getGraphics().drawImage(image, 0, 0, null);
            }
            return ImageIO.write(img, type, stream);
        } catch (Exception e) {
            return false;
        }
    }

    public Bitmap copy(Config config, boolean isMutable) {
        BufferedImage copy = new BufferedImage(getWidth(), getHeight(), BufferedImage.TYPE_INT_ARGB);
        copy.getGraphics().drawImage(image, 0, 0, null);
        return new Bitmap(copy, config, isMutable);
    }

    public byte[] toPng() {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        compress(CompressFormat.PNG, 100, out);
        return out.toByteArray();
    }

    public void eraseColor(int color) {
        for (int y = 0; y < getHeight(); y++) for (int x = 0; x < getWidth(); x++) image.setRGB(x, y, color);
    }

    public boolean hasAlpha() {
        return true;
    }

    public void recycle() {
    }

    public boolean isRecycled() {
        return false;
    }

    public BufferedImage asBufferedImage() {
        return image;
    }
}
