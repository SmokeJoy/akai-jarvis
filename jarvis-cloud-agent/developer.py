#!/usr/bin/env python3
"""Isolated JARVIS cloud developer: a proposal generator, never a deployer.
One manual task -> one constrained Java target -> one draft review PR.
"""
from __future__ import annotations
import argparse
import json
import os
import re
from pathlib import Path, PurePosixPath
import sys
import urllib.error
import urllib.request

ALLOWED_ROOTS = (
    "akai-remote-tv/app/src/main/java/it/akai/customremote/ai/",
)
# Drafts may add isolated AI skills but cannot rewrite the operating core,
# memory, provider security, launcher, server, or host tests.
PROTECTED_AI_FILES = frozenset({
    "AiProviderAdapter.java", "AkaiAiController.java", "AkaiMemoryEngine.java",
    "LocalIntentParser.java", "ScreenPerceptionEngine.java",
    "KeystoreSecurityHelper.java", "AkaiSpeechEngine.java",
    "AgentFactMemory.java", "AgentSkillGate.java",
})
MAX_SOURCE_CHARS = 35000
MAX_OUTPUT_CHARS = 50000
MAX_RESPONSE_BYTES = 250_000
API_ENDPOINTS = {
    "deepseek": "https://api.deepseek.com/chat/completions",
    "kimi": "https://api.moonshot.ai/v1/chat/completions",
}


class DeveloperError(Exception):
    pass


def target_path(root: Path, raw: str) -> Path:
    """Validate lexical and filesystem containment; prohibit symlinks."""
    if not raw or "\\" in raw or "\x00" in raw or raw.startswith("/"):
        raise DeveloperError("Invalid path")
    posix = PurePosixPath(raw)
    if any(part in (".", "..") for part in raw.split("/")) or posix.is_absolute():
        raise DeveloperError("Path traversal is forbidden")
    if not raw.endswith(".java") or not any(raw.startswith(x) for x in ALLOWED_ROOTS):
        raise DeveloperError("Only isolated AI Java skill sources can be proposed")
    if posix.name in PROTECTED_AI_FILES:
        raise DeveloperError("Core AI, memory, API and safety files require direct human development")
    if posix.parent.as_posix() != ALLOWED_ROOTS[0].rstrip("/"):
        raise DeveloperError("Nested Java source paths are outside the draft-skill sandbox")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*[.]java", posix.name):
        raise DeveloperError("Malformed Java source filename")
    parent = root.resolve()
    path = parent.joinpath(*posix.parts)
    if not path.resolve(strict=False).is_relative_to(parent):
        raise DeveloperError("Path escapes repository")
    if path.is_symlink():
        raise DeveloperError("Symlink not allowed")
    if path.exists() and not path.is_file():
        raise DeveloperError("Not a regular file")
    return path


def extract_json(text: str) -> dict:
    cleaned = text.strip()
    fence = chr(96) * 3
    if cleaned.startswith(fence + "json"):
        cleaned = cleaned[7:]
    elif cleaned.startswith(fence):
        cleaned = cleaned[3:]
    if cleaned.endswith(fence):
        cleaned = cleaned[:-3]
    try:
        obj = json.loads(cleaned.strip())
    except (ValueError, TypeError) as exc:
        raise DeveloperError("Provider output is not a JSON object") from exc
    if not isinstance(obj, dict):
        raise DeveloperError("Provider output must be a JSON object")
    return obj


def validate_change(obj: dict, target: str) -> str:
    changes = obj.get("changes")
    if not isinstance(changes, list) or len(changes) != 1:
        raise DeveloperError("Exactly one file change is required")
    change = changes[0]
    if not isinstance(change, dict) or change.get("path") != target:
        raise DeveloperError("Provider attempted to edit a different file")
    content = change.get("content")
    if not isinstance(content, str) or not content.strip() or len(content) > MAX_OUTPUT_CHARS:
        raise DeveloperError("Replacement file is empty or too large")
    if "\x00" in content:
        raise DeveloperError("Binary content is forbidden")
    # This is structural validation, NOT a guarantee of safe Java.
    # The resulting code must be reviewed and tested before merge.
    package = re.findall(r"(?m)^\s*package\s+([\w.]+)\s*;", content)
    if package != ["it.akai.customremote.ai"]:
        raise DeveloperError("Generated Java package declaration mismatch")
    classname = PurePosixPath(target).stem
    if not re.search(r"\bclass\s+" + re.escape(classname) + r"\b", content):
        raise DeveloperError("Declared Java class does not match target basename")
    return content


