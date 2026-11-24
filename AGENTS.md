# AGENTS.md — AKAI JARVIS (owner invariants)

> Canonical developer instructions for all agents, coding assistants, GitHub automations and reviewers contributing to this branch. Explicit owner decisions take precedence over historical PR comments.

## HARD RULE — V4 COMPLETE FIRST, V5 DEBUG-OFF ONLY (OWNER LATEST, 18 NOV 2026)

**This is the owner's most recent release decision and OVERRIDES all older v5-first / optional OTA wording.** All four features are mandatory and implemented **already in v4 Diagnostic**: (1) robust multi-app navigation and validated goals within lawful Android/DRM limits, (2) owner-confirmed OTA usable on TV with PC powered off, (3) measured real-AKAI CPU/RAM/stability and no major regressions, (4) original-key-signed diagnostic APK plus proven APK/SQLite/WAL/TLS backup and device recovery path. Full binding acceptance plan: `docs/JARVIS_V4_COMPLETE_ACCEPTANCE.md`.

- Do not call v4 complete until these four gates have actually passed, including real hardware and OTA tests; before owner-authorized v4 device test, status is `V4_INCOMPLETE`. GitHub CI passing or an APK built with a temporary key is NOT equivalent.
- **The v5 adds NO new functions**: after v4 has been accepted on the TV, build the SAME audited application source with `BuildProfile=Release`, `android:debuggable=false` and only necessary monotonically increasing `versionCode`/`versionName` metadata. Keep the original signer; do not change AI, UI, OTA, memory, protocol or recovery logic while making v5. Verify the functional diff is empty.
- OTA is required **already in v4**; it remains owner-confirmed (no silent installs), authenticated and independently usable on TV with PC off. Never bypass protected DRM content to meet a navigation target; clearly label unsupported cases.
- If any v4 gate is missing, report `V4_INCOMPLETE` rather than moving the feature to v5. No automatic TV changes, no signing secrets on public GitHub, and no use of non-DeepSeek/Kimi LLM inference.

## HARD RULE — OWNER FINAL QUALITY GATE (18 Nov 2026)

**PERMANENT AND BLOCKING. Before stating a JARVIS change is DONE, READY, FIXED, SAFE or RELEASE-APPROVED, apply the full mandatory two-pass review protocol:** `docs/JARVIS_MANDATORY_SECOND_PASS_REVIEW.md`.

1. First verify the **saved exact Git HEAD**, diff, invariants, implementation and tests appropriate to the scope. Second, deliberately challenge the implementation, seek latent bugs, regressions, race conditions, corner cases, privacy and performance risks, and compare simpler or better alternatives. If a defect is fixed, restart both passes on the NEW HEAD. Prefer a different reviewer for the second pass; never misrepresent one review as independently verified.
2. Consult current **official** project/vendor documentation for all material compatibility/security/API/build assertions; record sources, versions and what was actually verified. Never assume Android OEM, github runner, API provider, APK signature or rollback behavior from mock tests.
3. Provide evidence: exact SHA, check/test execution (PASS/FAIL/BLOCKED/NOT_RUN), APK package/version/signature where relevant, limitations, residual P0/P1/P2, and explicit GO/NO-GO *for the stated stage*. `CI_BLOCKED_NOT_EXECUTED` is NOT green. Do not claim the TV was tested without TV evidence.
4. Only declare a stage finished after the second review; if evidence is missing, state **INCOMPLETE/BLOCKED** rather than a success claim. Do not weaken gates, introduce unnecessary refactors or install/deploy without the owner's separate authorization. Perfect absence of defects cannot be guaranteed; rigor and auditability are mandatory.

## HARD RULE — AI PROVIDERS (17 Nov 2026)

**All JARVIS reasoning, image understanding and autonomous AI inference MUST use only official DeepSeek or Kimi (Moonshot) cloud APIs. A narrowly scoped optional personal free voice-output exception is documented below; it is not an agent reasoning provider.**

