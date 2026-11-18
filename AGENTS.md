# AGENTS.md — AKAI JARVIS (owner invariants)

> Canonical developer instructions for all agents, coding assistants, GitHub automations and reviewers contributing to this branch. Explicit owner decisions take precedence over historical PR comments.

## HARD RULE — AI PROVIDERS (17 Nov 2026)

**All JARVIS reasoning, image understanding and autonomous AI inference MUST use only official DeepSeek or Kimi (Moonshot) cloud APIs. A narrowly scoped optional personal free voice-output exception is documented below; it is not an agent reasoning provider.**

- **Never add or execute a local AI model** on the AKAI TV, a PC, Termux, an edge box or any fallback compute node. The TV is Android 9/API28, ARMv7, ~1.5 GB RAM, unsuitable for LLM inference.
- **No third-party reasoning/vision/planning model/API providers**, model routers, on-device LLM, Ollama, LM Studio, ONNX LLM, quantized fallback, multi-provider proxy or paid AI service other than the owner-selected DeepSeek/Kimi provider. Optional FreeTTS must remain disabled without its separate owner consent and a personal free-only key.
- Explicitly distinguish local **deterministic software** (buttons, Accessibility, package inventory, parsed commands, SQLite, rule-based UI guards, orchestration) from a local **AI model** (forbidden). The historical `LOCAL_ONLY` label means "cloud disabled, deterministic operations only" and MUST NOT implement or promise local inference.
- If DeepSeek/Kimi is unavailable, unconfigured, unauthorized or out of budget, fail closed for AI reasoning. Existing deterministic TV remote controls may continue.
- Verify the active provider and request destination with `CloudProviderPolicy`. API keys are provider-specific, kept in Android Keystore; no cross-provider redirects, no public credentials and no API charges without owner consent.
- Cloud screenshot inference requires explicit consent at capture/session start **separately** from Android MediaProjection approval, no sensitive UI, bounded JPEG/timeout/budget, and must not execute unverified AI text as actions. One owner-approved visual session may capture up to 20 on-demand frames (3 minutes) without prompting on every frame, but must always offer immediate STOP and a visible foreground notification.

## RELEASE AND HARDWARE FREEZE

- The owner has installed A2 preview `it.akai.customremote` versionCode 3 (17 Nov 2026). It is being tested separately.
- **No intermediate installs/upgrades/ADB write/root/reset/deploy/merge** until one final full agent release, barring a distinct, explicitly owner-approved emergency.
- Keep existing Launcher Home v8, Web Remote LAN, HTTPS TLS Root CA, native uinput, Android signing and SQLite memory intact.
- Build/test code on draft branches and PRs; GitHub Actions CI artifacts use ephemeral test signing/TLS and MUST NOT be installed on the TV.
- The real TV is not a CI runner. Report host/mock tests, Android APK build, remote API mock and real hardware evidence separately.
- Update memory and issue only with verified substantive results, SHA, CI state and remaining blocker; avoid reviews in comment loops.
- No promises of fully autonomous vision until visual fallback feeds the planner and goal verifier with verified evidence; MediaProjection cannot reliably capture DRM-protected apps.
- Release OTA is optional and must require owner confirmation, signed manifest, exact APK SHA/signing cert checks and a verified rollback path; private GitHub is not a secret-free OTA endpoint.

## MULTI-FRAME AUTONOMY + SELF-IMPROVEMENT (active implementation)

- **Real Android service**: `VisualProjectionService.java` reuses one MediaProjection/VirtualDisplay on Android 9, captures a fresh 960x540 RAM frame only on task request, provides a foreground STOP notification and expires automatically. It must not run on boot or keep a local LLM resident.
- **Owner approval UI**: `LocalVisualCaptureActivity.java` requests separate cloud session permission then Android's standard MediaProjection prompt; startup is opt-in only. No paid cloud call without approved active DeepSeek/Kimi key and budget.
- **Vision API and wiring**: `VisionSessionCoordinator` handles on-demand JPEG handoff via the bounded `VisualCaptureSessionGate`; `VisualObservationProvider` exposes the active session to the planner; `CloudVisionRequestPolicy` gates cloud image; `VisualObservationBridge` sanitizes results and blocks stale UI; `VisualStepPolicy` limits planning to one action before the next observation. No screenshot persisted.
- **Autonomous goal**: `AkaiAiController.processVisualGoalLocked` executes fresh screenshot -> chosen DeepSeek/Kimi image model -> text plan -> exactly one validated Android action -> re-observation -> native goal verifier. Limit 8 steps / 16 cloud calls / 2 minutes per task; maintain separate 3-minute MediaProjection cap and client-side budget.
- **Learning and adaptation**: `AkaiMemoryEngine` SQLite stores *only STATE_VERIFIED* skills; success/failure counters and `AgentSkillGate` quarantine unreliable skills. When a previously learned procedure fails, and the owner-approved vision session is active, JARVIS may rediscover the route and replace it **only after STATE_VERIFIED**. This is self-improvement of TV procedures, not self-editing code.
- **Owner Stop**: `AkaiAiController.cancelActiveTask` must revoke the capture session immediately via `VisualObservationProvider.stopAndRevoke`. No silent restart.
- **Test rigor**: host Java 40 tests, supplemental policy tests, simulated HTTP E2E and Android9 APK build. Do NOT claim the feature operates on real AKAI until a human confirms actual MediaProjection consent, JPEG frame updates across apps, remote vision API, memory preservation and rollback.
- **No intermediate OTA/deploy**; prepare the single final user-authorized update. Continue development until all explicit release gates pass.

