"""PII redaction for logs and span attributes.

Identity platforms handle phone numbers, emails and national IDs. None of that
should ever reach a log line or a trace attribute, in any environment. This
module is the single place that rule lives, so every service gets it for free.
"""

from __future__ import annotations

import hashlib
import re

# E.164 and common North American formats: +1 214 555 0142, (214) 555-0142, 2145550142
_PHONE = re.compile(r"(?<!\w)(\+?\d{1,3}[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}(?!\w)")
_EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")
_SSN = re.compile(r"(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)")

PATTERNS: dict[str, re.Pattern[str]] = {"ssn": _SSN, "email": _EMAIL, "phone": _PHONE}


def redact(text: str) -> str:
    """Replace every PII match with a typed placeholder, e.g. ``[REDACTED:phone]``."""
    for kind, pattern in PATTERNS.items():
        text = pattern.sub(f"[REDACTED:{kind}]", text)
    return text


def mask_phone(phone: str) -> str:
    """Keep only the last two digits so support can still correlate a ticket."""
    digits = re.sub(r"\D", "", phone)
    if len(digits) < 4:
        return "**"
    return "*" * (len(digits) - 2) + digits[-2:]


def pseudonymize(value: str, salt: str) -> str:
    """Stable, non-reversible token for joining records without exposing the value.

    The salt is per-environment (injected from a Kubernetes Secret), so a token
    from staging can never be matched against production data.
    """
    return hashlib.sha256(f"{salt}:{value}".encode()).hexdigest()[:32]
