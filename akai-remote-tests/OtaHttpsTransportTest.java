package it.akai.customremote;

import it.akai.customremote.ai.OtaCandidateGate;
import it.akai.customremote.ai.OtaHttpsTransport;
import it.akai.customremote.ai.OtaSignedReleaseManifest;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Signature;
import java.util.Collections;
import java.util.Set;

public final class OtaHttpsTransportTest {
    private static final Set<String> HOSTS = Collections.singleton("updates.example.com");
    private static int checks;

    private static void url(boolean expected, String input, String suffix, String label) {
        boolean safe = OtaHttpsTransport.safeHttpsEndpoint(input, HOSTS, suffix);
        if (safe != expected) throw new AssertionError(label);
        checks++;
    }

    private static void rejectedRead(InputStream input, int limit, String label) {
        try {
            OtaHttpsTransport.readBounded(input, limit);
            throw new AssertionError("accepted " + label);
        } catch (IOException expected) {
            checks++;
        }
    }

    public static void main(String[] args) throws Exception {
        url(true, "https://updates.example.com/jarvis.manifest", ".manifest", "manifest HTTPS");
        url(true, "https://updates.example.com/jarvis.sig", ".sig", "signature HTTPS");
        url(true, "https://updates.example.com/jarvis.apk?version=5", ".apk", "signed URL");
        url(false, "http://updates.example.com/jarvis.apk", ".apk", "http downgrade");
        url(false, "https://updates.example.com.evil.test/jarvis.apk", ".apk", "host spoof");
        url(false, "https://updates.example.com@evil.test/jarvis.apk", ".apk", "userinfo spoof");
        url(false, "https://updates.example.com:8443/jarvis.apk", ".apk", "untrusted port");
        url(false, "https://updates.example.com/jarvis.apk#x", ".apk", "fragment");
        url(false, "https://updates.example.com/jarvis.zip", ".apk", "wrong suffix");
        url(false, null, ".apk", "null URL");

        byte[] a = new byte[] {1, 2, 3, 4};
        byte[] read = OtaHttpsTransport.readBounded(new ByteArrayInputStream(a), 4);
        if (read.length != a.length || read[0] != 1 || read[3] != 4)
            throw new AssertionError("bounded response content mismatch");
        checks++;
        rejectedRead(new ByteArrayInputStream(a), 3, "oversized body");
        rejectedRead(new ByteArrayInputStream(new byte[0]), 4, "empty body");
        rejectedRead(null, 4, "missing source");
        rejectedRead(new ByteArrayInputStream(a), 0, "zero bound");
        rejectedRead(new ByteArrayInputStream(a),
                OtaCandidateGate.MAX_MANIFEST_BYTES + 1, "oversized bound");
        rejectedRead(new InputStream() {
            @Override public int read() throws IOException { throw new IOException("broken"); }
            @Override public int read(byte[] b) throws IOException { throw new IOException("broken"); }
        }, 4, "stream exception");
        rejectedRead(new InputStream() {
            @Override public int read() { return 0; }
            @Override public int read(byte[] b, int offset, int length) { return 0; }
        }, 4, "repeated zero reads");

        // Neither unsigned Candidate metadata nor an untrusted signature can
        // authorize staging; do not perform network operations in host tests.
        KeyPairGenerator keygen = KeyPairGenerator.getInstance("RSA");
        keygen.initialize(2048);
        KeyPair key = keygen.generateKeyPair();
        byte[] manifest = ("format=jarvis-ota-v1\n"
                + "package=it.akai.customremote\nversionCode=5\n"
                + "signerSha256=" + OtaCandidateGate.EXPECTED_SIGNER_SHA256 + "\n"
                + "apkSha256=aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899\n"
                + "url=https://updates.example.com/jarvis.apk\n"
                + "abi=armeabi-v7a\nminSdk=21\nsizeBytes=2048\nchannel=stable\n")
                .getBytes(StandardCharsets.US_ASCII);
        Signature sig = Signature.getInstance("SHA256withRSA");
        sig.initSign(key.getPrivate());
        sig.update(manifest);
        byte[] detached = sig.sign();
        byte[] badSig = detached.clone();
        badSig[0] ^= 1;
        OtaSignedReleaseManifest.Result rejected = OtaSignedReleaseManifest.verify(
                manifest, badSig, key.getPublic(), 4,
                OtaCandidateGate.EXPECTED_SIGNER_SHA256, HOSTS);
        if (rejected.verified()) throw new AssertionError("bad signature accepted by manifest gate");
        try {
            OtaHttpsTransport.stageVerifiedApk(rejected, HOSTS, null);
            throw new AssertionError("unverified manifest reached stage");
        } catch (IOException expected) {
            checks++;
        }
        OtaSignedReleaseManifest.Result approved = OtaSignedReleaseManifest.verify(
                manifest, detached, key.getPublic(), 4,
                OtaCandidateGate.EXPECTED_SIGNER_SHA256, HOSTS);
        if (!approved.verified()) throw new AssertionError("fixture manifest not verified");
        try {
            OtaHttpsTransport.stageVerifiedApk(approved, HOSTS, null);
            throw new AssertionError("missing private storage accepted");
        } catch (IOException expected) {
            checks++;
        }

        System.out.println("OtaHttpsTransportTest PASS: " + checks +
                " checks (URL/body/staging gates only, NO outbound HTTP)");
    }
}
