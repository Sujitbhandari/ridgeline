"""risk-scorer: returns a fraud-risk score for a pseudonymized phone token.

It sits in front of a (simulated) shared datastore with a hard connection
ceiling, MAX_ACTIVE_CONNECTIONS, the way a Postgres primary has
max_connections. When callers exceed it, requests are refused with 503,
which is exactly what a real database does to a fleet that scaled out
without anyone recomputing pool sizes (Lab 03).
"""

from __future__ import annotations

import asyncio
import hashlib
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from pydantic import BaseModel, Field

from ridgeline_common import chaos, lifecycle, telemetry
from ridgeline_common import logging as rlog
from ridgeline_common.settings import Settings

settings = Settings()
log = rlog.configure(settings.service_name, settings.log_level)
tracer = trace.get_tracer("risk-scorer")
life = lifecycle.Lifecycle(settings)

ACTIVE = telemetry.DATASTORE_ACTIVE
LIMIT = telemetry.DATASTORE_LIMIT


class ScoreRequest(BaseModel):
    subject_token: str = Field(min_length=16, max_length=64, description="pseudonymized phone, never the raw number")
    channel: str = Field(default="mobile", pattern="^(mobile|web|api)$")


class ScoreResponse(BaseModel):
    score: float
    band: str


class _Datastore:
    """Counts concurrent 'connections' and refuses past the ceiling."""

    def __init__(self, limit: int) -> None:
        self.limit = limit
        self.active = 0
        self._lock = asyncio.Lock()

    async def acquire(self) -> bool:
        async with self._lock:
            if self.active >= self.limit:
                return False
            self.active += 1
            ACTIVE.labels(settings.service_name).set(self.active)
            return True

    async def release(self) -> None:
        async with self._lock:
            self.active -= 1
            ACTIVE.labels(settings.service_name).set(self.active)


store = _Datastore(settings.max_active_connections)


@asynccontextmanager
async def lifespan(_: FastAPI):
    LIMIT.labels(settings.service_name).set(settings.max_active_connections)
    await life.startup()
    log.info("started", extra={"fields": {"max_active_connections": settings.max_active_connections}})
    yield
    await life.shutdown()
    log.info("shutting down")


app = FastAPI(title="risk-scorer", lifespan=lifespan)
telemetry.instrument(app, settings)
life.register(app)


def _score(token: str, channel: str) -> float:
    digest = hashlib.sha256(f"{token}:{channel}".encode()).digest()
    return round(int.from_bytes(digest[:2], "big") / 65535, 4)


@app.post("/v1/score", response_model=ScoreResponse)
async def score(req: ScoreRequest) -> ScoreResponse:
    if not await store.acquire():
        log.warning("datastore connection refused", extra={"fields": {"active": store.active}})
        raise HTTPException(status_code=503, detail="too many connections")
    try:
        with tracer.start_as_current_span("datastore.query") as span:
            span.set_attribute("db.system", "simulated")
            span.set_attribute("db.connections.active", store.active)
            await asyncio.sleep(0.02)  # a realistic indexed read
            await chaos.apply(settings)
            value = _score(req.subject_token, req.channel)
    finally:
        await store.release()
    band = "high" if value > 0.85 else "medium" if value > 0.5 else "low"
    return ScoreResponse(score=value, band=band)
