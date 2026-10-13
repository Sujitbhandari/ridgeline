{{/* Name of the service. Used as app.kubernetes.io/name, the Service name,
     the ServiceAccount name and OTEL_SERVICE_NAME, so all four always agree. */}}
{{- define "ps.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ps.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ps.name" . }}
{{- end -}}

{{- define "ps.labels" -}}
{{ include "ps.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: ridgeline
ridgeline.dev/team: {{ required "team is required: who gets paged for this service?" .Values.team }}
ridgeline.dev/environment: {{ .Values.environment }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Resource presets. Requests are what the scheduler packs on; the memory
     limit equals the request on purpose for small (Guaranteed memory), and
     there is no CPU limit unless cpuLimit is set explicitly. */}}
{{- define "ps.resources" -}}
{{- $presets := dict
  "small"  (dict "cpu" "100m" "memory" "128Mi" "memLimit" "256Mi")
  "medium" (dict "cpu" "250m" "memory" "256Mi" "memLimit" "512Mi")
  "large"  (dict "cpu" "500m" "memory" "512Mi" "memLimit" "1Gi")
-}}
{{- if eq .Values.size "custom" -}}
{{- if not .Values.resources.requests -}}
{{- fail "size: custom requires resources.requests" -}}
{{- end -}}
{{ toYaml .Values.resources }}
{{- else -}}
{{- $p := get $presets .Values.size -}}
requests:
  cpu: {{ $p.cpu }}
  memory: {{ $p.memory }}
limits:
  memory: {{ $p.memLimit }}
  {{- with .Values.cpuLimit }}
  cpu: {{ . }}
  {{- end }}
{{- end -}}
{{- end -}}

{{- define "ps.irsaRoleArn" -}}
{{- printf "arn:aws:iam::%s:role/%s-%s-%s" .Values.aws.accountId .Values.environment .Release.Namespace (include "ps.name" .) -}}
{{- end -}}

{{/* The pod template is shared by the Deployment and the Argo Rollout. */}}
{{- define "ps.podTemplate" -}}
metadata:
  labels:
    {{- include "ps.labels" . | nindent 4 }}
  annotations:
    # Restart pods when non-secret config changes.
    checksum/env: {{ toYaml .Values.env | sha256sum | trunc 16 }}
spec:
  serviceAccountName: {{ include "ps.name" . }}
  # IRSA injects its own projected token; the API token is never needed.
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: {{ .Values.shutdown.terminationGracePeriodSeconds }}
  {{- with .Values.scheduling.priorityClassName }}
  priorityClassName: {{ . }}
  {{- end }}
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  {{- if or .Values.scheduling.spreadAcrossZones .Values.scheduling.spreadAcrossNodes }}
  topologySpreadConstraints:
    {{- if .Values.scheduling.spreadAcrossZones }}
    - maxSkew: 1
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          {{- include "ps.selectorLabels" . | nindent 10 }}
      matchLabelKeys: [pod-template-hash]
    {{- end }}
    {{- if .Values.scheduling.spreadAcrossNodes }}
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels:
          {{- include "ps.selectorLabels" . | nindent 10 }}
      matchLabelKeys: [pod-template-hash]
    {{- end }}
  {{- end }}
  {{- with .Values.scheduling.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with .Values.scheduling.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  containers:
    - name: app
      image: "{{ required "image.repository is required" .Values.image.repository }}:{{ required "image.tag is required" .Values.image.tag }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - name: http
          containerPort: {{ .Values.port }}
          protocol: TCP
      env:
        - name: OTEL_SERVICE_NAME
          value: {{ include "ps.name" . }}
        - name: ENVIRONMENT
          value: {{ .Values.environment }}
        - name: HOST_IP
          valueFrom: { fieldRef: { fieldPath: status.hostIP } }
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://$(HOST_IP):{{ .Values.observability.otlpPort }}"
        - name: OTEL_EXPORTER_OTLP_INSECURE
          value: "true"
        - name: POD_NAME
          valueFrom: { fieldRef: { fieldPath: metadata.name } }
        - name: POD_NAMESPACE
          valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
        - name: NODE_NAME
          valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
        {{- range $k, $v := .Values.env }}
        - name: {{ $k }}
          value: {{ $v | quote }}
        {{- end }}
      {{- with .Values.secretEnvFrom }}
      envFrom:
        {{- range . }}
        - secretRef:
            name: {{ . }}
        {{- end }}
      {{- end }}
      resources:
        {{- include "ps.resources" . | nindent 8 }}
      startupProbe:
        httpGet: { path: {{ .Values.probes.livenessPath }}, port: http }
        periodSeconds: 2
        failureThreshold: {{ div .Values.probes.startupTimeoutSeconds 2 }}
      livenessProbe:
        httpGet: { path: {{ .Values.probes.livenessPath }}, port: http }
        periodSeconds: 10
        timeoutSeconds: 2
        failureThreshold: 3
      readinessProbe:
        httpGet: { path: {{ .Values.probes.readinessPath }}, port: http }
        periodSeconds: 5
        timeoutSeconds: 2
        failureThreshold: 2
      {{- if gt (int .Values.shutdown.preStopSleepSeconds) 0 }}
      lifecycle:
        preStop:
          sleep:
            seconds: {{ .Values.shutdown.preStopSleepSeconds }}
      {{- end }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: [ALL]
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir:
        sizeLimit: 64Mi
{{- end -}}