- **Never add or execute a local AI model** on the AKAI TV, a PC, Termux, an edge box or any fallback compute node. The TV is Android 9/API28, ARMv7, ~1.5 GB RAM, unsuitable for LLM inference.
- **No third-party reasoning/vision/planning model/API providers**, model routers, on-device LLM, Ollama, LM Studio, ONNX LLM, quantized fallback, multi-provider proxy or paid AI service other than the owner-selected DeepSeek/Kimi provider. Optional FreeTTS must remain disabled without its separate owner consent and a personal free-only key.
- Explicitly distinguish local **deterministic software** (buttons, Accessibility, package inventory, parsed commands, SQLite, rule-based UI guards, orchestration) from a local **AI model** (forbidden). The historical `LOCAL_ONLY` label means "cloud disabled, deterministic operations only" and MUST NOT implement or promise local inference.
- If DeepSeek/Kimi is unavailable, unconfigured, unauthorized or out of budget, fail closed for AI reasoning. Existing deterministic TV remote controls may continue.
- Verify the active provider and request destination with `CloudProviderPolicy`. API keys are provider-specific, kept in Android Keystore; no cross-provider redirects, no public credentials and no API charges without owner consent.
- Cloud screenshot inference requires explicit consent at capture/session start **separately** from Android MediaProjection approval, no sensitive UI, bounded JPEG/timeout/budget, and must not execute unverified AI text as actions. One owner-approved visual session may capture up to 20 on-demand frames (3 minutes) without prompting on every frame, but must always offer immediate STOP and a visible foreground notification.

## OWNER DECISION 18 NOV — STAGED DIAGNOSTIC TEST AND PRODUCTION

- **Owner has authorized the DEVELOPMENT of an initial debuggable test build**, followed by real-TV tests performed by the owner, and only *after* successful testing a final non-debuggable update. This is **NOT** permission to remotely install, deploy, or modify the TV.
- Diagnostic APK **versionCode 4**: `scripts/12_build_jarvis_final_candidate.ps1` default `-BuildProfile Diagnostic`; AAPT2 `--debug-mode` sets `android:debuggable=true` **in the APK compiled manifest**, although the canonical repository `AndroidManifest.xml` remains `false` for production safety. The builder must independently inspect and verify the compiled flag before signing approval. Use original owner's signing key/cert, never debug.keystore or transient CI signer. Explicit output name `jarvis-v4-owner-signed-diagnostic.apk` and provenance `buildProfile=Diagnostic, debuggable=true`.
- **AAPT2 version replacement P0 fixed 18/11:** tracked AndroidManifest declares A2 `android:versionCode=3` and `android:versionName=1.2.0-a2-preview`. Official AAPT2 `--version-code` and `--version-name` do **not** override existing attributes without `--replace-version`. Both the owner-signed builder and CI v4/v5 compiled-profile builder MUST use `--replace-version`, and the resulting APK `aapt dump badging` must show vCode 4 Diagnostic / vCode 5+ Release. Source tests are NOT a substitute for executing AAPT2 on SDK28.
- Production APK **versionCode 5 or greater**: explicit `-BuildProfile Release`; `android:debuggable=false` or attribute absent **in APK compiled manifest**, same signing key/cert, versionCode strictly greater than actually installed. The owner decides after device tests; do not flip it prematurely or issue a second update now.
- Diagnostic builds are private, local-network test only, with owner-authorized ADB. A debuggable v4 does **NOT** guarantee Android accepts downgrade to the old non-debuggable A2 vCode3. The pre-install APK/SQLite/WAL/TLS backup and recoverability gates remain mandatory.
- P0 installer metadata was hardened in `05_safe_install_and_rollback.ps1` via fail-closed `aapt` version/package comparison. Mock E2E fixtures now emulate `aapt` and installed version explicitly instead of bypassing the production validator. All CI still must be green on exact final SHA, plus owner-original signing key and preflight before install.
- Important CI limitation: runs #44256709238 and #44261816387 etc reported failure with GitHub jobs showing 0 steps / empty runner, so code test conclusions cannot be inferred from those runs. Investigate runner/Actions scheduling or policy, retry on the exact head. Do not claim PASS until full completed/success run.

## RELEASE AND HARDWARE FREEZE

