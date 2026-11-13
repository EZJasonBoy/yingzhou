package android.os;

/**
 * Desktop Looper: a token. Handlers run their messages on a shared scheduler (see {@link Handler}), so there is no
 * real message loop; {@link #loop()} parks the calling thread until {@link #quit()} for code that expects it to block.
 */
public final class Looper {
    private static final Looper MAIN = new Looper(null);
    private static final ThreadLocal<Looper> CURRENT = new ThreadLocal<>();

    private final Thread thread;
    private volatile boolean quit;

    private Looper(Thread thread) {
        this.thread = thread;
    }

    public static void prepare() {
        if (CURRENT.get() == null) CURRENT.set(new Looper(Thread.currentThread()));
    }

    public static void prepareMainLooper() {
        CURRENT.set(MAIN);
    }

    public static Looper getMainLooper() {
        return MAIN;
    }

    public static Looper myLooper() {
        return CURRENT.get();
    }

    public static MessageQueue myQueue() {
        return new MessageQueue();
    }

    public static void loop() {
        Looper me = myLooper();
        if (me == null || me == MAIN) return;
        synchronized (me) {
            while (!me.quit) {
                try {
                    me.wait();
                } catch (InterruptedException e) {
                    return;
                }
            }
        }
    }

    public void quit() {
        synchronized (this) {
            quit = true;
            notifyAll();
        }
    }

    public void quitSafely() {
        quit();
    }

    public Thread getThread() {
        return thread != null ? thread : Thread.currentThread();
    }

    public boolean isCurrentThread() {
        return thread == null || thread == Thread.currentThread();
    }

    public MessageQueue getQueue() {
        return new MessageQueue();
    }

    public static final class MessageQueue {
        public boolean isIdle() {
            return true;
        }
    }
}
