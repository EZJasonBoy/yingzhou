package tvbox.engine.js.legacy;

import java.nio.charset.StandardCharsets;

/** Stand-in for android.util.Base64 with the behaviour the copied TVBox code relies on. */
public final class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;

    private Base64() {}

    /** Like Android: characters outside the alphabet (line breaks, spaces) are ignored. */
    public static byte[] decode(String str, int flags) {
        String s = (flags & URL_SAFE) != 0 ? str.replace('-', '+').replace('_', '/') : str;
        return java.util.Base64.getMimeDecoder().decode(s);
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(new String(input, StandardCharsets.ISO_8859_1), flags);
    }

    public static String encodeToString(byte[] input, int flags) {
        java.util.Base64.Encoder encoder = (flags & URL_SAFE) != 0 ? java.util.Base64.getUrlEncoder() : java.util.Base64.getEncoder();
        if ((flags & NO_PADDING) != 0) encoder = encoder.withoutPadding();
        String out = encoder.encodeToString(input);
        if ((flags & NO_WRAP) != 0) return out;
        // Android's default wraps at 76 characters and ends with a newline.
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < out.length(); i += 76) sb.append(out, i, Math.min(out.length(), i + 76)).append('\n');
        return sb.toString();
    }
}
