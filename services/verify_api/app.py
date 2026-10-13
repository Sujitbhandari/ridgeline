"""verify-api: the public-facing identity verification endpoint.

Flow: client sends a phone number + consent -> we pseudonymize it at the edge
(the raw number never leaves this process, never hits a log or a span) ->
ask risk-scorer for a score -> return an approve / review / deny decision.

Calls to risk-scorer go through a bounded connection pool. Pool size times
replica count is a number someone has to own (Lab 03).
"""

from __future__ import annotations

import asyncio
import uuid
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from pydantic import BaseModel, Field

from ridgeline_common import chaos, lifecycle, telemetry
from ridgeline_common import logging as rlog
from ridgeline_common.redaction import mask_phone, pseudonymize
from ridgeline_common.settings import Settings

settings = Settings()
log = rlog.configure(settings.service_name, settings.log_level)
tracer = trace.get_tracer("verify-api")
life = lifecycle.Lifecycle(settings)
UPSTREAM = "risk-scorer"


class VerifyRequest(BaseModel):
    phone_number: str = Field(min_length=7, max_length=20)
    consent: bool
    channel: str = Field(default="mobile", pattern="^(mobile|web|api)$")


class VerifyResponse(BaseModel):
    verification_id: str
    decision: str
    risk_band: str
    phone_hint: str


class _State:
    client: httpx.AsyncClient | None = None
    pool: asyncio.Semaphore | None = None


state = _State()


@asynccontextmanager
async def lifespan(_: FastAPI):
    size = settings.upstream_pool_size
    state.pool = asyncio.Semaphore(size)
    state.client = httpx.AsyncClient(
        base_url=settings.risk_scorer_url,
        timeout=settings.upstream_timeout_s,
        limits=httpx.Limits(max_connections=size, max_keepalive_connections=size),
    )
    telemetry.UPSTREAM_POOL_SIZE.labels(settings.service_name, UPSTREAM).set(size)
    await life.startup()
    log.info("started", extra={"fields": {"upstream_pool_size": size, "environment": settings.environment}})
    yield
    await life.shutdown()
    await state.client.aclose()


app = FastAPI(title="verify-api", lifespan=lifespan)
telemetry.instrument(app, settings)
life.register(app)


def _decision(band: str) -> str:
    return {"low": "approve", "medium": "review"}.get(band, "deny")


@app.post("/v1/verify", response_model=VerifyResponse)
async def verify(req: VerifyRequest) -> VerifyResponse:
    if not req.consent:
        raise HTTPException(status_code=422, detail="consent is required")
    verification_id = str(uuid.uuid4())
    token = pseudonymize(req.phone_number, settings.pseudonym_salt)

    span = trace.get_current_span()
    span.set_attribute("verification.id", verification_id)
    span.set_attribute("verification.channel", req.channel)  # never the number itself

    await chaos.apply(settings)

    assert state.pool is not None and state.client is not None
    pool_gauge = telemetry.UPSTREAM_POOL_IN_USE.labels(settings.service_name, UPSTREAM)
    async with state.pool:
        pool_gauge.inc()
        try:
            with tracer.start_as_current_span("risk-scorer.score"):
                resp = await state.client.post("/v1/score", json={"subject_token": token, "channel": req.channel})
        except httpx.HTTPError as exc:
            log.error("risk-scorer unreachable", extra={"fields": {"error": type(exc).__name__}})
            raise HTTPException(status_code=503, detail="risk scoring unavailable") from exc
        finally:
            pool_gauge.dec()

    if resp.status_code == 503:
        telemetry.UPSTREAM_REJECTIONS.labels(settings.service_name, UPSTREAM).inc()
        raise HTTPException(status_code=503, detail="risk scoring saturated")
    resp.raise_for_status()
    band = resp.json()["band"]
    hint = mask_phone(req.phone_number)

    log.info(
        "verification complete",
        extra={"fields": {"verification_id": verification_id, "band": band, "phone_hint": hint}},
    )
    return VerifyResponse(
        verification_id=verification_id,
        decision=_decision(band),
        risk_band=band,
        phone_hint=hint,
    )
