"""OpenTelemetry tracing + Prometheus RED metrics, wired the same way in every service.

Developers should not have to think about instrumentation. They call
``instrument(app, settings)`` and get:
  * W3C trace-context propagation across HTTP hops
  * spans exported over OTLP to the node-local collector
  * RED metrics (rate, errors, duration) plus an in-flight gauge that the
    autoscaler uses as a custom scaling signal
"""

from __future__ import annotations

import os
import time

from fastapi import FastAPI, Request, Response
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

from .settings import Settings

# Buckets chosen around a 300ms latency SLO so the SLO threshold is a bucket edge.
_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 2.5, 5.0)

REQUESTS = Counter("http_requests_total", "HTTP requests", ["service", "route", "method", "code"])
LATENCY = Histogram("http_request_duration_seconds", "HTTP latency", ["service", "route", "method"], buckets=_BUCKETS)
INFLIGHT = Gauge("http_inflight_requests", "Requests currently being served", ["service"])
UPSTREAM_POOL_IN_USE = Gauge("upstream_pool_in_use", "Upstream connections checked out", ["service", "upstream"])
UPSTREAM_POOL_SIZE = Gauge("upstream_pool_size", "Upstream pool capacity", ["service", "upstream"])
UPSTREAM_REJECTIONS = Counter("upstream_rejections_total", "Upstream refused the connection", ["service", "upstream"])

DATASTORE_ACTIVE = Gauge("datastore_active_connections", "Simulated datastore connections in use", ["service"])
DATASTORE_LIMIT = Gauge("datastore_max_connections", "Simulated datastore connection ceiling", ["service"])

_SKIP = {"/metrics", "/healthz", "/readyz"}


def _setup_tracing(settings: Settings) -> None:
    resource = Resource.create(
        {
            "service.name": settings.service_name,
            "deployment.environment": settings.environment,
            # Populated by the Helm chart via the downward API:
            "k8s.pod.name": os.getenv("POD_NAME", ""),
            "k8s.node.name": os.getenv("NODE_NAME", ""),
            "k8s.namespace.name": os.getenv("POD_NAMESPACE", ""),
        }
    )
    provider = TracerProvider(resource=resource)
    if os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
        provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(provider)


def instrument(app: FastAPI, settings: Settings) -> None:
    _setup_tracing(settings)
    FastAPIInstrumentor.instrument_app(app, excluded_urls="healthz,readyz,metrics")
    HTTPXClientInstrumentor().instrument()
    svc = settings.service_name

    @app.middleware("http")
    async def red_metrics(request: Request, call_next):  # noqa: ANN001
        path = request.url.path
        if path in _SKIP:
            return await call_next(request)
        route = getattr(request.scope.get("route"), "path", path)
        INFLIGHT.labels(svc).inc()
        start = time.perf_counter()
        code = "500"
        try:
            response = await call_next(request)
            code = str(response.status_code)
            # Re-read the route: it is resolved during call_next.
            route = getattr(request.scope.get("route"), "path", route)
            return response
        finally:
            INFLIGHT.labels(svc).dec()
            LATENCY.labels(svc, route, request.method).observe(time.perf_counter() - start)
            REQUESTS.labels(svc, route, request.method, code).inc()

    @app.get("/metrics", include_in_schema=False)
    def metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
