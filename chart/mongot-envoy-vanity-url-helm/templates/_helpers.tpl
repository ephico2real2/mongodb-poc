{{- define "vanity.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- /* Where every object of the chart goes: the namespace value, or the release's namespace when it is empty. */ -}}
{{- define "vanity.namespace" -}}
{{ .Values.namespace | default .Release.Namespace }}
{{- end -}}

{{- /*
The chart's own names, every one from search.name: <name>-public is the Route or Ingress, and the prefix of the
rest, so that they sit beside the operator's <name>-search-lb-0 and are told from it at a glance.
*/ -}}
{{- define "vanity.public" -}}
{{ printf "%s-public" .Values.search.name }}
{{- end -}}
{{- define "vanity.deployment" -}}
{{ printf "%s-public-lb" .Values.search.name }}
{{- end -}}
{{- define "vanity.configMap" -}}
{{ printf "%s-public-envoy" .Values.search.name }}
{{- end -}}
{{- define "vanity.preflight" -}}
{{ printf "%s-public-preflight" .Values.search.name }}
{{- end -}}
{{- define "vanity.statsService" -}}
{{ printf "%s-public-envoy-stats" .Values.search.name }}
{{- end -}}
{{- define "vanity.exposeName" -}}
{{ .Values.expose.name | default (include "vanity.public" .) }}
{{- end -}}

{{- /*
The names the main chart derives from search.name and tls.certsSecretPrefix (its _helpers.tpl), repeated here so
the two charts read the same secrets; a value set by hand wins.
*/ -}}
{{- define "vanity.serverCertSecret" -}}
{{ .Values.tls.serverCertSecret | default (printf "%s-%s-search-lb-0-cert" .Values.tls.certsSecretPrefix .Values.search.name) }}
{{- end -}}
{{- define "vanity.clientCertSecret" -}}
{{ .Values.tls.clientCertSecret | default (printf "%s-%s-search-lb-0-client-cert" .Values.tls.certsSecretPrefix .Values.search.name) }}
{{- end -}}
{{- define "vanity.mongotService" -}}
{{ .Values.mongot.service | default (printf "%s-search-0-svc" .Values.search.name) }}
{{- end -}}
{{- /* The address Envoy resolves and the SNI it sends to mongot: the headless Service's cluster-local FQDN. */ -}}
{{- define "vanity.mongotFQDN" -}}
{{ printf "%s.%s.svc.cluster.local" (include "vanity.mongotService" .) (include "vanity.namespace" .) }}
{{- end -}}

{{- /*
The TLS server names Envoy accepts, as a JSON list: serverNames, or [vanityHostname] when it is empty. The Route (or
Ingress) sends every client with vanityHostname as SNI, so a list without it is refused here: the preflight checks
the certificate against this list only, and would pass while Envoy closed every handshake of the Route.
*/ -}}
{{- define "vanity.serverNames" -}}
{{- $names := .Values.serverNames | default (list .Values.vanityHostname) -}}
{{- if not (has .Values.vanityHostname $names) -}}
{{- fail (printf "serverNames must hold vanityHostname %s: the Route (or Ingress) sends its clients with that name, and Envoy would refuse every one. serverNames: %s" .Values.vanityHostname (toJson $names)) -}}
{{- end -}}
{{ toJson $names }}
{{- end -}}
