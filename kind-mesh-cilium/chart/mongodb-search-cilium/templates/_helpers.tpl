{{- define "msc.namespace" -}}{{ .Values.namespace | default .Release.Namespace }}{{- end -}}
{{- define "msc.fullname" -}}{{ printf "%s-%s" .Release.Name .Chart.Name | trunc 50 | trimSuffix "-" }}{{- end -}}
{{- define "msc.csv" -}}{{ printf "%s.v%s" .Values.operator.package .Values.operator.version }}{{- end -}}
{{- define "msc.endpoint" -}}{{ printf "%s.%s.svc.cluster.local:27028" .Values.globalService.name (include "msc.namespace" .) }}{{- end -}}
{{- define "msc.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}
{{- /* Refuses settings that cannot work, at render time: a release that renders is one that can run. */ -}}
{{- define "msc.validate" -}}
{{- if not .Values.source.hostAndPorts }}{{ fail "source.hostAndPorts is empty: list every member of the replica set" }}{{ end }}
{{- if and .Values.globalService.lbL7.enabled .Values.searchTLS.enabled }}{{ fail "globalService.lbL7 and searchTLS cannot both be on: Cilium's L7 load balancer reads cleartext gRPC only" }}{{ end }}
{{- if and (gt (int .Values.search.replicas) 1) (not .Values.globalService.name) }}{{ fail "more than one mongot needs globalService.name: the operator refuses replicas > 1 without a load balancer" }}{{ end }}
{{- end -}}