- The owner has installed A2 preview `it.akai.customremote` versionCode 3 (17 Nov 2026). It is being tested separately.
- **NO installation, ADB write, root, reset, deploy or merge without explicit owner authorization.** The owner has approved DEVELOPMENT of v4 Diagnostic for a separate owner-led installation/test after all gates pass; v5+ Release remains a second distinct approval. No unattended TV changes.
- Keep existing Launcher Home v8, Web Remote LAN, HTTPS TLS Root CA, native uinput, Android signing and SQLite memory intact.
- Build/test code on draft branches and PRs; GitHub Actions CI artifacts use ephemeral test signing/TLS and MUST NOT be installed on the TV.
- The real TV is not a CI runner. Report host/mock tests, Android APK build, remote API mock and real hardware evidence separately.
- Update memory and issue only with verified substantive results, SHA, CI state and remaining blocker; avoid reviews in comment loops.
- No promises of fully autonomous vision until visual fallback feeds the planner and goal verifier with verified evidence; MediaProjection cannot reliably capture DRM-protected apps.
- **Already in v4 Diagnostic**, OTA must work on-TV with PC off, require owner confirmation, signed/authenticated manifest, exact real APK SHA/signing cert checks and a verified recovery path. Its implementation must be verified before accepting v4. The v5 only disables debug and increments release metadata. See `docs/JARVIS_V4_COMPLETE_ACCEPTANCE.md`.

## MULTI-FRAME AUTONOMY + SELF-IMPROVEMENT (active implementation)

- **Real Android service**: `VisualProjectionService.java` reuses one MediaProjection/VirtualDisplay on Android 9, captures a fresh 960x540 RAM frame only on task request, provides a foreground STOP notification and expires automatically. It must not run on boot or keep a local LLM resident.
- **Owner approval UI**: `LocalVisualCaptureActivity.java` requests separate cloud session permission then Android's standard MediaProjection prompt; startup is opt-in only. No paid cloud call without approved active DeepSeek/Kimi key and budget.
- **Vision API and wiring**: `VisionSessionCoordinator` handles on-demand JPEG handoff via the bounded `VisualCaptureSessionGate`; `VisualObservationProvider` exposes the active session to the planner; `CloudVisionRequestPolicy` gates cloud image; `VisualObservationBridge` sanitizes results and blocks stale UI; `VisualStepPolicy` limits planning to one action before the next observation. No screenshot persisted.
- **Autonomous goal**: `AkaiAiController.processVisualGoalLocked` executes fresh screenshot -> chosen DeepSeek/Kimi image model -> text plan -> exactly one validated Android action -> re-observation -> native goal verifier. Limit 8 steps / 16 cloud calls / 2 minutes per task; maintain separate 3-minute MediaProjection cap and client-side budget.
- **Learning and adaptation**: `AkaiMemoryEngine` SQLite stores *only STATE_VERIFIED* skills; success/failure counters and `AgentSkillGate` quarantine unreliable skills. When a previously learned procedure fails, and the owner-approved vision session is active, JARVIS may rediscover the route and replace it **only after STATE_VERIFIED**. This is self-improvement of TV procedures, not self-editing code.
- **Owner Stop**: `AkaiAiController.cancelActiveTask` must revoke the capture session immediately via `VisualObservationProvider.stopAndRevoke`. No silent restart.
- **Test rigor**: host Java 40 tests, supplemental policy tests, simulated HTTP E2E and Android9 APK build. Do NOT claim the feature operates on real AKAI until a human confirms actual MediaProjection consent, JPEG frame updates across apps, remote vision API, memory preservation and rollback.
- **No unattended OTA/deploy.** Prepare owner-signed v4 Diagnostic for owner-led testing, then v5+ non-debuggable only after the separate owner approval. Preserve all release gates.

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
- The narrowly scoped TTS exception is NOT permission to expand AI provider policy, install neural models on the TV or bypass the owner-authorized staged v4/v5 installation gates. PR #18 remains Draft pending full CI, real TV tests and owner final release approval.
## OPTIONAL WEB REMOTE ITALIAN VOICE (17 NOV 2026)

- Important limitation: **JARVIS still speaks through eSpeak on the TV**. No natural Italian TTS voice has been installed on the AKAI TV. DeepSeek's official TTS docs do not currently list Italian; Kimi's official API does not offer TTS/ASR. Never claim that a natural voice is available on the television without device evidence.
- The Web Remote offers **explicitly opt-in Italian browser/system speech on the PHONE/REMOTE device**, not the TV speakers. The control is OFF after each page load. The client must accept only Italian browser voices with `localService === true`; if none are available it must leave `speak=true` for the TV's eSpeak.
- When selected, `/api/ai/ask` sends `speak=false` to avoid double audio and the response is played by the user's mobile OS/browser. Voice selection can prefer an already available enhanced local Italian voice; a name is not proof of naturalness. Never load an external TTS URL or add cloud provider/credentials. This is local platform output on the user's browser device; no AI reasoning is moved from DeepSeek/Kimi.
- STOP and opt-out must cancel browser audio, and a late AI response after opting out must not re-enable speech. In continuous conversation, wait until phone speech finishes before the microphone resumes. Full reply remains visible in the Web UI even without phone voice.
- Host regression `akai-remote-tests/test_web_local_italian_voice.js` runs in CI step `1a2`. Browser speech is not simulated on a real iPhone or Android device; test UI semantics and voices on actual hardware only after the owner-authorized release.
- The original phone-local voice option remains separate: FreeTTS personal free-tier speech, if enabled by the owner, can instead speak directly from the AKAI TV. Neither mode implies any APK deployment before the final owner-authorized update.

