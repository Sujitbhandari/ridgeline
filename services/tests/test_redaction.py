import json
import logging

from ridgeline_common.logging import JsonFormatter
from ridgeline_common.redaction import mask_phone, pseudonymize, redact


def test_redacts_phone_formats():
    for raw in ["+1 214 555 0142", "(214) 555-0142", "2145550142", "214.555.0142"]:
        out = redact(f"user {raw} failed otp")
        assert "0142" not in out, raw
        assert "[REDACTED:phone]" in out


def test_redacts_email_and_ssn():
    out = redact("contact jane.doe+x@example.com ssn 123-45-6789")
    assert "example.com" not in out
    assert "6789" not in out


def test_mask_phone_keeps_last_two():
    assert mask_phone("+1 (214) 555-0142") == "*********42"


def test_pseudonym_is_stable_and_env_scoped():
    a = pseudonymize("2145550142", "staging")
    assert a == pseudonymize("2145550142", "staging")
    assert a != pseudonymize("2145550142", "prod")
    assert "2145550142" not in a


def test_formatter_never_emits_pii():
    fmt = JsonFormatter("test")
    rec = logging.LogRecord("t", logging.INFO, __file__, 1, "lookup for 214-555-0142", None, None)
    rec.fields = {"email": "a@b.co"}
    line = json.loads(fmt.format(rec))
    assert "0142" not in line["msg"]
    assert line["email"] == "[REDACTED:email]"
