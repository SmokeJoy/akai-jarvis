# AGENTS.md — AKAI JARVIS (owner invariants)

> Canonical developer instructions for all agents, coding assistants, GitHub automations and reviewers contributing to this branch. Explicit owner decisions take precedence over historical PR comments.

## HARD RULE — AI PROVIDERS (17 Nov 2026)

**JARVIS MUST USE ONLY CLOUD DEEPSEEK OR KIMI (MOONSHOT) MODELS VIA THEIR OFFICIAL APIs FOR ANY AI INFERENCE.**

- **Never add or execute a local AI model** on the AKAI TV, a PC, Termux, an edge box or any fallback compute node. The TV is Android 9/API28, ARMv7, ~1.5 GB RAM, unsuitable for LLM inference.
- **No third-party model/API providers**, model routers, on-device LLM, Ollama, LM Studio, ONNX LLM, quantized fallback, multi-provider proxy or paid AI service other than the owner-selected DeepSeek/Kimi provider.
- Explicitly distinguish local **deterministic software** (buttons, Accessibility, package inventory, parsed commands, SQLite, rule-based UI guards, orchestration) from a local **AI model** (forbidden). The historical `LOCAL_ONLY` label means "cloud disabled, deterministic operations only" and MUST NOT implement or promise local inference.
- If DeepSeek/Kimi is unavailable, unconfigured, unauthorized or out of budget, fail closed for AI reasoning. Existing deterministic TV remote controls may continue.
- Verify the active provider and request destination with `CloudProviderPolicy`. API keys are provider-specific, kept in Android Keystore; no cross-provider redirects, no public credentials and no API charges without owner consent.
- Cloud screenshot inference (if any) requires separate per-image consent after Android MediaProjection approval, no sensitive UI, bounded JPEG/timeout/budget, and must not execute unverified AI text as actions.

## RELEASE AND HARDWARE FREEZE

- The owner has installed A2 preview `it.akai.customremote` versionCode 3 (17 Nov 2026). It is being tested separately.
- **No intermediate installs/upgrades/ADB write/root/reset/deploy/merge** until one final full agent release, barring a distinct, explicitly owner-approved emergency.
- Keep existing Launcher Home v8, Web Remote LAN, HTTPS TLS Root CA, native uinput, Android signing and SQLite memory intact.
- Build/test code on draft branches and PRs; GitHub Actions CI artifacts use ephemeral test signing/TLS and MUST NOT be installed on the TV.
- The real TV is not a CI runner. Report host/mock tests, Android APK build, remote API mock and real hardware evidence separately.
- Update memory and issue only with verified substantive results, SHA, CI state and remaining blocker; avoid reviews in comment loops.
- No promises of fully autonomous vision until visual fallback feeds the planner and goal verifier with verified evidence; MediaProjection cannot reliably capture DRM-protected apps.
- Release OTA is optional and must require owner confirmation, signed manifest, exact APK SHA/signing cert checks and a verified rollback path; private GitHub is not a secret-free OTA endpoint.

## CURRENT ENTRYPOINTS

- Final-release contract: `docs/JARVIS_FINAL_AGENT_OTA_RELEASE_CONTRACT.md`
- GitHub tracking issue: #17
- Draft implementation PR: #18, stacked on A2 PR #16; A2 preparatory PRs #10, #12, #13, #14, #15.
- AI core: `akai-remote-tv/app/src/main/java/it/akai/customremote/ai/`
- Android activity: `akai-remote-tv/app/src/main/java/it/akai/customremote/LocalVisualCaptureActivity.java`
- CI: `.github/workflows/ci.yml` and host mock suite.
