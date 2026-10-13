"""Health, readiness and graceful shutdown.

Liveness answers "is the process wedged?" and must never depend on anything
outside the process. Readiness answers "should I get traffic right now?".

Shutdown ordering on Kubernetes (the cause of most "502s during deploys"):
  1. Pod is marked Terminating. In parallel, kubelet runs the preStop hook
     AND the endpoint controller starts removing the pod from Services.
  2. The chart's preStop hook sleeps a few seconds, so kube-proxy / ingress
     have time to stop routing new requests here.
  3. Only then does SIGTERM arrive. uvicorn stops accepting connections,
     finishes in-flight requests (--timeout-graceful-shutdown), and runs the
     lifespan shutdown below, which flips readiness off.
Lab 05 reproduces what happens without step 2.
"""

from __future__ import annotations

import asyncio
import time

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from .settings import Settings


class Lifecycle:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.started_at = time.monotonic()
        self.ready = False
        self.draining = False

    async def startup(self) -> None:
        # Simulates warm-up work (loading models, priming caches, migrations).
        if self.settings.startup_delay_s > 0:
            await asyncio.sleep(self.settings.startup_delay_s)
        self.ready = True

    async def shutdown(self) -> None:
        self.draining = True
        self.ready = False

    def register(self, app: FastAPI) -> None:
        @app.get("/healthz", include_in_schema=False)
        def healthz() -> dict:
            return {"status": "ok"}

        @app.get("/readyz", include_in_schema=False)
        def readyz() -> JSONResponse:
            if self.ready and not self.draining:
                return JSONResponse({"status": "ready"})
            reason = "draining" if self.draining else "starting"
            return JSONResponse({"status": reason}, status_code=503)
