#!/usr/bin/env python3
"""No cleartext AI-memory or bearer backup in the owner install/rollback script.

Source regression only. Real TLS trust, backup SQLite/WAL and TV rollback require
separate private-owner, real-device verification.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "akai-remote-tests/05_safe_install_and_rollback.ps1"


def require_secure_memory_transport(source: str) -> None:
    url = '$MemoryUrl = "https://$($TargetTv):$HttpsPort/api/ai/memory"'
    if source.count(url) != 1:
        raise ValueError("memory backup endpoint must be exactly HTTPS/8443")
    calls = re.findall(r"(?m)^\s*\$memResp = Invoke-RestMethod -Uri \$MemoryUrl\b", source)
    if len(calls) != 2:
        raise ValueError("both memory-backup call sites must use the validated URL")
    for line in source.splitlines():
        code = line.split("#", 1)[0].strip()
        if not code or code.startswith("#"):
            continue
        if re.search(r"(?i)(?:-SkipCertificateCheck|ServerCertificateValidationCallback|http://[^'\"\s]*/api/ai/memory)", code):
            raise ValueError("cleartext memory or disabled TLS verification in installer")
    if 'if ($AuthToken) { $headers["Authorization"] = "Bearer $AuthToken" }' not in source:
        raise ValueError("memory REST token path changed: requires manual audit")


class BackupMemoryTransportTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text(encoding="utf-8-sig")

    def test_memory_url_secure_and_calls_bounded(self):
        require_secure_memory_transport(self.source)

    def test_rejects_legacy_http_memory_route(self):
        modified = self.source.replace(
            '$MemoryUrl = "https://$($TargetTv):$HttpsPort/api/ai/memory"',
            '$MemoryUrl = "http://$($TargetTv):$HttpPort/api/ai/memory"')
        self.assertNotEqual(modified, self.source)
        with self.assertRaises(ValueError):
            require_secure_memory_transport(modified)

    def test_rejects_skip_certificate_verification(self):
        modified = self.source.replace(
            "Invoke-RestMethod -Uri $MemoryUrl -Method Get",
            "Invoke-RestMethod -Uri $MemoryUrl -SkipCertificateCheck -Method Get")
        self.assertNotEqual(modified, self.source)
        with self.assertRaises(ValueError):
            require_secure_memory_transport(modified)


if __name__ == "__main__":
    unittest.main()
