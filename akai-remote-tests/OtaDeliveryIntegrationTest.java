package it.akai.customremote.ai;

import android.content.ContentResolver;
import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.content.pm.SigningInfo;
import android.content.res.AssetManager;
import android.os.Looper;

import java.io.BufferedInputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PublicKey;
import java.security.cert.Certificate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLServerSocket;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManagerFactory;

/**
 * Host-only vertical OTA delivery & verification integration harness.
 *
 * Uses ONLY ephemeral host/test PKCS12 & RSA-3072 staging keys over a local
 * 127.0.0.1 TLS fixture socket while exercising the real Android client pipeline
 * (OtaReleaseChannel, OtaReleaseTrust, OtaUpdatePreparation, OtaHttpsTransport,
 * OtaSignedReleaseManifest, OtaStagingCommit, OtaAndroidArchiveInspector,
 * OtaAndroidInstallPreflight, OtaOwnerPackageInstaller).
 *
 * IMPORTANT: Host fixture PASS NEVER implies OTA_PROVISIONED_READY, never proves
 * owner release signing keys, and is NOT a physical AKAI TV or PC-off OTA PASS.
 */
public final class OtaDeliveryIntegrationTest {
    private static final String STAGING_HOST = "staging-ota.akai-jarvis.example";
    private static final String MANIFEST_PATH = "/staging/jarvis.manifest";
    private static final String SIG_PATH = "/staging/jarvis.manifest.sig";
    private static final String MANIFEST_URL = "https://" + STAGING_HOST + MANIFEST_PATH;

    private static int checks;

    private OtaDeliveryIntegrationTest() {}

    private static void check(boolean cond, String msg) {
        if (!cond) {
            throw new AssertionError("OTA_INTEGRATION_FAIL: " + msg);
        }
        checks++;
    }

