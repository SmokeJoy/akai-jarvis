package it.akai.customremote;

import android.content.Context;
import android.util.Base64;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.math.BigInteger;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.Signature;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.PKCS8EncodedKeySpec;
import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;

/**
 * TlsCertificateManager: Gestore crittografico embedded per la CA Locale e i Certificati SAN (Milestone M2).
 *
 * Genera ed archivia esclusivamente nello storage privato dell'app su TV:
 * 1. Root Certificate Authority locale autofirmata (RSA 2048-bit, 3 anni di validità).
 * 2. Certificato server firmato dalla CA locale con Subject Alternative Names (SAN):
 *    - IP: 127.0.0.1, <IP LAN TV dinamico>
 *    - DNS: akai-tv.local, localhost, akai.local, akai-jarvis.lan
 * 3. Keystore PKCS#12 protetto da passphrase crittografica casuale a 256-bit generata on-device.
 * 4. Calcolo impronta SHA-256 della CA per verifica visiva anti-MITM a schermo prima del trust su iOS/Android.
 *
 * Zero chiavi o certificati hardcoded nel repository (garanzia di sicurezza fail-closed).
 */
public class TlsCertificateManager {
    private static final String TAG = "AKAI_TlsCertMgr";

    public static final String KEYSTORE_FILE_NAME = "server_keystore.p12";
    public static final String KEYSTORE_BAK_FILE_NAME = "server_keystore.p12.bak";
    public static final String PASSWORD_FILE_NAME = "server_keystore.pass";
    public static final String CA_CERT_FILE_NAME = "ca.crt";
    public static final String CA_PEM_FILE_NAME = "ca.pem";
    public static final String CA_KEY_FILE_NAME = "ca_key.der";

    public static final String CA_COMMON_NAME = "AKAI Jarvis Local CA";
    public static final String CA_ORGANIZATION = "AKAI Local Secure Remote";
    public static final String CA_COUNTRY = "IT";

    public static final String SERVER_COMMON_NAME = "akai-tv.local";
    public static final int HTTPS_PORT = 8443;

    private static TlsCertificateManager sInstance = null;

    public static class TlsInfo {
        public final String caFingerprintSha256;
        public final String caPem;
        public final List<String> serverSanList;
        public final long notAfterMs;
        public final File keystoreFile;
        public final char[] keyPassword;

        public TlsInfo(String caFingerprintSha256, String caPem, List<String> serverSanList,
                       long notAfterMs, File keystoreFile, char[] keyPassword) {
            this.caFingerprintSha256 = caFingerprintSha256;
            this.caPem = caPem;
            this.serverSanList = serverSanList;
            this.notAfterMs = notAfterMs;
            this.keystoreFile = keystoreFile;
            this.keyPassword = keyPassword;
        }
    }

    private TlsInfo cachedTlsInfo = null;

    private static Context sAppContext = null;

    public static void setApplicationContext(Context context) {
        if (context != null) {
            sAppContext = context.getApplicationContext();
        }
    }

    public static synchronized TlsCertificateManager getInstance() {
        if (sInstance == null) {
            sInstance = new TlsCertificateManager();
        }
        return sInstance;
    }

    public static synchronized void resetInstanceForTesting() {
        sInstance = null;
        sAppContext = null;
    }