## LEGACY SPEECH POLICY AND TTS LIFECYCLE (17 NOV 2026)

- `AkaiSpeechEngine` defaults to Android eSpeak offline (`com.reecedunn.espeak`); never use an unknown default engine or Azure Neural API/account. Owner may optionally enable FreeTTS personal free-tier Italian speech via explicit Web TV consent; eSpeak is fallback. Neither mode runs a local LLM.
- Legacy `CloudSpeechAdapter.speakNeural` and `fetchFromAzure` remain inert. FreeTTS uses a separate allowlisted free-voice-only path, never Azure account credentials or paid subscription. No raw TTS key may be shown in GitHub, logs or REST GET.
- `SpeechUtteranceGate` rejects stale/duplicate callbacks after STOP, replacement or session change. Android callbacks that alter focus/state are synchronized with `speak` and `stop`; utterance IDs use a monotonically incrementing request sequence rather than wall-clock milliseconds.
- CI `4j` runs pure Java gate regressions and a source policy contract. The complete Android9 build must pass on the exact HEAD. **No real AKAI eSpeak/AudioFocus success is claimed yet**; test actual speech, rapid interrupt, missing eSpeak, and volume/audio-focus coexistence at the single owner-authorized final release.
- Historical Azure preferences and method signatures remain inert; `getTtsVoice()` reports only eSpeak. Web Remote removes Azure voice options, credential/region inputs, and cloud audio-cache controls. `RestApiRouter` exposes authenticated GET/POST offline-only TTS config and denies Azure voice/key/region or preview **in both LOCAL_ONLY and CLOUD_OPTIONAL**. Java REST tests and Web/source checks are added; check the CI HEAD. No real TV speech success is asserted.

## OWNER VOICE DECISION — FREE ITALIAN AUDIO FROM TV SPEAKERS

- The owner rejected Azure account billing and requested a free natural Italian voice from the AKAI TV speakers with the PC off. This authorizes implementation of a narrow FreeTTS personal free voice-output option, NOT any third-party reasoning/vision/planning provider.
- FreeTTS Developer API requires a personal free-only account and API key; free output may have an audible watermark and is non-commercial. Its public docs describe inconsistent monthly quotas: JARVIS independently hard-stops at 5,000 characters per UTC month, 600 characters per utterance and 2 MiB per MP3. Failed attempts also consume the local reserved quota.
- The owner must enable separate cloud TTS consent and confirm use of the FREE personal tier; default mode is eSpeak, no key and zero cloud TTS calls. FreeTTS key is encrypted with Android Keystore in private SharedPreferences and never exposed via REST GET or web readback. No app-managed subscription, paid plan, credit card, overage purchase, upgrade or fallback to other remote providers.
- Use the official FreeTTS POST https://freetts.org/api/v1/tts and returned validated file ID with GET https://freetts.org/api/audio/{id} only; direct HTTPS host allowlist and no redirects. Skip requests containing sensitive-looking text; all network on a bounded worker, one active speech stream, STOP invalidates late responses, delete temporary MP3 after playback. On any error, fall back to offline eSpeak.
- FreeTTS synthesizes speech output only: permitted voice IDs it-IT-DiegoNeural and it-IT-IsabellaNeural. Never send image, code, private memory or credentials as TTS content. It uses Azure behind the FreeTTS proxy, but the user does NOT need an Azure account; do not misrepresent upstream processing or promise free availability forever.
- Code: FreeItalianTtsPolicy.java, FreeItalianTtsClient.java, FreeItalianTtsCoordinator.java, AkaiSpeechEngine.java, RestApiRouter.java, RemoteServerService.java, Web Remote voice configuration. CI: pure Java policy, Android build, TTS source-contract and REST mock. No paid API calls, no tested free account, no device playback verification yet.
- The narrowly scoped TTS exception is NOT permission to expand AI provider policy, install neural models on the TV or merge/install an intermediate release. PR #18 remains Draft pending full CI, real TV tests and owner final release approval.
## OPTIONAL WEB REMOTE ITALIAN VOICE (17 NOV 2026)

