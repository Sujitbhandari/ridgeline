"""Runtime settings, read once from the environment.

The failure-injection knobs exist for the labs in /labs. They let you
reproduce real production failure modes (CPU throttling, slow starts,
connection exhaustion, bad releases) on a laptop, on purpose.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field


def _f(name: str, default: float) -> float:
    return float(os.getenv(name, default))


def _i(name: str, default: int) -> int:
    return int(os.getenv(name, default))


@dataclass(frozen=True)
class Settings:
    service_name: str = field(default_factory=lambda: os.getenv("OTEL_SERVICE_NAME", "ridgeline-service"))
    log_level: str = field(default_factory=lambda: os.getenv("LOG_LEVEL", "INFO"))
    environment: str = field(default_factory=lambda: os.getenv("ENVIRONMENT", "lab"))
    pseudonym_salt: str = field(default_factory=lambda: os.getenv("PSEUDONYM_SALT", "lab-only-salt"))

    # verify-api -> risk-scorer
    risk_scorer_url: str = field(default_factory=lambda: os.getenv("RISK_SCORER_URL", "http://risk-scorer:8080"))
    upstream_pool_size: int = field(default_factory=lambda: _i("UPSTREAM_POOL_SIZE", 10))
    upstream_timeout_s: float = field(default_factory=lambda: _f("UPSTREAM_TIMEOUT_S", 2.0))

    # risk-scorer: models a shared datastore with a hard connection ceiling
    # (think Postgres max_connections). Lab 03 is built around this number.
    max_active_connections: int = field(default_factory=lambda: _i("MAX_ACTIVE_CONNECTIONS", 100))

    # Failure injection (all default to "healthy")
    cpu_burn_ms: int = field(default_factory=lambda: _i("CHAOS_CPU_BURN_MS", 0))
    extra_latency_ms: int = field(default_factory=lambda: _i("CHAOS_LATENCY_MS", 0))
    error_rate: float = field(default_factory=lambda: _f("CHAOS_ERROR_RATE", 0.0))
    startup_delay_s: float = field(default_factory=lambda: _f("CHAOS_STARTUP_DELAY_S", 0.0))
    memory_leak_kb_per_req: int = field(default_factory=lambda: _i("CHAOS_LEAK_KB_PER_REQ", 0))
