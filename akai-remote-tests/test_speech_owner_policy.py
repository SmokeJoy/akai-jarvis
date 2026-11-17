#!/usr/bin/env python3
"""Source policy checks for forbidden Azure speech and stale TTS callbacks.

These checks do not simulate an Android 9 audio engine or prove that eSpeak
initializes on the physical television; the APK build provides compile coverage.
"""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
AI = ROOT / "akai-remote-tv/app/src/main/java/it/akai/customremote/ai"


class SpeechOwnerPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.engine = (AI / "AkaiSpeechEngine.java").read_text(encoding="utf-8")
        cls.cloud = (AI / "CloudSpeechAdapter.java").read_text(encoding="utf-8")

    def test_azure_not_called_by_speech_engine(self):
        self.assertNotIn(".speakNeural(", self.engine)
        self.assertIn("return speakOfflineTts(text, interrupt);", self.engine)
        self.assertIn("return speakOfflineTts(text, true);", self.engine)
        self.assertNotIn("new CloudSpeechAdapter(", self.engine)
        self.assertIn("new TextToSpeech(mContext, this, PREFERRED_OFFLINE_ENGINE)", self.engine)
        self.assertNotIn("new TextToSpeech(mContext, this)", self.engine)
        self.assertNotIn("mTts.setSpeechRate(1.0f)", self.engine)
        self.assertNotIn("mTts.setPitch(1.0f)", self.engine)

    def test_legacy_cloud_adapter_is_inert(self):
        method = self.cloud.split("public synchronized boolean speakNeural(", 1)[1]
        method = method.split("private File fetchFromAzure(", 1)[0]
        self.assertIn("return false;", method)
        self.assertNotIn("openConnection(", self.cloud)
        self.assertNotIn("tts.speech.microsoft.com", self.cloud)
        self.assertNotIn("Ocp-Apim-Subscription-Key", self.cloud)
        fetch = self.cloud.split("private File fetchFromAzure(", 1)[1]
        fetch = fetch.split("private synchronized boolean playAudioFile(", 1)[0]
        self.assertIn("return null;", fetch)

    def test_stale_callback_guard_wired_to_android_tts(self):
        self.assertIn("mOfflineGate.activate(utteranceId);", self.engine)
        self.assertIn("mOfflineGate.isCurrent(utteranceId)", self.engine)
        self.assertGreaterEqual(self.engine.count("finishOfflineUtterance(utteranceId)"), 4)
        self.assertIn('"akai_offline_" + mSpeechId.get()', self.engine)
        self.assertNotIn('"akai_offline_" + System.currentTimeMillis()', self.engine)
        stop = self.engine.split("public synchronized void stop() {", 1)[1]
        self.assertLess(stop.index("mOfflineGate.stop();"), stop.index("mTts.stop()"))


if __name__ == "__main__":
    unittest.main()
