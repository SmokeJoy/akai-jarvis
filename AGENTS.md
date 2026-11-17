# AGENTS.md — AKAI JARVIS (owner invariants)

> Canonical developer instructions for all agents, coding assistants, GitHub automations and reviewers contributing to this branch. Explicit owner decisions take precedence over historical PR comments.

## HARD RULE — AI PROVIDERS (17 Nov 2026)

**JARVIS MUST USE ONLY CLOUD DEEPSEEK OR KIMI (MOONSHOT) MODELS VIA THEIR OFFICIAL APIs FOR ANY AI INFERENCE.**

- **Never add or execute a local AI model** on the AKAI TV, a PC, Termux, an edge box or any fallback compute node. The TV is Android 9/API28, ARMv7, ~1.5 GB RAM, unsuitable for LLM inference.
- **No third-party model/API providers**, model routers, on-device LLM, Ollama, LM Studio, ONNX LLM, quantized fallback, multi-provider proxy or paid AI service other than the owner-selected DeepSeek/Kimi provider.
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

## CURRENT ENTRYPOINTS

- Final-release contract: `docs/JARVIS_FINAL_AGENT_OTA_RELEASE_CONTRACT.md`
- GitHub tracking issue: #17
- Draft implementation PR: #18, stacked on A2 PR #16; A2 preparatory PRs #10, #12, #13, #14, #15.
- AI core: `akai-remote-tv/app/src/main/java/it/akai/customremote/ai/`
- Android activity: `akai-remote-tv/app/src/main/java/it/akai/customremote/LocalVisualCaptureActivity.java`
- CI: `.github/workflows/ci.yml` and host mock suite.
