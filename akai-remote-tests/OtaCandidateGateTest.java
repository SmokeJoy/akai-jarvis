package it.akai.customremote;

import it.akai.customremote.ai.OtaCandidateGate;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

public final class OtaCandidateGateTest {
    private static final String SIGNER = OtaCandidateGate.EXPECTED_SIGNER_SHA256;
    private static final String HASH = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899";
    private static final Set<String> TRUSTED = Collections.singleton("updates.nolimits3d.example");
    private static int checks;

    private static OtaCandidateGate.Candidate candidate(String pkg, int version, String signer,
                        String sha, String url, String abi, int sdk, long size, String channel) {
        return new OtaCandidateGate.Candidate(pkg, version, signer, sha, url, abi, sdk, size, channel);
    }

    private static OtaCandidateGate.Candidate good() {
        return candidate(OtaCandidateGate.PACKAGE, 4, SIGNER, HASH,
                "https://updates.nolimits3d.example/releases/jarvis-4.apk",
                "armeabi-v7a", 21, 512_000L, "stable");
    }

    private static void expect(String label, boolean expected, OtaCandidateGate.Candidate c,
                               int installed, String signer, Set<String> hosts) {
        OtaCandidateGate.Verdict result = OtaCandidateGate.inspect(c, installed, signer, hosts);
        if (result.eligibleForDownload != expected) {
            throw new AssertionError(label + ": " + result.code);
        }
        checks++;
    }

    public static void main(String[] args) {
        OtaCandidateGate.Candidate c = good();
        expect("stable upgrade", true, c, 3, SIGNER, TRUSTED);
        expect("same version", false, c, 4, SIGNER, TRUSTED);
        expect("downgrade", false, c, 7, SIGNER, TRUSTED);
        expect("no installed version", false, c, 0, SIGNER, TRUSTED);
        expect("wrong installed signer", false, c, 3, HASH, TRUSTED);
        expect("no host allowlist", false, c, 3, SIGNER, Collections.<String>emptySet());
        expect("null candidate", false, null, 3, SIGNER, TRUSTED);
        expect("null allowlist", false, c, 3, SIGNER, null);
        expect("wrong package", false, candidate("org.example.fake",4,SIGNER,HASH,c.downloadUrl,c.abi,21,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);
        expect("wrong candidate signer", false, candidate(c.packageName,4,HASH,HASH,c.downloadUrl,c.abi,21,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);
        expect("missing checksum", false, candidate(c.packageName,4,SIGNER,"",c.downloadUrl,c.abi,21,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);
        expect("preview excluded", false, candidate(c.packageName,4,SIGNER,HASH,c.downloadUrl,c.abi,21,c.sizeBytes,"preview"), 3,SIGNER,TRUSTED);
        expect("arm64 incompatible", false, candidate(c.packageName,4,SIGNER,HASH,c.downloadUrl,"arm64-v8a",21,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);
        expect("sdk 29 incompatible", false, candidate(c.packageName,4,SIGNER,HASH,c.downloadUrl,c.abi,29,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);
        expect("tiny apk", false, candidate(c.packageName,4,SIGNER,HASH,c.downloadUrl,c.abi,21,10L,"stable"), 3,SIGNER,TRUSTED);
        expect("huge apk", false, candidate(c.packageName,4,SIGNER,HASH,c.downloadUrl,c.abi,21,26L*1024L*1024L,"stable"), 3,SIGNER,TRUSTED);
        expect("http rejected", false, candidate(c.packageName,4,SIGNER,HASH,"http://updates.nolimits3d.example/file.apk",c.abi,21,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);
        expect("host spoof rejected", false, candidate(c.packageName,4,SIGNER,HASH,"https://updates.nolimits3d.example.evil.test/file.apk",c.abi,21,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);
        expect("userinfo spoof rejected", false, candidate(c.packageName,4,SIGNER,HASH,"https://updates.nolimits3d.example@evil.test/file.apk",c.abi,21,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);
        expect("non-443 port rejected", false, candidate(c.packageName,4,SIGNER,HASH,"https://updates.nolimits3d.example:8443/file.apk",c.abi,21,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);
        expect("fragment rejected", false, candidate(c.packageName,4,SIGNER,HASH,"https://updates.nolimits3d.example/file.apk#x",c.abi,21,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);
        expect("not an apk", false, candidate(c.packageName,4,SIGNER,HASH,"https://updates.nolimits3d.example/file.zip",c.abi,21,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);
        expect("signed URL allowed", true, candidate(c.packageName,4,SIGNER,HASH,c.downloadUrl+"?expires=123",c.abi,21,c.sizeBytes,"stable"), 3,SIGNER,TRUSTED);

        byte[] digest = new byte[32];
        for (int i=0; i<32; i++) digest[i]=(byte)i;
        StringBuilder h=new StringBuilder();
        for (byte b:digest) h.append(String.format("%02x",b & 0xff));
        if (!OtaCandidateGate.digestMatches(digest,h.toString())) throw new AssertionError("valid digest");
        checks++;
        digest[0] ^= 1;
        if (OtaCandidateGate.digestMatches(digest,h.toString())) throw new AssertionError("tampered digest accepted");
        checks++;
        if (OtaCandidateGate.digestMatches(null,h.toString())) throw new AssertionError("null digest accepted");
        checks++;
        System.out.println("OtaCandidateGateTest PASS: "+checks+" checks (metadata only; no APK installation)");
    }
}
