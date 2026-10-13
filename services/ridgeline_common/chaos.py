"""Deliberate failure injection used by the labs. Off by default."""

from __future__ import annotations

import asyncio
import random
import time

from fastapi import HTTPException

from .settings import Settings

_LEAK: list[bytes] = []


def burn_cpu(ms: int) -> None:
    """Busy-loop for ``ms`` of wall time. Under a CPU limit this is where
    CFS throttling turns into tail latency (Lab 02)."""
    end = time.perf_counter() + ms / 1000
    x = 0
    while time.perf_counter() < end:
        x += 1


async def apply(settings: Settings) -> None:
    if settings.cpu_burn_ms:
        burn_cpu(settings.cpu_burn_ms)
    if settings.extra_latency_ms:
        await asyncio.sleep(settings.extra_latency_ms / 1000)
    if settings.memory_leak_kb_per_req:
        _LEAK.append(b"x" * 1024 * settings.memory_leak_kb_per_req)
    if settings.error_rate and random.random() < settings.error_rate:
        raise HTTPException(status_code=500, detail="injected failure")
