package android.content.pm;

import android.content.IntentSender;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.Closeable;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.HashMap;
import java.util.Map;

public class PackageInstaller {
    public static final String EXTRA_SESSION_ID = "android.content.pm.extra.SESSION_ID";
    public static final String EXTRA_STATUS = "android.content.pm.extra.STATUS";
    public static final int STATUS_PENDING_USER_ACTION = -1;
    public static final int STATUS_SUCCESS = 0;
    public static final int STATUS_FAILURE = 1;

    private int nextSessionId = 100;
    private final Map<Integer, Session> sessions = new HashMap<>();

    public int createSessionCount;
    public int commitCount;
    public int abandonCount;
    public String lastAppPackageName;
    public long lastDeclaredSize = -1L;

    public static class SessionParams {
        public static final int MODE_FULL_INSTALL = 1;
        public final int mode;
        public String appPackageName;
        public long sizeBytes = -1L;

        public SessionParams(int mode) {
            this.mode = mode;
        }

        public void setAppPackageName(String appPackageName) {
            this.appPackageName = appPackageName;
        }

        public void setSize(long sizeBytes) {
            this.sizeBytes = sizeBytes;
        }
    }

    public synchronized int createSession(SessionParams params) throws IOException {
        createSessionCount++;
        if (params != null) {
            lastAppPackageName = params.appPackageName;
            lastDeclaredSize = params.sizeBytes;
        }
        int id = nextSessionId++;
        sessions.put(Integer.valueOf(id), new Session(this, id));
        return id;
    }

    public synchronized Session openSession(int sessionId) throws IOException {
        Session session = sessions.get(Integer.valueOf(sessionId));
        if (session == null) {
            throw new IOException("SESSION_NOT_FOUND_" + sessionId);
        }
        return session;
    }

    public synchronized void abandonSession(int sessionId) {
        Session session = sessions.remove(Integer.valueOf(sessionId));
        if (session != null && !session.abandoned && !session.committed) {
            session.abandoned = true;
            abandonCount++;
        }
    }

    public synchronized byte[] getLastCommittedBytes(String name) {
        if (sessions.isEmpty()) return null;
        Session latest = null;
        for (Session s : sessions.values()) {
            if (s.committed) latest = s;
        }
        if (latest == null) return null;
        ByteArrayOutputStream baos = latest.streams.get(name);
        return baos != null ? baos.toByteArray() : null;
    }

    public static class Session implements Closeable {
        private final PackageInstaller owner;
        private final int sessionId;
        private final Map<String, ByteArrayOutputStream> streams = new HashMap<>();
        private boolean committed;
        private boolean abandoned;

        Session(PackageInstaller owner, int sessionId) {
            this.owner = owner;
            this.sessionId = sessionId;
        }

        public OutputStream openWrite(String name, long offsetBytes, long lengthBytes)
                throws IOException {
            if (abandoned || committed) throw new IOException("SESSION_CLOSED");
            if (offsetBytes != 0L) throw new IOException("NONZERO_OFFSET_UNSUPPORTED");
            final ByteArrayOutputStream baos = new ByteArrayOutputStream();
            streams.put(name, baos);
            return new OutputStream() {
                @Override
                public void write(int b) {
                    baos.write(b);
                }

                @Override
                public void write(byte[] b, int off, int len) {
                    baos.write(b, off, len);
                }
            };
        }

        public void fsync(OutputStream out) throws IOException {
            if (out != null) out.flush();
        }

        public InputStream openRead(String name) throws IOException {
            ByteArrayOutputStream baos = streams.get(name);
            if (baos == null) throw new IOException("SESSION_ENTRY_MISSING_" + name);
            return new ByteArrayInputStream(baos.toByteArray());
        }

        public void commit(IntentSender statusReceiver) {
            if (abandoned || statusReceiver == null) return;
            synchronized (owner) {
                committed = true;
                owner.commitCount++;
            }
        }

        public void abandon() {
            owner.abandonSession(sessionId);
        }

        @Override
        public void close() {}
    }
}