## CURRENT ENTRYPOINTS

- **MANDATORY two-pass final review and adversarial bug/optimization hunt:** `docs/JARVIS_MANDATORY_SECOND_PASS_REVIEW.md`.

- **LATEST mandatory full-v4 acceptance gates:** `docs/JARVIS_V4_COMPLETE_ACCEPTANCE.md`
- Final-release contract: `docs/JARVIS_FINAL_AGENT_OTA_RELEASE_CONTRACT.md`
- **Current P0 pre-install audit / NO-GO gates:** `docs/JARVIS_FINAL_PREINSTALL_AUDIT_20261118.md` (historic fail-open package/version bug was patched in installer, but full mock/Android CI still NOT_RUN; Android9 rollback remains unproven). Additional source review: `docs/JARVIS_PREHOME_HARDENING_SECOND_PASS_20261118.md`. Do not request install until owner-approved conservative recovery, APK signed original and strict metadata checks are actually demonstrated.
- Owner-led single-install handoff (signed APK, backups, TV test matrix): `docs/JARVIS_FINAL_OWNER_HANDOFF.md`
- Owner-local no-TV build recipe: `scripts/12_build_jarvis_final_candidate.ps1` (Diagnostic v4 **debuggable** for tests, later Release v5+ non-debuggable, original TV signing certificate; never CI ephemeral APK).
- GitHub tracking issue: #17
- Draft implementation PR: #18, stacked on A2 PR #16; A2 preparatory PRs #10, #12, #13, #14, #15.
- AI core: `akai-remote-tv/app/src/main/java/it/akai/customremote/ai/`
- Android activity: `akai-remote-tv/app/src/main/java/it/akai/customremote/LocalVisualCaptureActivity.java`
- CI: `.github/workflows/ci.yml` and host mock suite. **Runner blocked / offline gate:** `docs/JARVIS_CI_RUNNER_BLOCKER_20261118.md`, `python scripts/13_jarvis_offline_host_gate.py` (partial, not hardware/complete CI evidence).

## 17 NOV 2026 — REVOKED VISION / DEADLINES / FINAL CHANNEL EVIDENCE (SOURCE GATES)

The following changes are source-backed implementation in draft PR #18, **not hardware-verified** on the AKAI TV:

- `VisualObservationProvider.observe` must discard an in-flight cloud result if its exact consented session was revoked/replaced before it returned. Host mock tests simulate STOP and replacement; a reply from the old session cannot drive planning.
- `VisionSessionCoordinator.observe` must recheck owner task cancellation, active visual session and cloud consent immediately before the DeepSeek/Kimi JPEG upload. Its frame wait uses a monotonic Android clock, not wall-clock time.
- `AkaiAiController.processVisualGoalLocked` must recheck owner STOP / cloud consent before a planning call, after the cloud response, before Android action execution, and before saving a verified SQLite skill. A STOP notification must not authorize continuation of a visual plan.
- Visual goals must be limited by **elapsed monotonic time** (`System.nanoTime()` interval and `VisualStepPolicy.mayContinueElapsed`), not a user/NTP change to the TV's clock. Preserve wall-clock time for diagnostic timestamps only.
- `GoalEvidenceVerifier` requires a whole-token channel label for explicit Italia 2 or Rai 1 playback goals. Labels `Italia 20` / `Rai 10` cannot count as evidence; `Italia2` and `Rai1` compact OEM labels may qualify when paired with the existing independent player/audio signals. Absence of a reliable label must fail closed.
- Run host Java regression tests, source-contract tests and full Android9 ARMv7 CI on the **latest exact SHA**. These tests are not equivalent to a real Android 9 cancellation, DRM, frame timing or channel playback test. TV A2 Preview vCode3 is unchanged; **NO** intermediate deployment, paid AI calls or new local model.
