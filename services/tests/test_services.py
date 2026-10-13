import importlib

import httpx
import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def scorer(monkeypatch):
    monkeypatch.setenv("OTEL_SERVICE_NAME", "risk-scorer")
    monkeypatch.setenv("MAX_ACTIVE_CONNECTIONS", "2")
    import risk_scorer.app as mod

    mod = importlib.reload(mod)
    with TestClient(mod.app) as client:
        yield mod, client


@pytest.fixture()
def verifier(monkeypatch, scorer):
    """verify-api wired to an in-process risk-scorer, no network."""
    scorer_mod, _ = scorer
    monkeypatch.setenv("OTEL_SERVICE_NAME", "verify-api")
    import verify_api.app as mod

    mod = importlib.reload(mod)
    with TestClient(mod.app) as client:
        mod.state.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=scorer_mod.app), base_url="http://risk-scorer"
        )
        yield mod, client


def test_probes(scorer):
    _, client = scorer
    assert client.get("/healthz").status_code == 200
    assert client.get("/readyz").json() == {"status": "ready"}


def test_score_is_deterministic(scorer):
    _, client = scorer
    body = {"subject_token": "a" * 32, "channel": "mobile"}
    first = client.post("/v1/score", json=body).json()
    assert first == client.post("/v1/score", json=body).json()
    assert first["band"] in {"low", "medium", "high"}


def test_scorer_refuses_past_connection_ceiling(scorer):
    mod, client = scorer
    mod.store.active = mod.store.limit  # simulate a saturated datastore
    resp = client.post("/v1/score", json={"subject_token": "b" * 32})
    assert resp.status_code == 503
    mod.store.active = 0


def test_verify_happy_path_never_echoes_number(verifier):
    _, client = verifier
    resp = client.post("/v1/verify", json={"phone_number": "+1 214 555 0142", "consent": True})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["decision"] in {"approve", "review", "deny"}
    assert body["phone_hint"].endswith("42")
    assert "0142" not in resp.text


def test_verify_requires_consent(verifier):
    _, client = verifier
    resp = client.post("/v1/verify", json={"phone_number": "2145550142", "consent": False})
    assert resp.status_code == 422


def test_metrics_exposed(verifier):
    _, client = verifier
    client.post("/v1/verify", json={"phone_number": "2145550142", "consent": True})
    text = client.get("/metrics").text
    assert 'http_requests_total{code="200",method="POST",route="/v1/verify",service="verify-api"}' in text
    assert "http_inflight_requests" in text
