# One image definition for every Python service on the platform.
#   docker build --build-arg APP=verify_api -t ridgeline/verify-api:dev .
# Runs as a non-root UID with a read-only root filesystem, so it passes the
# restricted Pod Security Standard and the Kyverno policies in /policies.

FROM python:3.12-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
ARG APP
ENV APP_MODULE=${APP}.app:app \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
COPY --from=build /install /usr/local
WORKDIR /app
COPY ridgeline_common ./ridgeline_common
COPY ${APP} ./${APP}
USER 10001:10001
EXPOSE 8080
# --timeout-graceful-shutdown must stay below the pod's terminationGracePeriodSeconds
# minus the preStop sleep, or Kubernetes SIGKILLs in-flight requests.
CMD ["sh", "-c", "exec uvicorn ${APP_MODULE} --host 0.0.0.0 --port 8080 --timeout-graceful-shutdown 15 --no-access-log"]