    /**
     * Carica o genera i certificati TLS a bordo TV garantendo SAN aggiornati.
     */
    public synchronized TlsInfo getOrGenerateTlsInfo(Context context, String localIp) {
        if (context != null && sAppContext == null) {
            sAppContext = context.getApplicationContext();
        }
        Context effectiveCtx = (context != null) ? context : sAppContext;

        if (cachedTlsInfo != null && cachedTlsInfo.keystoreFile != null && cachedTlsInfo.keystoreFile.exists()) {
            boolean ipValid = (localIp == null || localIp.trim().isEmpty() || "127.0.0.1".equals(localIp.trim()) ||
                               (cachedTlsInfo.serverSanList != null && cachedTlsInfo.serverSanList.contains(localIp.trim())));
            if (ipValid && System.currentTimeMillis() < (cachedTlsInfo.notAfterMs - (7L * 24 * 3600 * 1000))) {
                return cachedTlsInfo;
            }
            Log.i(TAG, "Certificato TLS in scadenza o IP TV mutato (" + localIp + "). Avvio rigenerazione...");
        }

        File filesDir = (effectiveCtx != null) ? effectiveCtx.getFilesDir() : new File(".");
        File ksFile = new File(filesDir, KEYSTORE_FILE_NAME);
        File ksBakFile = new File(filesDir, KEYSTORE_BAK_FILE_NAME);
        File passFile = new File(filesDir, PASSWORD_FILE_NAME);
        File caPemFile = new File(filesDir, CA_PEM_FILE_NAME);
        File caKeyFile = new File(filesDir, CA_KEY_FILE_NAME);

        boolean identityFilesExist = (ksFile.exists() || ksBakFile.exists() || passFile.exists() || caPemFile.exists() || caKeyFile.exists());

        // Auto-Recovery preventivo: se ksFile è assente o vuoto ma esiste ksBakFile valido, ripristina da .bak
        if ((!ksFile.exists() || ksFile.length() == 0) && ksBakFile.exists() && ksBakFile.length() > 0 && passFile.exists() && passFile.length() > 0) {
            try {
                char[] password = readPasswordFromFile(passFile);
                if (password != null && password.length > 0) {
                    KeyStore testKs = KeyStore.getInstance("PKCS12");
                    try (FileInputStream fisBak = new FileInputStream(ksBakFile)) {
                        testKs.load(fisBak, password);
                    }
                    if (testKs.getCertificate("akai_ca") != null && testKs.getCertificate("akai_server") != null) {
                        Log.w(TAG, "Keystore primario assente o vuoto: ripristino automatico preventivo da backup .bak...");
                        Files.copy(ksBakFile.toPath(), ksFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
                        ksFile.setReadable(false, false);
                        ksFile.setReadable(true, true);
                        ksFile.setWritable(false, false);
                        ksFile.setWritable(true, true);
                    }
                }
            } catch (Exception bakRecoveryEx) {
                Log.w(TAG, "Auto-recovery preventivo da .bak fallito: " + bakRecoveryEx.getMessage());
            }
        }

        // Se già presenti e validi, carica dallo storage privato
        if (ksFile.exists() && passFile.exists() && caPemFile.exists() && ksFile.length() > 0 && passFile.length() > 0) {
            try {
                char[] password = readPasswordFromFile(passFile);
                if (password != null && password.length > 0) {
                    KeyStore ks = KeyStore.getInstance("PKCS12");
                    try (FileInputStream fis = new FileInputStream(ksFile)) {
                        ks.load(fis, password);
                    } catch (Exception loadEx) {
                        // Se ksFile è corrotto (es. crash o scrittura interrotta), tenta ripristino trasparente da .bak
                        if (ksBakFile.exists() && ksBakFile.length() > 0) {
                            Log.w(TAG, "Keystore primario non leggibile (" + loadEx.getMessage() + "), ripristino trasparente da backup .bak...");
                            try (FileInputStream fisBak = new FileInputStream(ksBakFile)) {
                                ks = KeyStore.getInstance("PKCS12");
                                ks.load(fisBak, password);
                            }
                            Files.copy(ksBakFile.toPath(), ksFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
                            ksFile.setReadable(false, false);
                            ksFile.setReadable(true, true);
                            ksFile.setWritable(false, false);
                            ksFile.setWritable(true, true);
                        } else {
                            throw loadEx;
                        }
                    }
                    Certificate sCert = ks.getCertificate("akai_server");
                    Certificate cCert = ks.getCertificate("akai_ca");
                    if (sCert instanceof X509Certificate && cCert instanceof X509Certificate) {
                        X509Certificate serverX509 = (X509Certificate) sCert;
                        X509Certificate caX509 = (X509Certificate) cCert;
                        if (System.currentTimeMillis() < (serverX509.getNotAfter().getTime() - (7L * 24 * 3600 * 1000))) {
                            List<String> sans = extractSanStrings(serverX509);
                            boolean ipValid = (localIp == null || localIp.trim().isEmpty() || "127.0.0.1".equals(localIp.trim()) || sans.contains(localIp.trim()));
                            boolean ekuValid = (serverX509.getExtendedKeyUsage() != null && serverX509.getExtendedKeyUsage().contains("1.3.6.1.5.5.7.3.1"));
                            if (ipValid && ekuValid) {
                                String caFp = computeSha256Fingerprint(caX509);
                                String caPem = readStringFromFile(caPemFile);
                                cachedTlsInfo = new TlsInfo(caFp, caPem, sans, serverX509.getNotAfter().getTime(), ksFile, password);
                                Log.i(TAG, "Keystore TLS caricato con successo. CA Fingerprint: " + caFp);
                                return cachedTlsInfo;
                            } else {
                                Log.i(TAG, "IP LAN TV mutato (" + localIp + ") o estensioni EKU serverAuth mancanti. Rinnovo certificato Server con Root CA esistente...");
                                if (caKeyFile.exists() && caKeyFile.length() > 0) {
                                    try {
                                        byte[] keyBytes = new byte[(int) caKeyFile.length()];
                                        try (FileInputStream kfis = new FileInputStream(caKeyFile)) {
                                            int readBytes = kfis.read(keyBytes);
                                            if (readBytes <= 0) throw new IOException("CA key file empty");
                                        }
                                        KeyFactory kf = KeyFactory.getInstance("RSA");
                                        PrivateKey caPrivKey = kf.generatePrivate(new PKCS8EncodedKeySpec(keyBytes));

                                        KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA");
                                        kpg.initialize(2048, new SecureRandom());
                                        KeyPair serverPair = kpg.generateKeyPair();

                                        long now = System.currentTimeMillis();
                                        Date notBefore = new Date(now - 60000);
                                        Date notAfterServer = new Date(now + 1000L * 60 * 60 * 24 * 365);

                                        List<String> dnsList = Arrays.asList("akai-tv.local", "localhost", "akai.local", "akai-jarvis.lan");
                                        List<String> ipList = new ArrayList<>(Arrays.asList("127.0.0.1"));
                                        if (localIp != null && !localIp.trim().isEmpty() && !ipList.contains(localIp.trim())) {
                                            ipList.add(localIp.trim());
                                        }

                                        X509Certificate serverCert = generateCertificate(
                                            SERVER_COMMON_NAME, CA_ORGANIZATION, CA_COUNTRY,
                                            serverPair.getPublic(),
                                            CA_COMMON_NAME, CA_ORGANIZATION, CA_COUNTRY,
                                            caPrivKey,
                                            notBefore, notAfterServer,
                                            BigInteger.valueOf(System.currentTimeMillis()),
                                            false, dnsList, ipList
                                        );

                                        ks.setCertificateEntry("akai_ca", caX509);
                                        ks.setKeyEntry("akai_server", serverPair.getPrivate(), password, new Certificate[]{serverCert, caX509});

                                        saveKeystoreSafely(ks, ksFile, password);

                                        List<String> allSans = new ArrayList<>();
                                        allSans.addAll(dnsList);
                                        allSans.addAll(ipList);

                                        String caFp = computeSha256Fingerprint(caX509);
                                        String caPem = readStringFromFile(caPemFile);
                                        cachedTlsInfo = new TlsInfo(caFp, caPem, allSans, notAfterServer.getTime(), ksFile, password);
                                        Log.i(TAG, "Certificato Server rinnovato con successo per IP " + localIp + " preservando la Root CA (Fingerprint invariata: " + caFp + ")");
                                        return cachedTlsInfo;
                                    } catch (Exception renewalEx) {
                                        Log.e(TAG, "Fallimento rinnovo con Root CA esistente: " + renewalEx.getMessage() + ". Fail-closed: Root CA preservata, nessuna rigenerazione distruttiva.");
                                        if (cachedTlsInfo != null) {
                                            return cachedTlsInfo;
                                        }
                                        throw new IllegalStateException("Impossibile rinnovare certificato server mantenendo la Root CA: " + renewalEx.getMessage(), renewalEx);
                                    }
                                } else {
                                    Log.e(TAG, "ca_key.der mancante per il rinnovo SAN. Fail-closed: conservazione certificato e Root CA esistente.");
                                    String caFp = computeSha256Fingerprint(caX509);
                                    String caPem = readStringFromFile(caPemFile);
                                    cachedTlsInfo = new TlsInfo(caFp, caPem, sans, serverX509.getNotAfter().getTime(), ksFile, password);
                                    return cachedTlsInfo;
                                }
                            }
                        }
                    }
                }
            } catch (Exception e) {
                if (e instanceof IllegalStateException) throw (IllegalStateException) e;
                Log.w(TAG, "Errore caricamento keystore esistente (" + e.getMessage() + ").");
                if (cachedTlsInfo != null) return cachedTlsInfo;
            }
        }

        // Fail-Closed: se esistono già tracce di identità precedente, è VIETATA qualsiasi rigenerazione automatica
        if (identityFilesExist) {
            Log.e(TAG, "Fail-closed: Tracce di identità TLS preesistenti rilevate ma incomplete. Rifiuto rigenerazione automatica di una nuova Root CA.");
            if (cachedTlsInfo != null) return cachedTlsInfo;
            throw new IllegalStateException("Materiale crittografico TLS preesistente non rinnovabile. Rifiuto rigenerazione automatica per proteggere il trust store.");
        }

        // Generazione on-device ex-novo
        try {
            Log.i(TAG, "Generazione on-device di nuova Root CA e Certificato Server SAN...");
            KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA");
            kpg.initialize(2048, new SecureRandom());

            KeyPair caPair = kpg.generateKeyPair();
            KeyPair serverPair = kpg.generateKeyPair();

            long now = System.currentTimeMillis();
            Date notBefore = new Date(now - 60000); // 1 minuto nel passato per clock skew tollerance
            Date notAfterCa = new Date(now + 1000L * 60 * 60 * 24 * 365 * 3); // 3 anni per CA
            Date notAfterServer = new Date(now + 1000L * 60 * 60 * 24 * 365); // 1 anno per Server

            // 1. Root CA locale autofirmata
            X509Certificate caCert = generateCertificate(
                CA_COMMON_NAME, CA_ORGANIZATION, CA_COUNTRY,
                caPair.getPublic(),
                CA_COMMON_NAME, CA_ORGANIZATION, CA_COUNTRY,
                caPair.getPrivate(),
                notBefore, notAfterCa,
                BigInteger.valueOf(1),
                true, null, null
            );

            // 2. Server Certificate con SAN completi
            List<String> dnsList = Arrays.asList("akai-tv.local", "localhost", "akai.local", "akai-jarvis.lan");
            List<String> ipList = new ArrayList<>(Arrays.asList("127.0.0.1"));
            if (localIp != null && !localIp.trim().isEmpty() && !ipList.contains(localIp.trim())) {
                ipList.add(localIp.trim());
            }

            X509Certificate serverCert = generateCertificate(
                SERVER_COMMON_NAME, CA_ORGANIZATION, CA_COUNTRY,
                serverPair.getPublic(),
                CA_COMMON_NAME, CA_ORGANIZATION, CA_COUNTRY,
                caPair.getPrivate(),
                notBefore, notAfterServer,
                BigInteger.valueOf(2),
                false, dnsList, ipList
            );

            // Calcolo impronta SHA-256 della CA
            String caFingerprint = computeSha256Fingerprint(caCert);
            String caPem = toPem(caCert);

            // Generazione password casuale sicura a 256-bit (32 caratteri hex)
            byte[] pwdBytes = new byte[16];
            new SecureRandom().nextBytes(pwdBytes);
            StringBuilder pwdSb = new StringBuilder();
            for (byte b : pwdBytes) pwdSb.append(String.format("%02x", b));
            char[] password = pwdSb.toString().toCharArray();

            // Salvataggio sicuro nel Keystore PKCS#12
            KeyStore ks = KeyStore.getInstance("PKCS12");
            ks.load(null, password);
            ks.setCertificateEntry("akai_ca", caCert);
            ks.setKeyEntry("akai_server", serverPair.getPrivate(), password, new Certificate[]{serverCert, caCert});

            saveKeystoreSafely(ks, ksFile, password);

            writeStringToFile(passFile, new String(password));
            passFile.setReadable(false, false);
            passFile.setReadable(true, true);
            passFile.setWritable(false, false);
            passFile.setWritable(true, true);

            writeStringToFile(caPemFile, caPem);

            caKeyFile = new File(filesDir, CA_KEY_FILE_NAME);
            try (FileOutputStream fosKey = new FileOutputStream(caKeyFile)) {
                fosKey.write(caPair.getPrivate().getEncoded());
            }
            // Protezione stringente Root CA Private Key: accessibile solo dall'UID dell'app
            caKeyFile.setReadable(false, false);
            caKeyFile.setReadable(true, true);
            caKeyFile.setWritable(false, false);
            caKeyFile.setWritable(true, true);

            File caCrtFile = new File(filesDir, CA_CERT_FILE_NAME);
            writeStringToFile(caCrtFile, caPem);

            List<String> allSans = new ArrayList<>();
            allSans.addAll(dnsList);
            allSans.addAll(ipList);

            cachedTlsInfo = new TlsInfo(caFingerprint, caPem, allSans, notAfterServer.getTime(), ksFile, password);
            Log.i(TAG, "Nuova Root CA creata con successo. Impronta CA SHA-256: " + caFingerprint);
            return cachedTlsInfo;
        } catch (Exception e) {
            Log.e(TAG, "Fallimento critico nella generazione TLS on-device: " + e.getMessage(), e);
            return null;
        }
    }

    public synchronized SSLContext createSSLContext(Context context, String localIp) {
        TlsInfo info = getOrGenerateTlsInfo(context, localIp);
        if (info == null || info.keystoreFile == null || !info.keystoreFile.exists()) {
            Log.e(TAG, "Impossibile creare SSLContext: TlsInfo non disponibile");
            return null;
        }
        try {
            KeyStore ks = KeyStore.getInstance("PKCS12");
            try (FileInputStream fis = new FileInputStream(info.keystoreFile)) {
                ks.load(fis, info.keyPassword);
            }
            KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
            kmf.init(ks, info.keyPassword);

            SSLContext sslContext = SSLContext.getInstance("TLS");
            sslContext.init(kmf.getKeyManagers(), null, new SecureRandom());
            return sslContext;
        } catch (Exception e) {
            Log.e(TAG, "Errore inizializzazione SSLContext da PKCS12: " + e.getMessage(), e);
            return null;
        }
    }

    public static String computeSha256Fingerprint(X509Certificate cert) throws Exception {
        MessageDigest md = MessageDigest.getInstance("SHA-256");
        byte[] digest = md.digest(cert.getEncoded());
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < digest.length; i++) {
            if (i > 0) sb.append(":");
            sb.append(String.format("%02X", digest[i]));
        }
        return sb.toString();
    }

    public static String toPem(X509Certificate cert) throws Exception {
        byte[] enc = cert.getEncoded();
        String b64 = Base64.encodeToString(enc, Base64.NO_WRAP);
        StringBuilder sb = new StringBuilder();
        sb.append("-----BEGIN CERTIFICATE-----\n");
        int idx = 0;
        while (idx < b64.length()) {
            int end = Math.min(idx + 64, b64.length());
            sb.append(b64.substring(idx, end)).append("\n");
            idx = end;
        }
        sb.append("-----END CERTIFICATE-----\n");
        return sb.toString();
    }

    private static List<String> extractSanStrings(X509Certificate cert) {
        List<String> res = new ArrayList<>();
        try {
            if (cert.getSubjectAlternativeNames() != null) {
                for (List<?> item : cert.getSubjectAlternativeNames()) {
                    if (item != null && item.size() >= 2) {
                        res.add(String.valueOf(item.get(1)));
                    }
                }
            }
        } catch (Exception ignored) {}
        return res;
    }

    private static char[] readPasswordFromFile(File file) throws IOException {
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(new FileInputStream(file), StandardCharsets.UTF_8))) {
            String line = reader.readLine();
            return (line != null) ? line.trim().toCharArray() : null;
        }
    }

    private static String readStringFromFile(File file) throws IOException {
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(new FileInputStream(file), StandardCharsets.UTF_8))) {
            StringBuilder sb = new StringBuilder();
            String l;
            while ((l = reader.readLine()) != null) {
                sb.append(l).append("\n");
            }
            return sb.toString();
        }
    }

    public static void saveKeystoreSafely(KeyStore ks, File targetFile, char[] password) throws Exception {
        File parentDir = targetFile.getParentFile();
        if (parentDir == null) parentDir = new File(".");
        File tmpFile = new File(parentDir, targetFile.getName() + ".tmp");
        File bakFile = new File(parentDir, targetFile.getName() + ".bak");

        if (tmpFile.exists()) {
            tmpFile.delete();
        }

        // 1. Scrittura su file temporaneo nello stesso filesystem privato con flush ed fsync obbligatorio
        try (FileOutputStream fos = new FileOutputStream(tmpFile)) {
            ks.store(fos, password);
            fos.flush();
            fos.getFD().sync();
        }
        tmpFile.setReadable(false, false);
        tmpFile.setReadable(true, true);
        tmpFile.setWritable(false, false);
        tmpFile.setWritable(true, true);

        // 2. Riapertura e verifica rigorosa dell'integrità crittografica del keystore temporaneo
        KeyStore verifyKs = KeyStore.getInstance("PKCS12");
        try (FileInputStream fis = new FileInputStream(tmpFile)) {
            verifyKs.load(fis, password);
        }
        if (verifyKs.getCertificate("akai_ca") == null || verifyKs.getCertificate("akai_server") == null) {
            tmpFile.delete();
            throw new IOException("Verifica fallita: certificati mancanti nel keystore PKCS12 temporaneo.");
        }
        if (!verifyKs.isKeyEntry("akai_server")) {
            tmpFile.delete();
            throw new IOException("Verifica fallita: chiave privata akai_server assente nel keystore PKCS12 temporaneo.");
        }

        // 3. Conservazione copia di backup della versione precedente verificata (.bak)
        // BLOCCO FAIL-CLOSED: se la copia .bak fallisce, interrompi categoricamente prima dello swap!
        if (targetFile.exists() && targetFile.length() > 0) {
            try {
                Files.copy(targetFile.toPath(), bakFile.toPath(),
                    StandardCopyOption.REPLACE_EXISTING);
                bakFile.setReadable(false, false);
                bakFile.setReadable(true, true);
                bakFile.setWritable(false, false);
                bakFile.setWritable(true, true);
            } catch (Exception bakEx) {
                tmpFile.delete();
                throw new IOException("Creazione backup .bak fallita prima dello swap atomico: " + bakEx.getMessage(), bakEx);
            }
            if (!bakFile.exists() || bakFile.length() != targetFile.length()) {
                tmpFile.delete();
                throw new IOException("Verifica integrità backup .bak fallita: dimensione non corrispondente prima dello swap atomico.");
            }
        }

        // 4. Sostituzione atomica del file di destinazione (ATOMIC_MOVE con fallback verificato)
        try {
            Files.move(tmpFile.toPath(), targetFile.toPath(),
                StandardCopyOption.ATOMIC_MOVE);
        } catch (Exception atomicEx) {
            Files.move(tmpFile.toPath(), targetFile.toPath(),
                StandardCopyOption.REPLACE_EXISTING);
        }
        if (!targetFile.exists() || targetFile.length() == 0) {
            if (bakFile.exists() && bakFile.length() > 0) {
                Files.copy(bakFile.toPath(), targetFile.toPath(), StandardCopyOption.REPLACE_EXISTING);
            }
            throw new IOException("Sostituzione keystore fallita: targetFile non presente o vuoto post-move.");
        }
        targetFile.setReadable(false, false);
        targetFile.setReadable(true, true);
        targetFile.setWritable(false, false);
        targetFile.setWritable(true, true);
    }

    private static void writeStringToFile(File file, String content) throws IOException {
        try (FileOutputStream fos = new FileOutputStream(file)) {
            fos.write(content.getBytes(StandardCharsets.UTF_8));
        }
    }

    // =========================================================================
    // ENCODER DER / ASN.1 PURO JAVA PER X.509 v3 (Zero Dipendenze Esterne)
    // =========================================================================

    private static byte[] encodeLength(int length) {
        if (length < 128) {
            return new byte[]{(byte) length};
        } else if (length < 256) {
            return new byte[]{(byte) 0x81, (byte) length};
        } else {
            return new byte[]{(byte) 0x82, (byte) (length >> 8), (byte) (length & 0xFF)};
        }
    }

    private static byte[] derSequence(byte[]... items) throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        for (byte[] item : items) {
            if (item != null) baos.write(item);
        }
        byte[] payload = baos.toByteArray();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0x30);
        out.write(encodeLength(payload.length));
        out.write(payload);
        return out.toByteArray();
    }

    private static byte[] derSet(byte[]... items) throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        for (byte[] item : items) {
            if (item != null) baos.write(item);
        }
        byte[] payload = baos.toByteArray();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0x31);
        out.write(encodeLength(payload.length));
        out.write(payload);
        return out.toByteArray();
    }

    private static byte[] derInteger(BigInteger val) throws IOException {
        byte[] bytes = val.toByteArray();
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0x02);
        out.write(encodeLength(bytes.length));
        out.write(bytes);
        return out.toByteArray();
    }

    private static byte[] derBitString(byte[] bytes) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0x03);
        out.write(encodeLength(bytes.length + 1));
        out.write(0x00); // 0 bit inutilizzati
        out.write(bytes);
        return out.toByteArray();
    }

    private static byte[] derOctetString(byte[] bytes) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0x04);
        out.write(encodeLength(bytes.length));
        out.write(bytes);
        return out.toByteArray();
    }

    private static byte[] derUtcTime(Date date) throws IOException {
        SimpleDateFormat sdf = new SimpleDateFormat("yyMMddHHmmss'Z'", Locale.US);
        sdf.setTimeZone(TimeZone.getTimeZone("UTC"));
        byte[] bytes = sdf.format(date).getBytes(StandardCharsets.US_ASCII);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(0x17);
        out.write(encodeLength(bytes.length));
        out.write(bytes);
        return out.toByteArray();
    }

    private static byte[] derRsaSha256AlgId() {
        // OID 1.2.840.113549.1.1.11 con parametro NULL
        return new byte[]{
            0x30, 0x0D,
            0x06, 0x09, 0x2A, (byte) 0x86, 0x48, (byte) 0x86, (byte) 0xF7, 0x0D, 0x01, 0x01, 0x0B,
            0x05, 0x00
        };
    }

    private static byte[] derName(String cn, String org, String country) throws IOException {
        List<byte[]> rdns = new ArrayList<>();
        if (country != null) {
            byte[] attr = derSequence(
                new byte[]{0x06, 0x03, 0x55, 0x04, 0x06},
                derString(0x13, country) // PrintableString
            );
            rdns.add(derSet(attr));
        }
        if (org != null) {
            byte[] attr = derSequence(
                new byte[]{0x06, 0x03, 0x55, 0x04, 0x0A},
                derString(0x0C, org) // UTF8String
            );
            rdns.add(derSet(attr));
        }
        if (cn != null) {
            byte[] attr = derSequence(
                new byte[]{0x06, 0x03, 0x55, 0x04, 0x03},
                derString(0x0C, cn) // UTF8String
            );
            rdns.add(derSet(attr));
        }
        return derSequence(rdns.toArray(new byte[0][]));
    }

    private static byte[] derString(int tag, String s) throws IOException {
        byte[] bytes = s.getBytes(StandardCharsets.UTF_8);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        out.write(tag);
        out.write(encodeLength(bytes.length));
        out.write(bytes);
        return out.toByteArray();
    }

    private static byte[] buildSanExtension(List<String> dnsNames, List<String> ipAddresses) throws IOException {
        ByteArrayOutputStream names = new ByteArrayOutputStream();
        if (dnsNames != null) {
            for (String dns : dnsNames) {
                byte[] b = dns.getBytes(StandardCharsets.US_ASCII);
                names.write((byte) 0x82); // [2] dNSName
                names.write(encodeLength(b.length));
                names.write(b);
            }
        }
        if (ipAddresses != null) {
            for (String ip : ipAddresses) {
                try {
                    byte[] b = InetAddress.getByName(ip).getAddress();
                    names.write((byte) 0x87); // [7] iPAddress
                    names.write(encodeLength(b.length));
                    names.write(b);
                } catch (Exception ignored) {}
            }
        }
        byte[] sanSeq = derSequence(names.toByteArray());
        byte[] extOid = new byte[]{0x06, 0x03, 0x55, 0x1D, 0x11}; // 2.5.29.17
        return derSequence(extOid, derOctetString(sanSeq));
    }

    private static byte[] buildBasicConstraints(boolean isCa) throws IOException {
        byte[] extOid = new byte[]{0x06, 0x03, 0x55, 0x1D, 0x13}; // 2.5.29.19
        byte[] valSeq = isCa ? derSequence(new byte[]{0x01, 0x01, (byte) 0xFF}) : derSequence();
        if (isCa) {
            return derSequence(extOid, new byte[]{0x01, 0x01, (byte) 0xFF}, derOctetString(valSeq)); // critical=true
        }
        return derSequence(extOid, derOctetString(valSeq));
    }

    private static byte[] buildKeyUsage(boolean isCa) throws IOException {
        byte[] extOid = new byte[]{0x06, 0x03, 0x55, 0x1D, 0x0F}; // 2.5.29.15
        if (isCa) {
            // keyCertSign (5), cRLSign (6) -> 00000110 in byte 0 = 0x06 con 1 bit inutilizzato (critical=true RFC 5280)
            byte[] bitString = new byte[]{0x03, 0x02, 0x01, 0x06};
            return derSequence(extOid, new byte[]{0x01, 0x01, (byte) 0xFF}, derOctetString(bitString));
        } else {
            // digitalSignature (0), keyEncipherment (2) -> 10100000 = 0xA0 con 5 bit inutilizzati
            byte[] bitString = new byte[]{0x03, 0x02, 0x05, (byte) 0xA0};
            return derSequence(extOid, new byte[]{0x01, 0x01, (byte) 0xFF}, derOctetString(bitString));
        }
    }

    private static byte[] buildExtendedKeyUsage() throws IOException {
        byte[] extOid = new byte[]{0x06, 0x03, 0x55, 0x1D, 0x25}; // 2.5.29.37
        // id-kp-serverAuth (1.3.6.1.5.5.7.3.1) obbligatorio per conformità Apple iOS 13+ / RFC 5280
        byte[] serverAuthOid = new byte[]{0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01};
        byte[] ekuSeq = derSequence(serverAuthOid);
        return derSequence(extOid, derOctetString(ekuSeq));
    }

    public static X509Certificate generateCertificate(
            String subjectCn, String subjectOrg, String subjectCountry,
            PublicKey subjectPub,
            String issuerCn, String issuerOrg, String issuerCountry,
            PrivateKey issuerPriv,
            Date notBefore, Date notAfter,
            BigInteger serial,
            boolean isCa,
            List<String> dnsNames, List<String> ipAddresses) throws Exception {

        byte[] version = new byte[]{(byte) 0xA0, 0x03, 0x02, 0x01, 0x02}; // v3
        byte[] serialDer = derInteger(serial);
        byte[] algId = derRsaSha256AlgId();
        byte[] issuer = derName(issuerCn, issuerOrg, issuerCountry);
        byte[] validity = derSequence(derUtcTime(notBefore), derUtcTime(notAfter));
        byte[] subject = derName(subjectCn, subjectOrg, subjectCountry);
        byte[] spki = subjectPub.getEncoded();

        List<byte[]> extList = new ArrayList<>();
        extList.add(buildBasicConstraints(isCa));
        extList.add(buildKeyUsage(isCa));
        if (!isCa) {
            extList.add(buildExtendedKeyUsage());
            if (dnsNames != null || ipAddresses != null) {
                extList.add(buildSanExtension(dnsNames, ipAddresses));
            }
        }
        byte[] extsSeq = derSequence(extList.toArray(new byte[0][]));
        ByteArrayOutputStream extsTagOut = new ByteArrayOutputStream();
        extsTagOut.write((byte) 0xA3);
        extsTagOut.write(encodeLength(extsSeq.length));
        extsTagOut.write(extsSeq);
        byte[] extsExplicit = extsTagOut.toByteArray();

        byte[] tbs = derSequence(version, serialDer, algId, issuer, validity, subject, spki, extsExplicit);

        Signature sig = Signature.getInstance("SHA256withRSA");
        sig.initSign(issuerPriv);
        sig.update(tbs);
        byte[] signatureBytes = sig.sign();
        byte[] sigBitString = derBitString(signatureBytes);

        byte[] certDer = derSequence(tbs, algId, sigBitString);

        CertificateFactory cf = CertificateFactory.getInstance("X.509");
        return (X509Certificate) cf.generateCertificate(new ByteArrayInputStream(certDer));
    }
}