def call_provider(provider: str, task: str, target: str, current: str, *, approved: bool = False) -> dict:
    if not approved:
        raise DeveloperError("Paid API request requires explicit per-run owner approval; zero calls made")
    if provider not in API_ENDPOINTS:
        raise DeveloperError("Provider must be deepseek or kimi")
    key_name = "DEEPSEEK_API_KEY" if provider == "deepseek" else "MOONSHOT_API_KEY"
    key = os.environ.get(key_name, "")
    if not key:
        raise DeveloperError(f"{key_name} is not configured; zero paid calls made")
    model = "deepseek-flash" if provider == "deepseek" else os.environ.get("MOONSHOT_MODEL", "")
    if not model:
        raise DeveloperError("MOONSHOT_MODEL must be set to a valid API model ID")
    system = (
        "You are a constrained Java coding agent for an Android 9 TV assistant. "
        "Return a SINGLE valid JSON object with keys summary and changes. "
        "changes is a one-item array: {path: the exact given target, content: COMPLETE UTF-8 file}. "
        "Never modify the remote control, Android launcher, OS, security settings, "
        "other files, or package installation. Prefer small minimal changes; "
        "do not include markdown fences or code execution directives."
    )
    user = json.dumps({"task": task, "target": target, "current_file_content": current}, ensure_ascii=False)
    payload = {
        "model": model,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "max_tokens": 8192,
        "temperature": 0.1,
        "stream": False,
    }
    if provider == "deepseek":
        payload["thinking"] = {"type": "disabled"}
        payload["response_format"] = {"type": "json_object"}
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        API_ENDPOINTS[provider], data=data, method="POST",
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=75) as response:
            result = response.read(MAX_RESPONSE_BYTES + 1)
    except urllib.error.HTTPError as exc:
        raise DeveloperError(f"Provider HTTP {exc.code}; request aborted") from exc
    except (OSError, TimeoutError) as exc:
        raise DeveloperError("Provider network error or timeout") from exc
    if len(result) > MAX_RESPONSE_BYTES:
        raise DeveloperError("Provider response exceeded limit")
    try:
        parsed = json.loads(result.decode("utf-8"))
        message = parsed["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError) as exc:
        raise DeveloperError("Invalid provider response schema") from exc
    return extract_json(message)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--task", required=True)
    parser.add_argument("--provider", choices=sorted(API_ENDPOINTS), default="deepseek")
    parser.add_argument("--target", required=True, help="One exact AI Java file; all other files are protected")
    parser.add_argument("--root", default=".")
    parser.add_argument("--mock-json", help="Unit-test only. Workflow never passes this argument.")
    parser.add_argument("--approve-paid-api", action="store_true",
                        help="Owner explicitly authorizes ONE potentially billable provider request")
    args = parser.parse_args(argv)
    try:
        if not args.task.strip() or len(args.task) > 1800:
            raise DeveloperError("Task is empty or exceeds 1800 chars")
        root = Path(args.root).resolve()
        if not root.is_dir():
            raise DeveloperError("Repository directory missing")
        path = target_path(root, args.target)
        old = path.read_text(encoding="utf-8") if path.exists() else ""
        if len(old) > MAX_SOURCE_CHARS:
            raise DeveloperError("Target file too large for bounded context; split scope")
        if args.mock_json:
            proposal = extract_json(Path(args.mock_json).read_text(encoding="utf-8"))
        else:
            proposal = call_provider(args.provider, args.task, args.target, old, approved=args.approve_paid_api)
        replacement = validate_change(proposal, args.target)
        if replacement == old:
            raise DeveloperError("No meaningful file changes")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(replacement, encoding="utf-8")
        print(json.dumps({
            "status": "PROPOSAL_WRITTEN", "path": args.target,
            "summary": str(proposal.get("summary", ""))[:200],
        }, ensure_ascii=False))
        return 0
    except DeveloperError as exc:
        print(f"AGENT_BLOCKED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
