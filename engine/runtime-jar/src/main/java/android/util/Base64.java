package android.util;

import java.nio.charset.StandardCharsets;

/**
 * Android's Base64, with its quirks: DEFAULT output is wrapped at 76 characters and ends with a newline, and the
 * decoder skips every character outside the alphabet (whitespace, and '-'/'_' unless URL_SAFE).
 */
public final class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_PADDING = 1;
    public static final int NO_WRAP = 2;
    public static final int CRLF = 4;
    public static final int URL_SAFE = 8;
    public static final int NO_CLOSE = 16;

    private Base64() {
    }

    public static byte[] decode(String str, int flags) {
        return decode(str.getBytes(StandardCharsets.ISO_8859_1), flags);
    }

    public static byte[] decode(byte[] input, int flags) {
        return decode(input, 0, input.length, flags);
    }

    public static byte[] decode(byte[] input, int offset, int len, int flags) {
        boolean url = (flags & URL_SAFE) != 0;
        StringBuilder clean = new StringBuilder(len);
        for (int i = offset; i < offset + len; i++) {
            char c = (char) (input[i] & 0xff);
            boolean ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                    || (url ? (c == '-' || c == '_') : (c == '+' || c == '/'));
            if (ok) clean.append(c);
        }
        if (clean.length() % 4 == 1) throw new IllegalArgumentException("bad base-64");
        try {
            return (url ? java.util.Base64.getUrlDecoder() : java.util.Base64.getDecoder()).decode(clean.toString());
        } catch (IllegalArgumentException e) {
            throw new IllegalArgumentException("bad base-64", e);
        }
    }

    public static String encodeToString(byte[] input, int flags) {
        return new String(encode(input, flags), StandardCharsets.US_ASCII);
    }

    public static String encodeToString(byte[] input, int offset, int len, int flags) {
        return new String(encode(input, offset, len, flags), StandardCharsets.US_ASCII);
    }

    public static byte[] encode(byte[] input, int flags) {
        return encode(input, 0, input.length, flags);
    }

    public static byte[] encode(byte[] input, int offset, int len, int flags) {
        byte[] slice = new byte[len];
        System.arraycopy(input, offset, slice, 0, len);
        java.util.Base64.Encoder encoder = (flags & URL_SAFE) != 0 ? java.util.Base64.getUrlEncoder() : java.util.Base64.getEncoder();
        if ((flags & NO_PADDING) != 0) encoder = encoder.withoutPadding();
        String s = encoder.encodeToString(slice);
        if ((flags & NO_WRAP) == 0 && !s.isEmpty()) {
            String nl = (flags & CRLF) != 0 ? "\r\n" : "\n";
            StringBuilder b = new StringBuilder(s.length() + s.length() / 76 * nl.length() + nl.length());
            for (int i = 0; i < s.length(); i += 76) {
                b.append(s, i, Math.min(s.length(), i + 76)).append(nl);
            }
            s = b.toString();
        }
        return s.getBytes(StandardCharsets.US_ASCII);
    }
}
