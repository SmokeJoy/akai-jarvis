#!/usr/bin/env python3
"""Source-backed invariants for no-billing FreeTTS voice, no paid endpoints.

This does not claim live provider availability, account eligibility, audio
quality or Android9 hardware playback. API requests are NEVER made by CI.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
AI = ROOT / "akai-remote-tv/app/src/main/java/it/akai/customremote/ai"


class FreeItalianVoiceSourceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.client = (AI / "FreeItalianTtsClient.java").read_text(encoding="utf-8")
        cls.coordinator = (AI / "FreeItalianTtsCoordinator.java").read_text(encoding="utf-8")
        cls.engine = (AI / "AkaiSpeechEngine.java").read_text(encoding="utf-8")
        cls.policy = (AI / "FreeItalianTtsPolicy.java").read_text(encoding="utf-8")
        cls.router = (AI.parent / "RestApiRouter.java").read_text(encoding="utf-8")
        cls.remote = (AI.parent / "RemoteServerService.java").read_text(encoding="utf-8")
        cls.web = (ROOT / "akai-remote-web/app.js").read_text(encoding="utf-8")
        cls.html = (ROOT / "akai-remote-web/index.html").read_text(encoding="utf-8")

    def test_only_free_personal_endpoint_and_bounded_download(self):
        self.assertIn('ENDPOINT = "https://freetts.org/api/v1/tts"', self.policy)
        self.assertIn('AUDIO_PREFIX = "https://freetts.org/api/audio/"', self.policy)
        self.assertIn('MAX_MONTHLY_CHARS = 5000', self.policy)
        self.assertIn('MAX_UTTERANCE_CHARS = 600', self.policy)
        self.assertIn('MAX_AUDIO_BYTES = 2 * 1024 * 1024', self.policy)
        self.assertIn('!"freetts.org".equalsIgnoreCase(url.getHost())', self.client)
        self.assertIn('conn.setInstanceFollowRedirects(false)', self.client)
        self.assertIn('readBounded(is, 8192)', self.client)
        self.assertIn('fileIdAllowed(id)', self.client)
        self.assertIn('public interface Cancellation', self.client)
        self.assertGreaterEqual(self.client.count('cancel.isCancelled()'), 4)
        self.assertIn('if (cancelled.isCancelled()) return;', self.coordinator)
        self.assertIn('request != generation', self.coordinator)
        self.assertIn('!prefs.getBoolean(CONSENT, false)', self.coordinator)

        self.assertIn('setRequestProperty("x-api-key", freeApiKey)', self.client)
        self.assertNotIn('azure', self.client.lower())
        self.assertNotIn('microsoft.com', self.client.lower())

    def test_no_net_without_owner_opt_in_and_durable_local_quota(self):
        self.assertIn('input.optBoolean("free_tts_consent", false)', self.coordinator)
        self.assertIn('input.optBoolean("free_tier_confirmed", false)', self.coordinator)
        self.assertIn('KeystoreSecurityHelper.encrypt(rawKey)', self.coordinator)
        self.assertIn('KeystoreSecurityHelper.decrypt(stored)', self.coordinator)
        self.assertIn('if (apiKey.isEmpty() || !reserve(text)) return false;', self.coordinator)
        self.assertIn('if (!editor.commit()) return false;', self.coordinator)
        self.assertIn('.putInt(CHARS, next).commit()', self.coordinator)
        self.assertIn('ExecutorService worker = Executors.newSingleThreadExecutor()', self.coordinator)
        self.assertIn('main.post(new Runnable()', self.coordinator)
        self.assertIn('if (request != generation)', self.coordinator)
        self.assertIn('events.onFallback(text)', self.coordinator)
        self.assertIn('mMemoryEngine.isGuestMode()', self.engine)
        self.assertIn('mFreeVoice.stop()', self.engine)
        self.assertNotIn('new CloudSpeechAdapter(', self.engine)

    def test_endpoint_is_authenticated_and_no_key_in_readback(self):
        self.assertIn('default JSONObject getTtsConfig()', self.router)
        self.assertIn('aiHandler.saveTtsConfig(req)', self.router)
        self.assertIn('cfg.remove("freetts_api_key")', self.router)
        self.assertIn('out.remove("freetts_api_key")', self.router)
        self.assertIn('it.akai.customremote.ai.FreeItalianTtsPolicy.voiceAllowed(voice)', self.router)
        self.assertIn('getTtsConfig()', self.remote)
        self.assertIn('saveTtsConfig(JSONObject settings)', self.remote)

    def test_web_disables_tts_by_default_until_explicit_action(self):
        self.assertIn('value="offline_espeak" selected', self.html)
        self.assertIn('id="free-tts-api-key"', self.html)
        self.assertIn('id="free-tts-consent"', self.html)
        self.assertIn('id="free-tts-free-plan"', self.html)
        self.assertIn('cloudSpeech && (!consent || !confirmedFree)', self.web)
        self.assertIn('free_tts_consent: cloudSpeech && consent', self.web)
        self.assertIn('free_tier_confirmed: cloudSpeech && confirmedFree', self.web)
        self.assertIn("if (cloudSpeech && key) payload.freetts_api_key = key;", self.web)
        self.assertNotIn('azure-speech-key-input', self.web)


if __name__ == "__main__":
    unittest.main()