- Important limitation: **JARVIS still speaks through eSpeak on the TV**. No natural Italian TTS voice has been installed on the AKAI TV. DeepSeek's official TTS docs do not currently list Italian; Kimi's official API does not offer TTS/ASR. Never claim that a natural voice is available on the television without device evidence.
- The Web Remote offers **explicitly opt-in Italian browser/system speech on the PHONE/REMOTE device**, not the TV speakers. The control is OFF after each page load. The client must accept only Italian browser voices with `localService === true`; if none are available it must leave `speak=true` for the TV's eSpeak.
- When selected, `/api/ai/ask` sends `speak=false` to avoid double audio and the response is played by the user's mobile OS/browser. Voice selection can prefer an already available enhanced local Italian voice; a name is not proof of naturalness. Never load an external TTS URL or add cloud provider/credentials. This is local platform output on the user's browser device; no AI reasoning is moved from DeepSeek/Kimi.
- STOP and opt-out must cancel browser audio, and a late AI response after opting out must not re-enable speech. In continuous conversation, wait until phone speech finishes before the microphone resumes. Full reply remains visible in the Web UI even without phone voice.
- Host regression `akai-remote-tests/test_web_local_italian_voice.js` runs in CI step `1a2`. Browser speech is not simulated on a real iPhone or Android device; test UI semantics and voices on actual hardware only after the owner-authorized release.
- The original phone-local voice option remains separate: FreeTTS personal free-tier speech, if enabled by the owner, can instead speak directly from the AKAI TV. Neither mode implies any APK deployment before the final owner-authorized update.

## CURRENT ENTRYPOINTS

- Final-release contract: `docs/JARVIS_FINAL_AGENT_OTA_RELEASE_CONTRACT.md`
- **Current P0 pre-install audit / NO-GO gates:** `docs/JARVIS_FINAL_PREINSTALL_AUDIT_20261118.md` (rollback Android9 + fail-open candidate package/version check). Do not request install until owner-approved conservative recovery and strict metadata validation are demonstrated.
- Owner-led single-install handoff (signed APK, backups, TV test matrix): `docs/JARVIS_FINAL_OWNER_HANDOFF.md`
- Owner-local no-TV build recipe: `scripts/12_build_jarvis_final_candidate.ps1` (versionCode 4+, same TV signing cert; no debug/CI APK).
- GitHub tracking issue: #17
- Draft implementation PR: #18, stacked on A2 PR #16; A2 preparatory PRs #10, #12, #13, #14, #15.
- AI core: `akai-remote-tv/app/src/main/java/it/akai/customremote/ai/`
- Android activity: `akai-remote-tv/app/src/main/java/it/akai/customremote/LocalVisualCaptureActivity.java`
- CI: `.github/workflows/ci.yml` and host mock suite.

## 17 NOV 2026 — REVOKED VISION / DEADLINES / FINAL CHANNEL EVIDENCE (SOURCE GATES)

The following changes are source-backed implementation in draft PR #18, **not hardware-verified** on the AKAI TV:

- `VisualObservationProvider.observe` must discard an in-flight cloud result if its exact consented session was revoked/replaced before it returned. Host mock tests simulate STOP and replacement; a reply from the old session cannot drive planning.
- `VisionSessionCoordinator.observe` must recheck owner task cancellation, active visual session and cloud consent immediately before the DeepSeek/Kimi JPEG upload. Its frame wait uses a monotonic Android clock, not wall-clock time.
- `AkaiAiController.processVisualGoalLocked` must recheck owner STOP / cloud consent before a planning call, after the cloud response, before Android action execution, and before saving a verified SQLite skill. A STOP notification must not authorize continuation of a visual plan.
- Visual goals must be limited by **elapsed monotonic time** (`System.nanoTime()` interval and `VisualStepPolicy.mayContinueElapsed`), not a user/NTP change to the TV's clock. Preserve wall-clock time for diagnostic timestamps only.
- `GoalEvidenceVerifier` requires a whole-token channel label for explicit Italia 2 or Rai 1 playback goals. Labels `Italia 20` / `Rai 10` cannot count as evidence; `Italia2` and `Rai1` compact OEM labels may qualify when paired with the existing independent player/audio signals. Absence of a reliable label must fail closed.
- Run host Java regression tests, source-contract tests and full Android9 ARMv7 CI on the **latest exact SHA**. These tests are not equivalent to a real Android 9 cancellation, DRM, frame timing or channel playback test. TV A2 Preview vCode3 is unchanged; **NO** intermediate deployment, paid AI calls or new local model.