    private static String sha256Hex(byte[] data) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(data);
        StringBuilder sb = new StringBuilder(digest.length * 2);
        for (byte b : digest) {
            sb.append(String.format(Locale.ROOT, "%02x", b & 0xff));
        }
        return sb.toString();
    }

    private static String sha256File(File file) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        try (FileInputStream in = new FileInputStream(file)) {
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) != -1) {
                md.update(buf, 0, n);
            }
        }
        byte[] digest = md.digest();
        StringBuilder sb = new StringBuilder(digest.length * 2);
        for (byte b : digest) {
            sb.append(String.format(Locale.ROOT, "%02x", b & 0xff));
        }
        return sb.toString();
    }

    private static byte[] deterministicApkBytes(int seed, int length) {
        byte[] data = new byte[length];
        data[0] = 'P';
        data[1] = 'K';
        data[2] = 0x03;
        data[3] = 0x04;
        for (int i = 4; i < length; i++) {
            data[i] = (byte) ((seed * 31 + i) & 0xff);
        }
        return data;
    }

    private static File[] listStagingFiles(File filesDir, final String suffix) {
        File staging = new File(filesDir, "ota-staging");
        if (!staging.isDirectory()) return new File[0];
        File[] matches = staging.listFiles(new java.io.FilenameFilter() {
            @Override
            public boolean accept(File dir, String name) {
                return name.endsWith(suffix);
            }
        });
        return matches != null ? matches : new File[0];
    }

    private static void generateEphemeralPkcs12(Path keystorePath, char[] password,
                                                String alias, String dname,
                                                String sanExt) throws Exception {
        String keytoolBin = System.getProperty("java.home") + File.separator + "bin"
                + File.separator + "keytool";
        if (System.getProperty("os.name", "").toLowerCase(Locale.ROOT).contains("win")) {
            File exe = new File(keytoolBin + ".exe");
            if (exe.isFile()) keytoolBin = exe.getAbsolutePath();
        }
        List<String> cmd = new ArrayList<>();
        cmd.add(keytoolBin);
        cmd.add("-genkeypair");
        cmd.add("-alias");
        cmd.add(alias);
        cmd.add("-keyalg");
        cmd.add("RSA");
        cmd.add("-keysize");
        cmd.add("2048");
        cmd.add("-validity");
        cmd.add("1");
        cmd.add("-keystore");
        cmd.add(keystorePath.toAbsolutePath().toString());
        cmd.add("-storetype");
        cmd.add("PKCS12");
        cmd.add("-storepass");
        cmd.add(new String(password));
        cmd.add("-keypass");
        cmd.add(new String(password));
        cmd.add("-dname");
        cmd.add(dname);
        if (sanExt != null) {
            cmd.add("-ext");
            cmd.add(sanExt);
        }
        cmd.add("-noprompt");

        Process proc = new ProcessBuilder(cmd).redirectErrorStream(true).start();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (InputStream in = proc.getInputStream()) {
            byte[] buf = new byte[1024];
            int n;
            while ((n = in.read(buf)) != -1) out.write(buf, 0, n);
        }
        int exit = proc.waitFor();
        if (exit != 0) {
            throw new IllegalStateException("keytool failed (" + exit + "): "
                    + new String(out.toByteArray(), StandardCharsets.UTF_8));
        }
    }

    private static final class SignedArtifact {
        final int versionCode;
        final String apkPath;
        final byte[] apkBytes;
        final String apkSha256;
        final byte[] manifestBytes;
        final byte[] signatureBytes;

        SignedArtifact(int versionCode, String apkPath, byte[] apkBytes, String apkSha256,
                       byte[] manifestBytes, byte[] signatureBytes) {
            this.versionCode = versionCode;
            this.apkPath = apkPath;
            this.apkBytes = apkBytes;
            this.apkSha256 = apkSha256;
            this.manifestBytes = manifestBytes;
            this.signatureBytes = signatureBytes;
        }

        OtaCandidateGate.Candidate toCandidate() {
            return new OtaCandidateGate.Candidate(
                    OtaCandidateGate.PACKAGE,
                    versionCode,
                    "",
                    apkSha256,
                    "https://" + STAGING_HOST + apkPath,
                    "armeabi-v7a",
                    21,
                    apkBytes.length,
                    "stable");
        }
    }

    private static SignedArtifact buildSignedArtifact(KeyPair manifestSigningKey,
                                                      String signerCertSha256,
                                                      int versionCode,
                                                      String apkPath,
                                                      byte[] apkBytes) throws Exception {
        String apkSha256 = sha256Hex(apkBytes);
        String manifestText = "format=jarvis-ota-v1\n"
                + "package=" + OtaCandidateGate.PACKAGE + "\n"
                + "versionCode=" + versionCode + "\n"
                + "signerSha256=" + signerCertSha256 + "\n"
                + "apkSha256=" + apkSha256 + "\n"
                + "url=https://" + STAGING_HOST + apkPath + "\n"
                + "abi=armeabi-v7a\n"
                + "minSdk=21\n"
                + "sizeBytes=" + apkBytes.length + "\n"
                + "channel=stable\n";
        byte[] manifestBytes = manifestText.getBytes(StandardCharsets.US_ASCII);
        java.security.Signature signer = java.security.Signature.getInstance("SHA256withRSA");
        signer.initSign(manifestSigningKey.getPrivate());
        signer.update(manifestBytes);
        byte[] sigBytes = signer.sign();
        return new SignedArtifact(versionCode, apkPath, apkBytes, apkSha256, manifestBytes, sigBytes);
    }

    private static byte[] buildSignedEvidenceReceipt(String channelProfile,
                                                     String deviceUid,
                                                     int installedVersion,
                                                     String backupId,
                                                     long createdEpochSec,
                                                     long expiresEpochSec,
                                                     String backupArchiveSha256,
                                                     int priorRescueFloorVersionCode,
                                                     int recoveryRescueVersionCode,
                                                     String rescueApkSha256,
                                                     boolean offlineRestoreVerified,
                                                     boolean nonDestructiveVerified) {
        String text = "format=jarvis-ota-evidence-v2\n"
                + "package=" + OtaCandidateGate.PACKAGE + "\n"
                + "channelProfile=" + channelProfile + "\n"
                + "deviceUid=" + deviceUid + "\n"
                + "installedVersionCode=" + installedVersion + "\n"
                + "backupId=" + backupId + "\n"
                + "backupCreatedEpochSec=" + createdEpochSec + "\n"
                + "backupExpiresEpochSec=" + expiresEpochSec + "\n"
                + "backupArchiveSha256=" + backupArchiveSha256 + "\n"
                + "priorRescueFloorVersionCode=" + priorRescueFloorVersionCode + "\n"
                + "recoveryRescueVersionCode=" + recoveryRescueVersionCode + "\n"
                + "rescueApkSha256=" + rescueApkSha256 + "\n"
                + "offlineRestoreVerified=" + offlineRestoreVerified + "\n"
                + "nonDestructiveVerified=" + nonDestructiveVerified + "\n";
        return text.getBytes(StandardCharsets.US_ASCII);
    }

    private static byte[] signDetachedRsa(byte[] payload, KeyPair signingKey) throws Exception {
        java.security.Signature signer = java.security.Signature.getInstance("SHA256withRSA");
        signer.initSign(signingKey.getPrivate());
        signer.update(payload);
        return signer.sign();
    }

    private static void writeRawEvidenceFiles(File filesDir, byte[] receiptBytes, byte[] sigBytes)
            throws IOException {
        File dir = new File(filesDir, OtaRecoveryEvidenceStore.EVIDENCE_SUBDIR);
        if (!dir.isDirectory() && !dir.mkdirs()) {
            throw new IOException("Could not create evidence dir");
        }
        Files.write(new File(dir, OtaRecoveryEvidenceStore.RECEIPT_FILENAME).toPath(), receiptBytes);
        Files.write(new File(dir, OtaRecoveryEvidenceStore.SIGNATURE_FILENAME).toPath(), sigBytes);
    }

    private static void writeLocalBackupArchive(File filesDir, byte[] archiveBytes) throws IOException {
        File dir = new File(filesDir, OtaRecoveryEvidenceStore.EVIDENCE_SUBDIR);
        if (!dir.isDirectory() && !dir.mkdirs()) {
            throw new IOException("Could not create evidence dir");
        }
        Files.write(new File(dir, OtaRecoveryEvidenceStore.LOCAL_ARCHIVE_FILENAME).toPath(), archiveBytes);
    }

    private static void clearEvidenceFiles(File filesDir) {
        File dir = new File(filesDir, OtaRecoveryEvidenceStore.EVIDENCE_SUBDIR);
        if (!dir.isDirectory()) return;
        File[] items = dir.listFiles();
        if (items != null) {
            for (File f : items) f.delete();
        }
    }

    private static final class TestArchiveCatalog {
        final byte[] installedCertBytes;
        final String signerSha256;
        final Map<String, PackageInfo> archivesByApkSha256 = new HashMap<>();

        TestArchiveCatalog(byte[] installedCertBytes, String signerSha256) {
            this.installedCertBytes = installedCertBytes.clone();
            this.signerSha256 = signerSha256;
        }

        void registerApkArchive(String apkSha256, String pkg, int versionCode,
                                int minSdk, int targetSdk, byte[] certBytes) {
            PackageInfo info = new PackageInfo();
            info.packageName = pkg;
            info.setLongVersionCode(versionCode);
            ApplicationInfo app = new ApplicationInfo(pkg);
            app.minSdkVersion = minSdk;
            app.targetSdkVersion = targetSdk;
            info.applicationInfo = app;
            info.signingInfo = new SigningInfo(false, new Signature[]{new Signature(certBytes)});
            archivesByApkSha256.put(apkSha256.toLowerCase(Locale.ROOT), info);
        }

        PackageInfo buildInstalledInfo(int versionCode) {
            PackageInfo info = new PackageInfo();
            info.packageName = OtaCandidateGate.PACKAGE;
            info.setLongVersionCode(versionCode);
            ApplicationInfo app = new ApplicationInfo(OtaCandidateGate.PACKAGE);
            app.minSdkVersion = 21;
            app.targetSdkVersion = 28;
            info.applicationInfo = app;
            info.signingInfo = new SigningInfo(false, new Signature[]{new Signature(installedCertBytes)});
            return info;
        }
    }

    private static final class TestPackageManager extends PackageManager {
        private final TestArchiveCatalog catalog;
        private final int installedVersionCode;
        private final PackageInstaller installer = new PackageInstaller();
        private boolean canRequestInstalls;

        TestPackageManager(TestArchiveCatalog catalog, int installedVersionCode,
                           boolean canRequestInstalls) {
            this.catalog = catalog;
            this.installedVersionCode = installedVersionCode;
            this.canRequestInstalls = canRequestInstalls;
        }

        @Override
        public PackageInfo getPackageInfo(String packageName, int flags)
                throws NameNotFoundException {
            if (OtaCandidateGate.PACKAGE.equals(packageName)
                    && (flags & GET_SIGNING_CERTIFICATES) != 0) {
                return catalog.buildInstalledInfo(installedVersionCode);
            }
            throw new NameNotFoundException(packageName);
        }

        @Override
        public PackageInfo getPackageArchiveInfo(String archiveFilePath, int flags) {
            if (archiveFilePath == null || (flags & GET_SIGNING_CERTIFICATES) == 0) {
                return null;
            }
            File file = new File(archiveFilePath);
            if (!file.isFile()) return null;
            try {
                String actualSha = sha256File(file).toLowerCase(Locale.ROOT);
                return catalog.archivesByApkSha256.get(actualSha);
            } catch (Exception e) {
                return null;
            }
        }

        @Override
        public boolean canRequestPackageInstalls() {
            return canRequestInstalls;
        }

        @Override
        public PackageInstaller getPackageInstaller() {
            return installer;
        }
    }

    private static final class TestClientContext extends Context {
        private final File filesDir;
        private final TestPackageManager packageManager;
        private final AssetManager assetManager;
        private final ContentResolver contentResolver;

        TestClientContext(File filesDir,
                          final String channelManifestUrl,
                          final byte[] bundledPublicKeyDer,
                          TestPackageManager packageManager) {
            this(filesDir, channelManifestUrl, bundledPublicKeyDer,
                    packageManager, "akai-tv-fixture-uid-001");
        }

        TestClientContext(File filesDir,
                          final String channelManifestUrl,
                          final byte[] bundledPublicKeyDer,
                          TestPackageManager packageManager,
                          String deviceUid) {
            this.filesDir = filesDir;
            this.packageManager = packageManager;
            this.contentResolver = new ContentResolver(deviceUid);
            this.assetManager = new AssetManager() {
                @Override
                public InputStream open(String fileName) throws IOException {
                    if ("ota-release-channel.txt".equals(fileName) && channelManifestUrl != null) {
                        return new ByteArrayInputStream(
                                (channelManifestUrl + "\n").getBytes(StandardCharsets.US_ASCII));
                    }
                    if ("ota-release-public.der".equals(fileName) && bundledPublicKeyDer != null) {
                        return new ByteArrayInputStream(bundledPublicKeyDer.clone());
                    }
                    throw new FileNotFoundException(fileName);
                }
            };
        }

        @Override
        public File getFilesDir() {
            return filesDir;
        }

        @Override
        public String getPackageName() {
            return OtaCandidateGate.PACKAGE;
        }

        @Override
        public PackageManager getPackageManager() {
            return packageManager;
        }

        @Override
        public AssetManager getAssets() {
            return assetManager;
        }

        @Override
        public ContentResolver getContentResolver() {
            return contentResolver;
        }
    }

    private enum ApkFault {
        NONE,
        CORRUPT_DIGEST,
        REDIRECT_307,
        TRUNCATE_HALF,
        STALL_TIMEOUT,
        PACE_FOR_INTERRUPT
    }

    private static final class LocalOtaTlsFixture implements AutoCloseable {
        private final SSLServerSocket serverSocket;
        private final SSLContext clientSslContext;
        private final ExecutorService workers = Executors.newCachedThreadPool();
        private final AtomicBoolean closed = new AtomicBoolean(false);

        final AtomicInteger manifestHits = new AtomicInteger(0);
        final AtomicInteger sigHits = new AtomicInteger(0);
        final AtomicInteger apkHits = new AtomicInteger(0);
        final List<String> requestedPaths = new CopyOnWriteArrayList<>();
        final List<String> openerUrls = new CopyOnWriteArrayList<>();

        private volatile byte[] manifestBody = new byte[0];
        private volatile byte[] sigBody = new byte[0];
        private volatile String expectedApkPath = "/staging/jarvis-v7.apk";
        private volatile byte[] apkBody = new byte[0];
        private volatile boolean redirectManifest302;
        private volatile boolean delayManifestForTimeout;
        private volatile ApkFault apkFault = ApkFault.NONE;
        private volatile CountDownLatch slowApkStartedLatch;

        LocalOtaTlsFixture(Path tempDir) throws Exception {
            char[] pass = "ephemeral-fixture-pass".toCharArray();
            Path tlsStorePath = tempDir.resolve("tls-fixture.p12");
            generateEphemeralPkcs12(
                    tlsStorePath,
                    pass,
                    "tlshost",
                    "CN=" + STAGING_HOST,
                    "SAN=DNS:" + STAGING_HOST + ",IP:127.0.0.1");

            KeyStore ks = KeyStore.getInstance("PKCS12");
            try (InputStream in = Files.newInputStream(tlsStorePath)) {
                ks.load(in, pass);
            }

            KeyManagerFactory kmf = KeyManagerFactory.getInstance(
                    KeyManagerFactory.getDefaultAlgorithm());
            kmf.init(ks, pass);
            SSLContext serverCtx = SSLContext.getInstance("TLS");
            serverCtx.init(kmf.getKeyManagers(), null, null);

            KeyStore trustStore = KeyStore.getInstance("PKCS12");
            trustStore.load(null, null);
            Certificate serverCert = ks.getCertificate("tlshost");
            trustStore.setCertificateEntry("tlshost", serverCert);
            TrustManagerFactory tmf = TrustManagerFactory.getInstance(
                    TrustManagerFactory.getDefaultAlgorithm());
            tmf.init(trustStore);
            this.clientSslContext = SSLContext.getInstance("TLS");
            this.clientSslContext.init(null, tmf.getTrustManagers(), null);

            this.serverSocket = (SSLServerSocket) serverCtx.getServerSocketFactory()
                    .createServerSocket(0, 16, InetAddress.getByName("127.0.0.1"));

            Thread acceptThread = new Thread(new Runnable() {
                @Override
                public void run() {
                    while (!closed.get()) {
                        try {
                            final SSLSocket socket = (SSLSocket) serverSocket.accept();
                            workers.submit(new Runnable() {
                                @Override
                                public void run() {
                                    handleClient(socket);
                                }
                            });
                        } catch (IOException e) {
                            if (!closed.get()) {
                                // ignore transient accept failure until close
                            }
                        }
                    }
                }
            }, "ota-tls-fixture-accept");
            acceptThread.setDaemon(true);
            acceptThread.start();
        }

        int getPort() {
            return serverSocket.getLocalPort();
        }

        void resetCountersAndFaults() {
            manifestHits.set(0);
            sigHits.set(0);
            apkHits.set(0);
            requestedPaths.clear();
            openerUrls.clear();
            redirectManifest302 = false;
            delayManifestForTimeout = false;
            apkFault = ApkFault.NONE;
            slowApkStartedLatch = null;
        }

        void serveArtifact(SignedArtifact artifact, byte[] customSigBody) {
            this.manifestBody = artifact.manifestBytes;
            this.sigBody = (customSigBody != null) ? customSigBody : artifact.signatureBytes;
            this.expectedApkPath = artifact.apkPath;
            this.apkBody = artifact.apkBytes;
        }

        OtaHttpsTransport.ConnectionOpener opener(final int readTimeoutMs) {
            return new OtaHttpsTransport.ConnectionOpener() {
                @Override
                public HttpsURLConnection open(String validatedUrl) throws IOException {
                    openerUrls.add(validatedUrl);
                    URI uri;
                    try {
                        uri = new URI(validatedUrl);
                    } catch (Exception e) {
                        throw new IOException("INVALID_URL", e);
                    }
                    if (!STAGING_HOST.equalsIgnoreCase(uri.getHost())) {
                        throw new IOException("UNEXPECTED_NON_STAGING_HOST_" + uri.getHost());
                    }
                    String target = "https://127.0.0.1:" + getPort() + uri.getRawPath();
                    if (uri.getRawQuery() != null) {
                        target += "?" + uri.getRawQuery();
                    }
                    HttpsURLConnection conn = (HttpsURLConnection) new URL(target).openConnection();
                    conn.setSSLSocketFactory(clientSslContext.getSocketFactory());
                    conn.setRequestMethod("GET");
                    conn.setConnectTimeout(1500);
                    conn.setReadTimeout(readTimeoutMs);
                    conn.setUseCaches(false);
                    conn.setInstanceFollowRedirects(false);
                    conn.setRequestProperty("Host", uri.getHost());
                    conn.setRequestProperty("Accept-Encoding", "identity");
                    return conn;
                }
            };
        }

        private void handleClient(SSLSocket socket) {
            try (SSLSocket s = socket) {
                s.setSoTimeout(4000);
                BufferedInputStream in = new BufferedInputStream(s.getInputStream());
                String requestLine = readAsciiLine(in);
                if (requestLine == null) return;
                String line;
                while ((line = readAsciiLine(in)) != null && !line.isEmpty()) {
                    // consume headers
                }
                String[] parts = requestLine.split(" ");
                String rawPath = parts.length >= 2 ? parts[1] : "/";
                requestedPaths.add(rawPath);

                OutputStream out = s.getOutputStream();
                if (MANIFEST_PATH.equals(rawPath)) {
                    manifestHits.incrementAndGet();
                    if (redirectManifest302) {
                        writeHttp(out, "302 Found",
                                "Location: https://redirected-attacker.example/evil.manifest\r\n",
                                "redirect".getBytes(StandardCharsets.US_ASCII));
                        return;
                    }
                    if (delayManifestForTimeout) {
                        sleepQuietly(1800L);
                    }
                    writeHttp(out, "200 OK", "", manifestBody);
                } else if (SIG_PATH.equals(rawPath)) {
                    sigHits.incrementAndGet();
                    writeHttp(out, "200 OK", "", sigBody);
                } else if (expectedApkPath.equals(rawPath)) {
                    apkHits.incrementAndGet();
                    if (apkFault == ApkFault.REDIRECT_307) {
                        writeHttp(out, "307 Temporary Redirect",
                                "Location: https://redirected-attacker.example/evil.apk\r\n",
                                "redirect".getBytes(StandardCharsets.US_ASCII));
                        return;
                    }
                    if (apkFault == ApkFault.TRUNCATE_HALF) {
                        int full = apkBody.length;
                        byte[] half = Arrays.copyOf(apkBody, full / 2);
                        String hdr = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                                + "Content-Length: " + full + "\r\nConnection: close\r\n\r\n";
                        out.write(hdr.getBytes(StandardCharsets.US_ASCII));
                        out.write(half);
                        out.flush();
                        return;
                    }
                    if (apkFault == ApkFault.STALL_TIMEOUT) {
                        String hdr = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                                + "Content-Length: " + apkBody.length + "\r\nConnection: close\r\n\r\n";
                        out.write(hdr.getBytes(StandardCharsets.US_ASCII));
                        out.write(apkBody, 0, Math.min(512, apkBody.length));
                        out.flush();
                        sleepQuietly(1800L);
                        return;
                    }
                    if (apkFault == ApkFault.PACE_FOR_INTERRUPT) {
                        String hdr = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                                + "Content-Length: " + apkBody.length + "\r\nConnection: close\r\n\r\n";
                        out.write(hdr.getBytes(StandardCharsets.US_ASCII));
                        int offset = 0;
                        int step = 128;
                        int firstChunk = Math.min(1024, apkBody.length);
                        out.write(apkBody, offset, firstChunk);
                        out.flush();
                        offset += firstChunk;
                        if (slowApkStartedLatch != null) slowApkStartedLatch.countDown();
                        while (offset < apkBody.length && !closed.get()) {
                            sleepQuietly(25L);
                            int len = Math.min(step, apkBody.length - offset);
                            out.write(apkBody, offset, len);
                            out.flush();
                            offset += len;
                        }
                        return;
                    }
                    byte[] body = apkBody;
                    if (apkFault == ApkFault.CORRUPT_DIGEST) {
                        body = apkBody.clone();
                        body[body.length / 2] ^= 0x55;
                    }
                    writeHttp(out, "200 OK", "", body);
                } else {
                    writeHttp(out, "404 Not Found", "", "not found".getBytes(StandardCharsets.US_ASCII));
                }
            } catch (IOException ignored) {
                // Expected on abrupt close/timeout/cancellation tests
            }
        }

        private static void writeHttp(OutputStream out, String status, String extraHeaders,
                                      byte[] body) throws IOException {
            String header = "HTTP/1.1 " + status + "\r\n"
                    + "Content-Type: application/octet-stream\r\n"
                    + "Content-Length: " + body.length + "\r\n"
                    + extraHeaders
                    + "Connection: close\r\n\r\n";
            out.write(header.getBytes(StandardCharsets.US_ASCII));
            out.write(body);
            out.flush();
        }

        private static String readAsciiLine(InputStream in) throws IOException {
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            int b;
            while ((b = in.read()) != -1) {
                if (b == '\n') break;
                if (b != '\r') buf.write(b);
            }
            if (b == -1 && buf.size() == 0) return null;
            return new String(buf.toByteArray(), StandardCharsets.US_ASCII);
        }

        private static void sleepQuietly(long ms) {
            try {
                Thread.sleep(ms);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        }

        @Override
        public void close() throws IOException {
            closed.set(true);
            try {
                serverSocket.close();
            } finally {
                workers.shutdownNow();
            }
        }
    }

    private static int findDeadLoopbackPort() throws IOException {
        try (ServerSocket socket = new ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))) {
            return socket.getLocalPort();
        }
    }

    private static void deleteTree(Path root) {
        if (root == null || !Files.exists(root)) return;
        try {
            List<Path> paths = new ArrayList<>();
            Files.walk(root).forEach(paths::add);
            Collections.sort(paths, Comparator.reverseOrder());
            for (Path p : paths) {
                Files.deleteIfExists(p);
            }
        } catch (IOException ignored) {
        }
    }

    public static void main(String[] args) throws Exception {
        Path workRoot = Files.createTempDirectory("jarvis_ota_delivery_it_");
        try {
            // Ensure test main thread does not impersonate Android main Looper unless explicitly tested
            Looper.setCurrentAsMainLooperForTest(false);

            // 1) Ephemeral APK signer X.509 cert (STRICTLY distinct from OtaCandidateGate.EXPECTED_SIGNER_SHA256)
            Path apkStorePath = workRoot.resolve("ephemeral-apk-signer.p12");
            char[] apkPass = "ephemeral-apk-pass".toCharArray();
            generateEphemeralPkcs12(
                    apkStorePath,
                    apkPass,
                    "stagingapk",
                    "CN=JARVIS Ephemeral Staging Fixture",
                    null);
            KeyStore apkKs = KeyStore.getInstance("PKCS12");
            try (InputStream in = Files.newInputStream(apkStorePath)) {
                apkKs.load(in, apkPass);
            }
            byte[] stagingApkCertBytes = apkKs.getCertificate("stagingapk").getEncoded();
            String stagingApkSignerSha = sha256Hex(stagingApkCertBytes);
            check(!OtaCandidateGate.EXPECTED_SIGNER_SHA256.equalsIgnoreCase(stagingApkSignerSha),
                    "Staging fixture APK signer MUST remain strictly distinct from production EXPECTED_SIGNER_SHA256");

            // 2) Ephemeral RSA-3072 staging manifest signing keypair
            KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA");
            kpg.initialize(3072);
            KeyPair stagingManifestKey = kpg.generateKeyPair();
            byte[] bundledPublicDer = stagingManifestKey.getPublic().getEncoded();

            byte[] v7Bytes = deterministicApkBytes(7, 4096);
            byte[] v8Bytes = deterministicApkBytes(8, 16384);
            SignedArtifact v5Downgrade = buildSignedArtifact(
                    stagingManifestKey, stagingApkSignerSha, 5,
                    "/staging/jarvis-v5.apk", deterministicApkBytes(5, 2048));
            SignedArtifact v6Replay = buildSignedArtifact(
                    stagingManifestKey, stagingApkSignerSha, 6,
                    "/staging/jarvis-v6.apk", deterministicApkBytes(6, 2048));
            SignedArtifact v7Artifact = buildSignedArtifact(
                    stagingManifestKey, stagingApkSignerSha, 7,
                    "/staging/jarvis-v7.apk", v7Bytes);
            SignedArtifact v8Artifact = buildSignedArtifact(
                    stagingManifestKey, stagingApkSignerSha, 8,
                    "/staging/jarvis-v8.apk", v8Bytes);

            TestArchiveCatalog catalog = new TestArchiveCatalog(stagingApkCertBytes, stagingApkSignerSha);
            catalog.registerApkArchive(v7Artifact.apkSha256, OtaCandidateGate.PACKAGE, 7, 21, 28, stagingApkCertBytes);
            catalog.registerApkArchive(v8Artifact.apkSha256, OtaCandidateGate.PACKAGE, 8, 21, 28, stagingApkCertBytes);

            try (LocalOtaTlsFixture server = new LocalOtaTlsFixture(workRoot)) {
                OtaHttpsTransport.ConnectionOpener normalOpener = server.opener(2500);
                OtaHttpsTransport.ConnectionOpener shortTimeoutOpener = server.opener(350);

                // Scenario 1: Valid signed manifest with pinned ephemeral key + SHA-256 streamed APK
                File clientFiles1 = workRoot.resolve("client-s1").toFile();
                clientFiles1.mkdirs();
                TestPackageManager pm1 = new TestPackageManager(catalog, 6, true);
                TestClientContext ctx1 = new TestClientContext(
                        clientFiles1, MANIFEST_URL, bundledPublicDer, pm1);
                OtaReleaseChannel.Channel channel = OtaReleaseChannel.loadBundled(ctx1);
                check(channel != null && MANIFEST_URL.equals(channel.manifestUrl),
                        "Bundled staging channel loaded");
                PublicKey loadedPub = OtaReleaseTrust.readBundledPublicKey(ctx1);
                check(loadedPub != null && Arrays.equals(loadedPub.getEncoded(), bundledPublicDer),
                        "Bundled ephemeral public key loaded");

                // Scenario 12 early check: public prepare() refuses ephemeral staging cert (trust boundary)
                server.resetCountersAndFaults();
                server.serveArtifact(v7Artifact, null);
                OtaUpdatePreparation.Result publicDenied = OtaUpdatePreparation.prepare(
                        ctx1, channel.manifestUrl, channel.trustedHosts);
                check(!publicDenied.staged && "PREPARE_INSTALLED_IDENTITY_UNKNOWN".equals(publicDenied.code),
                        "Public production prepare() must reject ephemeral staging signer: " + publicDenied.code);
                check(server.manifestHits.get() == 0 && server.apkHits.get() == 0,
                        "Public prepare() must reject before hitting network");

                // Execute real staging flow via package-private seams
                OtaUpdatePreparation.Result okV7 = OtaUpdatePreparation.prepare(
                        ctx1, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                check(okV7.staged && "VERIFIED_PRIVATE_APK_NOT_INSTALLED".equals(okV7.code),
                        "Scenario 1 valid staging delivery failed: " + okV7.code);
                check(okV7.candidateVersionCode == 7 && okV7.privateApk != null && okV7.privateApk.isFile(),
                        "Scenario 1 staged v7 file present");
                check(okV7.privateApk.getName().equals("jarvis-7-" + v7Artifact.apkSha256 + ".apk"),
                        "Immutable version+sha staged filename mismatch: " + okV7.privateApk.getName());
                check(listStagingFiles(clientFiles1, ".part").length == 0,
                        "Scenario 1 left lingering .part files");
                check(server.manifestHits.get() == 1 && server.sigHits.get() == 1 && server.apkHits.get() == 1,
                        "Scenario 1 should make 1 manifest, 1 sig, 1 apk TLS request");
                check(pm1.getPackageInstaller().createSessionCount == 0
                        && pm1.getPackageInstaller().commitCount == 0,
                        "Preparation must NEVER create or commit PackageInstaller session");

                OtaAndroidInstallPreflight.Verdict preflightV7 =
                        OtaAndroidInstallPreflight.inspect(ctx1, okV7, stagingApkSignerSha);
                check(preflightV7.readyForOwnerRecoveryReview
                        && "TECHNICAL_PREFLIGHT_OK_BACKUP_AND_OWNER_NOT_CHECKED".equals(preflightV7.code),
                        "Scenario 1 preflight verdict unexpected: " + preflightV7.code);

                // Scenario 2: Corrupted manifest signature
                File clientFiles2 = workRoot.resolve("client-s2").toFile();
                clientFiles2.mkdirs();
                TestClientContext ctx2 = new TestClientContext(
                        clientFiles2, MANIFEST_URL, bundledPublicDer,
                        new TestPackageManager(catalog, 6, true));
                server.resetCountersAndFaults();
                byte[] badSig = v7Artifact.signatureBytes.clone();
                badSig[0] ^= 0x7f;
                server.serveArtifact(v7Artifact, badSig);
                OtaUpdatePreparation.Result resBadSig = OtaUpdatePreparation.prepare(
                        ctx2, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                check(!resBadSig.staged && "PREPARE_MANIFEST_SIGNATURE_INVALID".equals(resBadSig.code),
                        "Scenario 2 expected PREPARE_MANIFEST_SIGNATURE_INVALID, got " + resBadSig.code);
                check(server.apkHits.get() == 0 && listStagingFiles(clientFiles2, ".apk").length == 0,
                        "Scenario 2 must not request or stage APK on invalid signature");

                // Scenario 3: Mismatched APK digest
                File clientFiles3 = workRoot.resolve("client-s3").toFile();
                clientFiles3.mkdirs();
                TestClientContext ctx3 = new TestClientContext(
                        clientFiles3, MANIFEST_URL, bundledPublicDer,
                        new TestPackageManager(catalog, 6, true));
                server.resetCountersAndFaults();
                server.serveArtifact(v7Artifact, null);
                server.apkFault = ApkFault.CORRUPT_DIGEST;
                OtaUpdatePreparation.Result resBadDigest = OtaUpdatePreparation.prepare(
                        ctx3, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                check(!resBadDigest.staged && "PREPARE_DOWNLOAD_OR_INSPECTION_FAILED".equals(resBadDigest.code),
                        "Scenario 3 expected PREPARE_DOWNLOAD_OR_INSPECTION_FAILED, got " + resBadDigest.code);
                check(listStagingFiles(clientFiles3, ".part").length == 0
                        && listStagingFiles(clientFiles3, ".apk").length == 0,
                        "Scenario 3 must clean .part and never commit .apk");

                // Scenario 4: Redirected host (302 manifest and 307 APK blocked fail-closed)
                File clientFiles4 = workRoot.resolve("client-s4").toFile();
                clientFiles4.mkdirs();
                TestClientContext ctx4 = new TestClientContext(
                        clientFiles4, MANIFEST_URL, bundledPublicDer,
                        new TestPackageManager(catalog, 6, true));
                server.resetCountersAndFaults();
                server.serveArtifact(v7Artifact, null);
                server.redirectManifest302 = true;
                OtaUpdatePreparation.Result resManifestRedirect = OtaUpdatePreparation.prepare(
                        ctx4, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                check(!resManifestRedirect.staged
                        && "PREPARE_MANIFEST_FETCH_FAILED".equals(resManifestRedirect.code),
                        "Scenario 4a 302 manifest expected fail-closed, got " + resManifestRedirect.code);
                check(server.apkHits.get() == 0, "Scenario 4a must stop before APK");

                server.resetCountersAndFaults();
                server.serveArtifact(v7Artifact, null);
                server.apkFault = ApkFault.REDIRECT_307;
                OtaUpdatePreparation.Result resApkRedirect = OtaUpdatePreparation.prepare(
                        ctx4, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                check(!resApkRedirect.staged
                        && "PREPARE_DOWNLOAD_OR_INSPECTION_FAILED".equals(resApkRedirect.code),
                        "Scenario 4b 307 APK expected fail-closed, got " + resApkRedirect.code);
                check(listStagingFiles(clientFiles4, ".part").length == 0
                        && listStagingFiles(clientFiles4, ".apk").length == 0,
                        "Scenario 4b must clean .part and stage nothing");
                for (String openedUrl : server.openerUrls) {
                    check(!openedUrl.contains("redirected-attacker.example"),
                            "Redirect target was followed unexpectedly: " + openedUrl);
                }

                // Scenario 5: Truncated download
                File clientFiles5 = workRoot.resolve("client-s5").toFile();
                clientFiles5.mkdirs();
                TestClientContext ctx5 = new TestClientContext(
                        clientFiles5, MANIFEST_URL, bundledPublicDer,
                        new TestPackageManager(catalog, 6, true));
                server.resetCountersAndFaults();
                server.serveArtifact(v7Artifact, null);
                server.apkFault = ApkFault.TRUNCATE_HALF;
                OtaUpdatePreparation.Result resTruncated = OtaUpdatePreparation.prepare(
                        ctx5, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                check(!resTruncated.staged
                        && "PREPARE_DOWNLOAD_OR_INSPECTION_FAILED".equals(resTruncated.code),
                        "Scenario 5 truncated expected fail-closed, got " + resTruncated.code);
                check(listStagingFiles(clientFiles5, ".part").length == 0
                        && listStagingFiles(clientFiles5, ".apk").length == 0,
                        "Scenario 5 truncated must delete .part and stage nothing");

                // Scenario 6: Read timeout (APK stall)
                File clientFiles6 = workRoot.resolve("client-s6").toFile();
                clientFiles6.mkdirs();
                TestClientContext ctx6 = new TestClientContext(
                        clientFiles6, MANIFEST_URL, bundledPublicDer,
                        new TestPackageManager(catalog, 6, true));
                server.resetCountersAndFaults();
                server.serveArtifact(v7Artifact, null);
                server.apkFault = ApkFault.STALL_TIMEOUT;
                long t0 = System.nanoTime();
                OtaUpdatePreparation.Result resTimeout = OtaUpdatePreparation.prepare(
                        ctx6, channel.manifestUrl, channel.trustedHosts, shortTimeoutOpener, stagingApkSignerSha);
                long elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - t0);
                check(!resTimeout.staged
                        && "PREPARE_DOWNLOAD_OR_INSPECTION_FAILED".equals(resTimeout.code),
                        "Scenario 6 timeout expected fail-closed, got " + resTimeout.code);
                check(elapsedMs < 1500L, "Scenario 6 timeout took too long: " + elapsedMs + "ms");
                check(listStagingFiles(clientFiles6, ".part").length == 0
                        && listStagingFiles(clientFiles6, ".apk").length == 0,
                        "Scenario 6 timeout must delete .part and stage nothing");

                // Scenario 7: Stale / replayed version (equal v6 and downgrade v5 when installed=6)
                File clientFiles7 = workRoot.resolve("client-s7").toFile();
                clientFiles7.mkdirs();
                TestClientContext ctx7 = new TestClientContext(
                        clientFiles7, MANIFEST_URL, bundledPublicDer,
                        new TestPackageManager(catalog, 6, true));
                server.resetCountersAndFaults();
                server.serveArtifact(v6Replay, null);
                OtaUpdatePreparation.Result resReplay = OtaUpdatePreparation.prepare(
                        ctx7, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                check(!resReplay.staged && "PREPARE_CANDIDATE_NOT_AN_UPGRADE".equals(resReplay.code),
                        "Scenario 7a replay v6 expected PREPARE_CANDIDATE_NOT_AN_UPGRADE, got " + resReplay.code);
                check(server.apkHits.get() == 0, "Scenario 7a must not download replayed v6 APK");

                server.resetCountersAndFaults();
                server.serveArtifact(v5Downgrade, null);
                OtaUpdatePreparation.Result resDowngrade = OtaUpdatePreparation.prepare(
                        ctx7, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                check(!resDowngrade.staged && "PREPARE_CANDIDATE_NOT_AN_UPGRADE".equals(resDowngrade.code),
                        "Scenario 7b downgrade v5 expected PREPARE_CANDIDATE_NOT_AN_UPGRADE, got " + resDowngrade.code);
                check(server.apkHits.get() == 0, "Scenario 7b must not download downgrade v5 APK");

                // Scenario 8 & 10b: Interrupted partial download + client restart persistence + clean v8 retry
                File clientFilesRestart = workRoot.resolve("client-s8-restart").toFile();
                clientFilesRestart.mkdirs();
                TestPackageManager pmPreRestart = new TestPackageManager(catalog, 6, true);
                TestClientContext ctxPreRestart = new TestClientContext(
                        clientFilesRestart, MANIFEST_URL, bundledPublicDer, pmPreRestart);

                // First stage verified v7 before simulated partial v8 interruption/restart
                server.resetCountersAndFaults();
                server.serveArtifact(v7Artifact, null);
                OtaUpdatePreparation.Result priorV7 = OtaUpdatePreparation.prepare(
                        ctxPreRestart, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                check(priorV7.staged && priorV7.privateApk.isFile(), "Scenario 8 prior v7 staged");

                // Now stream v8 slowly and interrupt mid-transfer
                server.resetCountersAndFaults();
                server.serveArtifact(v8Artifact, null);
                server.apkFault = ApkFault.PACE_FOR_INTERRUPT;
                final CountDownLatch apkStarted = new CountDownLatch(1);
                server.slowApkStartedLatch = apkStarted;

                final AtomicReference<OtaUpdatePreparation.Result> interruptedResult = new AtomicReference<>();
                Thread downloadWorker = new Thread(new Runnable() {
                    @Override
                    public void run() {
                        interruptedResult.set(OtaUpdatePreparation.prepare(
                                ctxPreRestart, channel.manifestUrl, channel.trustedHosts,
                                normalOpener, stagingApkSignerSha));
                    }
                }, "ota-interrupt-worker");
                downloadWorker.start();
                check(apkStarted.await(3, TimeUnit.SECONDS), "Scenario 8 partial v8 transfer started");
                long waitPartDeadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(1000L);
                while (System.nanoTime() < waitPartDeadline) {
                    File[] partsNow = listStagingFiles(clientFilesRestart, ".part");
                    if (partsNow.length > 0 && partsNow[0].length() > 0) break;
                    Thread.sleep(10L);
                }
                downloadWorker.interrupt();
                downloadWorker.join(4000L);
                check(!downloadWorker.isAlive(), "Scenario 8 worker exited promptly after interrupt");
                OtaUpdatePreparation.Result partialCancelRes = interruptedResult.get();
                check(partialCancelRes != null && !partialCancelRes.staged
                        && "PREPARE_CANCELLED".equals(partialCancelRes.code),
                        "Scenario 8 expected PREPARE_CANCELLED, got "
                                + (partialCancelRes != null ? partialCancelRes.code : "null"));
                check(listStagingFiles(clientFilesRestart, ".part").length == 0,
                        "Scenario 8 aborted partial .part must be deleted");
                check(priorV7.privateApk.isFile()
                        && v7Artifact.apkSha256.equalsIgnoreCase(sha256File(priorV7.privateApk)),
                        "Scenario 8 interrupted v8 MUST preserve prior verified v7 fallback APK on disk");

                // Simulated fresh client restart pointing to the same persisted filesDir:
                // validates preserved prior fallback v7 APK on disk + clean retry of v8
                // from scratch (NOT resumable partial HTTP download or persisted UI state).
                TestPackageManager pmRestarted = new TestPackageManager(catalog, 6, false);
                TestClientContext ctxRestarted = new TestClientContext(
                        clientFilesRestart, MANIFEST_URL, bundledPublicDer, pmRestarted);
                File[] persistedApks = listStagingFiles(clientFilesRestart, ".apk");
                check(persistedApks.length == 1 && persistedApks[0].equals(priorV7.privateApk),
                        "Scenario 8 persisted v7 APK discovered after simulated client restart");
                OtaAndroidArchiveInspector.Result postRestartV7Check =
                        OtaAndroidArchiveInspector.inspect(
                                ctxRestarted, persistedApks[0], v7Artifact.toCandidate(), stagingApkSignerSha);
                check(postRestartV7Check.accepted,
                        "Scenario 8 persisted v7 still passes ArchiveInspector after client restart: "
                                + postRestartV7Check.code);

                // Clean retry of v8 after restart succeeds without deleting prior v7
                server.resetCountersAndFaults();
                server.serveArtifact(v8Artifact, null);
                OtaUpdatePreparation.Result retryV8 = OtaUpdatePreparation.prepare(
                        ctxRestarted, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                check(retryV8.staged && retryV8.candidateVersionCode == 8,
                        "Scenario 8 clean v8 retry after restart failed: " + retryV8.code);
                check(listStagingFiles(clientFilesRestart, ".apk").length == 2
                        && listStagingFiles(clientFilesRestart, ".part").length == 0,
                        "Scenario 8 both v7 fallback and v8 candidate preserved immutably with zero .part");

                // Scenario 9: Offline / unreachable server (closed port)
                final int deadPort = findDeadLoopbackPort();
                OtaHttpsTransport.ConnectionOpener offlineOpener = new OtaHttpsTransport.ConnectionOpener() {
                    @Override
                    public HttpsURLConnection open(String validatedUrl) throws IOException {
                        URI uri;
                        try {
                            uri = new URI(validatedUrl);
                        } catch (Exception e) {
                            throw new IOException(e);
                        }
                        HttpsURLConnection conn = (HttpsURLConnection) new URL(
                                "https://127.0.0.1:" + deadPort + uri.getRawPath()).openConnection();
                        conn.setConnectTimeout(400);
                        conn.setReadTimeout(400);
                        return conn;
                    }
                };
                File clientFiles9 = workRoot.resolve("client-s9-offline").toFile();
                clientFiles9.mkdirs();
                TestClientContext ctx9 = new TestClientContext(
                        clientFiles9, MANIFEST_URL, bundledPublicDer,
                        new TestPackageManager(catalog, 6, true));
                OtaUpdatePreparation.Result resOffline = OtaUpdatePreparation.prepare(
                        ctx9, channel.manifestUrl, channel.trustedHosts, offlineOpener, stagingApkSignerSha);
                check(!resOffline.staged && "PREPARE_MANIFEST_FETCH_FAILED".equals(resOffline.code),
                        "Scenario 9 offline expected PREPARE_MANIFEST_FETCH_FAILED, got " + resOffline.code);
                check(listStagingFiles(clientFiles9, ".apk").length == 0,
                        "Scenario 9 offline staged zero files");

                // Scenario 10a & 10c: Pre-call Thread.interrupt() + main Looper guard
                server.resetCountersAndFaults();
                Thread.currentThread().interrupt();
                try {
                    OtaUpdatePreparation.Result preCancelled = OtaUpdatePreparation.prepare(
                            ctx9, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                    check(!preCancelled.staged && "PREPARE_CANCELLED".equals(preCancelled.code),
                            "Scenario 10a pre-interrupted expected PREPARE_CANCELLED, got " + preCancelled.code);
                    check(Thread.currentThread().isInterrupted(),
                            "Scenario 10a interrupt flag must remain set");
                } finally {
                    Thread.interrupted();
                }
                check(server.manifestHits.get() == 0, "Scenario 10a must not hit network when cancelled");

                Looper.setCurrentAsMainLooperForTest(true);
                try {
                    OtaUpdatePreparation.Result mainDenied = OtaUpdatePreparation.prepare(
                            ctx9, channel.manifestUrl, channel.trustedHosts, normalOpener, stagingApkSignerSha);
                    check(!mainDenied.staged && "PREPARE_MAIN_THREAD_FORBIDDEN".equals(mainDenied.code),
                            "Scenario 10c expected PREPARE_MAIN_THREAD_FORBIDDEN, got " + mainDenied.code);
                } finally {
                    Looper.setCurrentAsMainLooperForTest(false);
                }

                // Scenario 11: Installer NEVER invoked without BOTH explicit owner consent AND
                // cryptographically verified local backup/recovery receipt (no hardcoded true booleans).
                PackageInstaller installerRestarted = pmRestarted.getPackageInstaller();
                final long nowSec = 1_795_000_000L;
                final String deviceUid = "akai-tv-fixture-uid-001";
                final String wrongUid = "akai-tv-other-uid-999";

                // 11a: missing physical owner approval
                OtaOwnerPackageInstaller.Outcome noOwnerConsent =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, false, stagingApkSignerSha, nowSec);
                check(!noOwnerConsent.submittedToAndroid
                        && "PHYSICAL_OWNER_APPROVAL_REQUIRED".equals(noOwnerConsent.code),
                        "Scenario 11a missing owner consent: " + noOwnerConsent.code);

                // 11a2: unknown sources permission still disabled on pmRestarted
                OtaOwnerPackageInstaller.Outcome noUnknownSourcesPerm =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(!noUnknownSourcesPerm.submittedToAndroid
                        && "PREFLIGHT_ANDROID_UNKNOWN_SOURCE_PERMISSION_REQUIRED".equals(noUnknownSourcesPerm.code),
                        "Scenario 11a2 unknown-sources gate: " + noUnknownSourcesPerm.code);

                // Enable unknown-sources so every cryptographic backup/recovery receipt gate runs directly
                pmRestarted.canRequestInstalls = true;
                final String rescueDigest = v8Artifact.apkSha256;

                // 11b: two checkboxes checked (ownerConsent=true) but ZERO evidence receipt on disk
                clearEvidenceFiles(clientFilesRestart);
                OtaOwnerPackageInstaller.Outcome noReceipt =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(!noReceipt.submittedToAndroid
                        && "EVIDENCE_RECEIPT_MISSING".equals(noReceipt.code),
                        "Scenario 11b missing evidence receipt: " + noReceipt.code);

                // 11c: expired receipt rejected even with ownerConsent=true
                byte[] expiredReceipt = buildSignedEvidenceReceipt(
                        "staging", deviceUid, 6, "bkp-expired",
                        nowSec - 7200L, nowSec - 60L, v7Artifact.apkSha256, 0, 9, rescueDigest, true, true);
                writeRawEvidenceFiles(clientFilesRestart, expiredReceipt,
                        signDetachedRsa(expiredReceipt, stagingManifestKey));
                OtaOwnerPackageInstaller.Outcome expiredOutcome =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(!expiredOutcome.submittedToAndroid
                        && "EVIDENCE_EXPIRED".equals(expiredOutcome.code),
                        "Scenario 11c expired receipt: " + expiredOutcome.code);

                // 11d: receipt bound to a different device UID rejected
                byte[] otherUidReceipt = buildSignedEvidenceReceipt(
                        "staging", wrongUid, 6, "bkp-other-uid",
                        nowSec - 300L, nowSec + 86400L, v7Artifact.apkSha256, 0, 9, rescueDigest, true, true);
                writeRawEvidenceFiles(clientFilesRestart, otherUidReceipt,
                        signDetachedRsa(otherUidReceipt, stagingManifestKey));
                OtaOwnerPackageInstaller.Outcome uidMismatchOutcome =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(!uidMismatchOutcome.submittedToAndroid
                        && "EVIDENCE_DEVICE_UID_MISMATCH".equals(uidMismatchOutcome.code),
                        "Scenario 11d wrong deviceUid: " + uidMismatchOutcome.code);

                // 11e: receipt bound to different installedVersionCode (5 vs actual 6) rejected
                byte[] wrongVerReceipt = buildSignedEvidenceReceipt(
                        "staging", deviceUid, 5, "bkp-wrong-ver",
                        nowSec - 300L, nowSec + 86400L, v7Artifact.apkSha256, 0, 9, rescueDigest, true, true);
                writeRawEvidenceFiles(clientFilesRestart, wrongVerReceipt,
                        signDetachedRsa(wrongVerReceipt, stagingManifestKey));
                OtaOwnerPackageInstaller.Outcome verMismatchOutcome =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(!verMismatchOutcome.submittedToAndroid
                        && "EVIDENCE_INSTALLED_VERSION_MISMATCH".equals(verMismatchOutcome.code),
                        "Scenario 11e wrong installedVersionCode: " + verMismatchOutcome.code);

                // 11f: unattested offline restore rejected
                byte[] noOfflineRestore = buildSignedEvidenceReceipt(
                        "staging", deviceUid, 6, "bkp-no-offline",
                        nowSec - 300L, nowSec + 86400L, v7Artifact.apkSha256, 0, 9, rescueDigest, false, true);
                writeRawEvidenceFiles(clientFilesRestart, noOfflineRestore,
                        signDetachedRsa(noOfflineRestore, stagingManifestKey));
                OtaOwnerPackageInstaller.Outcome noOfflineOutcome =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(!noOfflineOutcome.submittedToAndroid
                        && "EVIDENCE_OFFLINE_RESTORE_NOT_VERIFIED".equals(noOfflineOutcome.code),
                        "Scenario 11f unattested offline restore: " + noOfflineOutcome.code);

                // 11g: non-destructive restore false rejected
                byte[] destructiveReceipt = buildSignedEvidenceReceipt(
                        "staging", deviceUid, 6, "bkp-destructive",
                        nowSec - 300L, nowSec + 86400L, v7Artifact.apkSha256, 0, 9, rescueDigest, true, false);
                writeRawEvidenceFiles(clientFilesRestart, destructiveReceipt,
                        signDetachedRsa(destructiveReceipt, stagingManifestKey));
                OtaOwnerPackageInstaller.Outcome destructiveOutcome =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(!destructiveOutcome.submittedToAndroid
                        && "EVIDENCE_NONDESTRUCTIVE_RESTORE_NOT_VERIFIED".equals(destructiveOutcome.code),
                        "Scenario 11g nonDestructive false: " + destructiveOutcome.code);

                // 11h: recoveryRescueVersionCode <= candidateVersionCode (8 <= 8) rejected
                byte[] lowRescueReceipt = buildSignedEvidenceReceipt(
                        "staging", deviceUid, 6, "bkp-low-rescue",
                        nowSec - 300L, nowSec + 86400L, v7Artifact.apkSha256, 0, 8, rescueDigest, true, true);
                writeRawEvidenceFiles(clientFilesRestart, lowRescueReceipt,
                        signDetachedRsa(lowRescueReceipt, stagingManifestKey));
                OtaOwnerPackageInstaller.Outcome lowRescueOutcome =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(!lowRescueOutcome.submittedToAndroid
                        && "EVIDENCE_RECOVERY_RESCUE_NOT_ABOVE_CANDIDATE".equals(lowRescueOutcome.code),
                        "Scenario 11h rescue <= candidate: " + lowRescueOutcome.code);

                // 11h2: Release receipt where candidate <= priorRescueFloor (8 <= 8) rejected
                byte[] badReleaseFloor = buildSignedEvidenceReceipt(
                        "release", deviceUid, 6, "bkp-rel-floor",
                        nowSec - 300L, nowSec + 86400L, v7Artifact.apkSha256, 8, 9, rescueDigest, true, true);
                writeRawEvidenceFiles(clientFilesRestart, badReleaseFloor,
                        signDetachedRsa(badReleaseFloor, stagingManifestKey));
                OtaOwnerPackageInstaller.Outcome badReleaseFloorOutcome =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(!badReleaseFloorOutcome.submittedToAndroid
                        && "EVIDENCE_RELEASE_NOT_ABOVE_PRIOR_RESCUE".equals(badReleaseFloorOutcome.code),
                        "Scenario 11h2 release floor mismatch: " + badReleaseFloorOutcome.code);

                // 11i: corrupted signature rejected (and import helper also refuses invalid sig)
                byte[] validReleaseSyntheticReceipt = buildSignedEvidenceReceipt(
                        "release", deviceUid, 6, "bkp-synthetic-rel-01",
                        nowSec - 300L, nowSec + 86400L * 7L, v7Artifact.apkSha256, 7, 9, rescueDigest, true, true);
                byte[] validReleaseSyntheticSig = signDetachedRsa(validReleaseSyntheticReceipt, stagingManifestKey);
                byte[] corruptReceiptSig = validReleaseSyntheticSig.clone();
                corruptReceiptSig[0] ^= 0x3c;
                writeRawEvidenceFiles(clientFilesRestart, validReleaseSyntheticReceipt, corruptReceiptSig);
                OtaOwnerPackageInstaller.Outcome badReceiptSigOutcome =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(!badReceiptSigOutcome.submittedToAndroid
                        && "EVIDENCE_SIGNATURE_INVALID".equals(badReceiptSigOutcome.code),
                        "Scenario 11i corrupted receipt sig: " + badReceiptSigOutcome.code);

                OtaRecoveryEvidenceGate.Verdict refusedImport =
                        OtaRecoveryEvidenceStore.importVerifiedReceipt(
                                ctxRestarted, validReleaseSyntheticReceipt, corruptReceiptSig,
                                6, 8, nowSec);
                check(!refusedImport.accepted && "EVIDENCE_SIGNATURE_INVALID".equals(refusedImport.code),
                        "Scenario 11j importVerifiedReceipt must reject bad signature");

                // 11k: valid RSA signature on receipt + tampered local archive -> blocked BEFORE PackageInstaller!
                byte[] tamperedBackup = v7Artifact.apkBytes.clone();
                tamperedBackup[100] ^= 0x55;
                writeLocalBackupArchive(clientFilesRestart, tamperedBackup);
                writeRawEvidenceFiles(clientFilesRestart, validReleaseSyntheticReceipt, validReleaseSyntheticSig);
                OtaOwnerPackageInstaller.Outcome tamperedLocalArchiveOutcome =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(!tamperedLocalArchiveOutcome.submittedToAndroid
                        && "EVIDENCE_LOCAL_ARCHIVE_HASH_MISMATCH".equals(tamperedLocalArchiveOutcome.code),
                        "Scenario 11k local archive mismatch must fail closed: " + tamperedLocalArchiveOutcome.code);
                check(installerRestarted.createSessionCount == 0 && installerRestarted.commitCount == 0,
                        "Installer must NOT create session when local archive bytes differ from signed receipt");

                // Restore genuine matching local archive and import cleanly
                writeLocalBackupArchive(clientFilesRestart, v7Artifact.apkBytes);
                OtaRecoveryEvidenceGate.Verdict importedSynthetic =
                        OtaRecoveryEvidenceStore.importVerifiedReceipt(
                                ctxRestarted, validReleaseSyntheticReceipt, validReleaseSyntheticSig,
                                6, 8, nowSec);
                check(importedSynthetic.accepted
                        && "LOCAL_RECOVERY_EVIDENCE_VERIFIED_NOT_AUTHORIZED_ALONE".equals(importedSynthetic.code),
                        "Scenario 11k2 synthetic release receipt import: " + importedSynthetic.code);
                check(installerRestarted.createSessionCount == 0 && installerRestarted.commitCount == 0,
                        "Installer must NOT create or commit session before final submit");

                // 11l: public submit still blocks staging signer even with valid synthetic receipt
                OtaOwnerPackageInstaller.Outcome publicInstallerBlocked =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true);
                check(!publicInstallerBlocked.submittedToAndroid,
                        "Scenario 11l public installer must reject staging cert");
                check(installerRestarted.createSessionCount == 0 && installerRestarted.commitCount == 0,
                        "Scenario 11l must leave PackageInstaller untouched");

                // 11m: positive synthetic release fixture (NON_AUTHORITATIVE ephemeral key + receipt):
                // installed=6 <= priorRescue=7 < candidate=8 < recoveryRescue=9
                OtaOwnerPackageInstaller.Outcome committed =
                        OtaOwnerPackageInstaller.submitAfterPhysicalOwnerApproval(
                                ctxRestarted, retryV8, true, stagingApkSignerSha, nowSec);
                check(committed.submittedToAndroid
                        && "SUBMITTED_TO_ANDROID_AWAITING_OS_USER_RESULT".equals(committed.code),
                        "Scenario 11m approved synthetic install submission failed: " + committed.code);
                check(installerRestarted.createSessionCount == 1
                        && installerRestarted.commitCount == 1
                        && installerRestarted.abandonCount == 0,
                        "Scenario 11m expected 1 created & 1 committed PackageInstaller session");
                byte[] sessionBytes = installerRestarted.getLastCommittedBytes("base.apk");
                check(sessionBytes != null && sessionBytes.length == v8Bytes.length
                        && v8Artifact.apkSha256.equalsIgnoreCase(sha256Hex(sessionBytes)),
                        "Scenario 11m committed PackageInstaller bytes must match staged v8 SHA-256");
            }
        } finally {
            deleteTree(workRoot);
        }

        System.out.println("OtaDeliveryIntegrationTest PASS: " + checks
                + " assertions across 12 host HTTPS & signed recovery receipt scenarios (EPHEMERAL NON_AUTHORITATIVE FIXTURE ONLY — NOT OTA_PROVISIONED_READY, NOT owner release cert, NOT TV/PC-off PASS)");
    }
}
