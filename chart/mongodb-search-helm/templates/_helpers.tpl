{{- define "mongodb-search-helm.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.operator.version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- /* The one CSV the approver approves and the gate waits for: <package>.v<version>. */ -}}
{{- define "mongodb-search-helm.csv" -}}
{{ printf "%s.v%s" .Values.operator.package .Values.operator.version }}
{{- end -}}

{{- /* Prefix for the chart's own objects (Jobs and their RBAC, the OperatorGroup). */ -}}
{{- define "mongodb-search-helm.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{ .Release.Name | trunc 50 | trimSuffix "-" }}
{{- else -}}
{{ printf "%s-%s" .Release.Name .Chart.Name | trunc 50 | trimSuffix "-" }}
{{- end -}}
{{- end -}}

{{- /*
The names the operator derives from the MongoDBSearch's name. The chart does not choose them; it repeats the
operator's convention (cluster index 0) so the preflight, the gate, the Route and the monitors agree with it.
*/ -}}
{{- define "mongodb-search-helm.mongotCertSecret" -}}
{{ printf "%s-%s-search-cert" .Values.tls.certsSecretPrefix .Values.search.name }}
{{- end -}}
{{- define "mongodb-search-helm.lbCertSecret" -}}
{{ printf "%s-%s-search-lb-0-cert" .Values.tls.certsSecretPrefix .Values.search.name }}
{{- end -}}
{{- define "mongodb-search-helm.lbClientCertSecret" -}}
{{ printf "%s-%s-search-lb-0-client-cert" .Values.tls.certsSecretPrefix .Values.search.name }}
{{- end -}}
{{- define "mongodb-search-helm.mongotStatefulSet" -}}
{{ printf "%s-search-0" .Values.search.name }}
{{- end -}}
{{- define "mongodb-search-helm.mongotService" -}}
{{ printf "%s-search-0-svc" .Values.search.name }}
{{- end -}}
{{- define "mongodb-search-helm.lbDeployment" -}}
{{ printf "%s-search-lb-0" .Values.search.name }}
{{- end -}}
{{- define "mongodb-search-helm.proxyService" -}}
{{ printf "%s-search-0-proxy-svc" .Values.search.name }}
{{- end -}}
{{- define "mongodb-search-helm.envoyStatsService" -}}
{{ printf "%s-envoy-stats" .Values.search.name }}
{{- end -}}

{{- /* The pod spec shared by the Jobs: restricted-v2 compliant, a shell and oc. */ -}}
{{- define "mongodb-search-helm.jobPod" -}}
restartPolicy: Never
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{- define "mongodb-search-helm.jobContainer" -}}
image: "{{ .Values.jobs.image.repository }}:{{ .Values.jobs.image.tag }}"
resources:
  {{- toYaml .Values.jobs.resources | nindent 2 }}
securityContext:
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
command: ["/bin/bash", "-c"]
{{- end -}}
