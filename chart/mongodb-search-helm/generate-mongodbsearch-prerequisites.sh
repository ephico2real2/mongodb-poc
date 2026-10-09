#!/usr/bin/env bash
# Turns the company's password-protected PEM files into the five objects this chart needs before it installs (the
# chart's README, "The prerequisites script"), as YAML files in ./<namespace>/ and, with --apply, in the cluster.
# It is packaged with the chart. helm stores a chart's files without the executable bit: run it with bash, from a
# directory OUTSIDE the chart (helm packages every file of a chart's directory).
#
#   export TargetNamespace=dvh-vectordb-qa        # or --target-namespace <ns> on each command; there is no default
#   mkdir -m 700 dvh-vectordb-qa                  # this script never creates the folder
#   P=<the chart>/generate-mongodbsearch-prerequisites.sh
#
#   bash $P --check [--mongot <pem>] [--envoy <pem>] [--route <pem>]
#   bash $P --trustca <pem> [--trustca <pem>...] [--check-source <host:port>]  --dry-run | --apply
#   bash $P --mongot  <pem>                       --dry-run | --apply
#   bash $P --envoy   <pem>                       --dry-run | --apply
#   bash $P --route   <pem> [--hostname <fqdn>]   --dry-run | --apply
#   bash $P --dbcred  [--username mongotuser]     --dry-run | --apply
#   bash $P --clean
#
# --dry-run writes the file and contacts no cluster. --apply writes it and creates the object with `oc create`;
# --replace lets it replace one that exists, --yes skips typing the namespace back. For automation, the key's
# passphrase and the database password may come from a file only you can read: --passin-file, --password-file.
#
# Each company PEM holds an encrypted private key, the CA bundle and the leaf certificate. Works with OpenSSL 3 and
# with the LibreSSL macOS ships (OPENSSL names another binary), under bash 3.2 and later.
set +x                    # a caller's "bash -x" would print the key: tracing is off whatever was inherited
set +a                    # and "allexport" would put it in the environment of every command run below
unset KEY pw again        # so would a variable of the caller's that has one of these names and is exported
set -euo pipefail
ulimit -c 0 2>/dev/null || true
umask 077

OPENSSL="${OPENSSL:-openssl}"
# tls.certsSecretPrefix and search.name of the chart. The operator builds the three TLS secret names from them and
# finds the secrets by name only (templates/_helpers.tpl).
PREFIX=ent
SEARCH=mongot
MONGOT_SECRET="${PREFIX}-${SEARCH}-search-cert"
ENVOY_SECRET="${PREFIX}-${SEARCH}-search-lb-0-client-cert"
LB_SECRET="${PREFIX}-${SEARCH}-search-lb-0-cert"
TRUST_CM="${PREFIX}-trust-bundle"
PASSWORD_SECRET=search-sync-source-password
NOTE=prerequisites.mongodb-search          # the prefix of the annotations each file carries
ME="$(basename "$0")"

die()  { printf '%s: %s\n' "${ME}" "$*" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }
usage() { sed -n '2,/^set +x/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------------------------------- arguments
ACTION="" MODE="" NS_FLAG="" PEM="" HOSTNAME_WANTED="" USERNAME=mongotuser PASSIN_FILE="" PASSWORD_FILE=""
SOURCE_HOST="" REPLACE=no YES=no CHECK=no CHECK_MONGOT="" CHECK_ENVOY="" CHECK_ROUTE=""
TRUST_PEMS=()
action() { [[ -z "${ACTION}" || "${ACTION}" == "$1" ]] || die "one action a run: --${ACTION} and --$1 were both given"; ACTION="$1"; }
value()  { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   CHECK=yes ;;
    --mongot|--envoy|--route) value "$@"
               if [[ "${CHECK:-no}" == yes ]]; then
                 case "$1" in --mongot) CHECK_MONGOT="$2" ;; --envoy) CHECK_ENVOY="$2" ;; --route) CHECK_ROUTE="$2" ;; esac
               else action "${1#--}"; PEM="$2"; fi; shift ;;
    --trustca) value "$@"; action trustca; TRUST_PEMS+=("$2"); shift ;;
    --dbcred)  action dbcred ;;
    --clean)   action clean ;;
    --dry-run|--apply) [[ -z "${MODE}" || "${MODE}" == "${1#--}" ]] || die "--dry-run and --apply were both given"; MODE="${1#--}" ;;
    --target-namespace) value "$@"; NS_FLAG="$2"; shift ;;
    --target-namespace=*) value --target-namespace "${1#*=}"; NS_FLAG="${1#*=}" ;;
    --hostname)      value "$@"; HOSTNAME_WANTED="$2"; shift ;;
    --username)      value "$@"; USERNAME="$2"; shift ;;
    --passin-file)   value "$@"; PASSIN_FILE="$2"; shift ;;
    --password-file) value "$@"; PASSWORD_FILE="$2"; shift ;;
    --check-source)  value "$@"; SOURCE_HOST="$2"; shift ;;
    --replace) REPLACE=yes ;;
    --yes)     YES=yes ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1 (--help lists them)" ;;
  esac
  shift
done
# --check may come after the PEMs it is to look at: "--mongot x.pem --check".
if [[ "${CHECK:-no}" == yes ]]; then
  case "${ACTION}" in
    mongot) CHECK_MONGOT="${PEM}" ;; envoy) CHECK_ENVOY="${PEM}" ;; route) CHECK_ROUTE="${PEM}" ;;
    "") ;; *) die "--check goes with --mongot, --envoy and --route only" ;;
  esac
  ACTION=check
fi
[[ -n "${ACTION}" ]] || { usage >&2; exit 2; }
# Both go into an annotation of the file, on one line: a newline in either would give YAML that oc reads otherwise.
[[ "${USERNAME}${HOSTNAME_WANTED}" != *[[:cntrl:]]* ]] || die "--username and --hostname take no control character (a newline is one)"

# ---------------------------------------------------------------------------------------------------- namespace
# Hard rule: the namespace is named by the caller, here or in TargetNamespace. Nothing is assumed, and the project
# `oc` happens to be on is never used.
NS="${NS_FLAG:-${TargetNamespace:-}}"
[[ -n "${NS}" ]] || die "no namespace: export TargetNamespace=<namespace>, or pass --target-namespace <namespace>"
[[ -z "${NS_FLAG}" || -z "${TargetNamespace:-}" || "${NS_FLAG}" == "${TargetNamespace}" ]] \
  || die "--target-namespace says ${NS_FLAG} and TargetNamespace says ${TargetNamespace}: which one?"
NAME_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
[[ "${NS}" =~ ${NAME_RE} && ${#NS} -le 63 ]] || die "'${NS}' is not a namespace name (lower-case letters, digits and '-')"
DIR="${PWD}/${NS}"

# helm packages every file under a chart's directory, and keeps the chart in each release it installs: a key
# written inside a chart would travel with it.
chart_above() {      # prints the chart this directory is in, if it is in one
  local d="${PWD}"
  while [[ -n "${d}" && "${d}" != "/" ]]; do
    if [[ -f "${d}/Chart.yaml" ]]; then say "${d}"; return 0; fi
    d="$(dirname "${d}")"
  done
  return 1
}
folder_problem() {   # prints what is wrong with the folder, or nothing
  local chart
  # shellcheck disable=SC2012  # ls prints the mode the same way on BSD and GNU; stat does not
  if chart="$(chart_above)"; then
    say "this directory is inside the Helm chart ${chart}: what is written here would be packaged with the chart. Run the script from a directory outside it"
  elif [[ -L "${DIR}" ]]; then say "${DIR} is a link; it must be a real directory"
  elif [[ ! -d "${DIR}" ]]; then say "no folder ${NS}/ here (${PWD}). Create it yourself: mkdir -m 700 ${NS}"
  elif [[ "$(ls -ld "${DIR}" | cut -c5-10)" != "------" ]]; then say "${NS}/ can be read by others. Close it: chmod 700 ${NS}"
  fi
}
# A file this script writes must be one git ignores: the repository this lives in is public.
in_git() { git -C "${DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
kept_how() { if in_git; then say "mode 600, and ignored by git"; else say "mode 600"; fi; }
tracked_problem() {  # $1 = file name in the folder
  git -C "${DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  git -C "${DIR}" check-ignore -q -- "$1" 2>/dev/null \
    || say "git would track ${NS}/$1. Add a line to .gitignore first: /${NS}/"
}
need_folder() { local p; p="$(folder_problem)"; [[ -z "${p}" ]] || die "${p}"; }

WORK="" TTY_STATE="" PARTIAL=""
cleanup() {
  trap '' HUP INT QUIT TERM         # the tidying is not stopped half way (bash hangs up its own group a second time)
  [[ -z "${TTY_STATE}" ]] || stty "${TTY_STATE}" < /dev/tty 2>/dev/null || true       # stopped while asking a secret
  [[ -z "${WORK}" ]] || rm -rf "${WORK}"
  [[ -z "${PARTIAL}" ]] || rm -f "${PARTIAL}"                 # this run's own, in a folder that passed need_folder
}
trap cleanup EXIT
# Without these two the EXIT trap is not run: bash 5 skips it when a hangup arrives inside $(...), as when the
# terminal is closed at the passphrase prompt, and bash 3.2 dies of SIGQUIT (Ctrl-\) where bash 5 ignores it.
trap 'exit 129' HUP
trap 'exit 131' QUIT
workdir() { WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdbs-prereq.XXXXXX")"; }

# ---------------------------------------------------------------------------------------------------- certificates
# What a PEM holds, read without its passphrase. Sets CERT_FILES (one file per certificate, in the PEM's order),
# KEY_BLOCKS and KEY_ENCRYPTED, and leaves the PEM without CRs or a byte-order mark in ${IN}.
read_pem() {  # $1 = pem
  [[ -f "$1" && -r "$1" ]] || die "cannot read $1"
  # openssl's prompt names the file it reads, so the copy keeps the PEM's name, in a directory of its own where no
  # name of this script's can meet it.
  rm -rf "${WORK}/in"; mkdir "${WORK}/in"; IN="${WORK}/in/$(basename "$1")"
  LC_ALL=C sed -e $'1s/^\xef\xbb\xbf//' -e $'s/\r$//' "$1" > "${IN}"
  local kinds unknown
  kinds="$(LC_ALL=C grep -E '^-----BEGIN [A-Z0-9 ]+-----$' "${IN}" | sed -e 's/^-----BEGIN //' -e 's/-----$//' || true)"
  [[ -n "${kinds}" ]] || die "$1 holds no PEM block"
  unknown="$(grep -vxE 'CERTIFICATE|PRIVATE KEY|ENCRYPTED PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|EC PARAMETERS' <<<"${kinds}" | sort -u | tr '\n' ',' | sed 's/,$//' || true)"
  [[ -z "${unknown}" ]] || die "$1 holds a block this script does not take: ${unknown}"
  KEY_BLOCKS="$(grep -cE 'PRIVATE KEY$' <<<"${kinds}" || true)"
  KEY_ENCRYPTED=no
  if grep -qx 'ENCRYPTED PRIVATE KEY' <<<"${kinds}" || grep -q '^Proc-Type: 4,ENCRYPTED' "${IN}"; then KEY_ENCRYPTED=yes; fi
  rm -f "${WORK}"/cert-*.crt
  awk -v d="${WORK}" '/^-----BEGIN CERTIFICATE-----$/{n++; f=1} f{print > (d "/cert-" n ".crt")} /^-----END CERTIFICATE-----$/{f=0}' "${IN}"
  CERT_FILES=()
  local i=1
  while [[ -f "${WORK}/cert-${i}.crt" ]]; do
    "${OPENSSL}" x509 -in "${WORK}/cert-${i}.crt" -noout >/dev/null 2>&1 || die "certificate ${i} of $1 cannot be read"
    CERT_FILES+=("${WORK}/cert-${i}.crt"); i=$((i + 1))
  done
}

# The two builds print a subject differently ("subject=CN=x" and "subject= /CN=x"); RFC 2253 is the same in both.
subject_of() { "${OPENSSL}" x509 -in "$1" -noout -subject -nameopt RFC2253 | sed 's/^subject= *//'; }
issuer_of()  { "${OPENSSL}" x509 -in "$1" -noout -issuer  -nameopt RFC2253 | sed 's/^issuer= *//'; }
expiry_of()  { "${OPENSSL}" x509 -in "$1" -noout -enddate | sed 's/^notAfter=//'; }
print_of()   { "${OPENSSL}" x509 -in "$1" -noout -fingerprint -sha256 | sed 's/^.*=//'; }
# The line under an extension's heading in the text form, which is the same in both builds. Never a search of the
# whole text: an issuer's alternative names and name constraints print "DNS:" too.
extension() { "${OPENSSL}" x509 -in "$1" -noout -text | awk -v h="$2" 'index($0, h) {getline; sub(/^ +/, ""); print; exit}'; }
is_ca()     { [[ "$(extension "$1" 'X509v3 Basic Constraints')" == CA:TRUE* || "$(subject_of "$1")" == "$(issuer_of "$1")" ]]; }
# The text reads "URI:http://x/a, DNS:y" the same whether y is a name of the certificate or the tail of its URI. The
# DER does not: the names read from the text count only when the extension holds as many dNSName entries ([2]).
dns_names() {
  local found at
  found="$(extension "$1" 'X509v3 Subject Alternative Name' | tr ',' '\n' | sed -n 's/^ *DNS://p' | tr '[:upper:]' '[:lower:]')"
  [[ -n "${found}" ]] || return 0
  at="$("${OPENSSL}" asn1parse -in "$1" | awk '/:X509v3 Subject Alternative Name$/ {f = 1; next} f == 1 && /OCTET STRING/ {print $1 + 0; f = 2}')"
  [[ "$("${OPENSSL}" asn1parse -in "$1" -strparse "${at:-0}" 2>/dev/null | grep -c 'd=1 .*cont \[ 2 \]')" == "$(grep -c . <<<"${found}")" ]] || return 0
  say "${found}"
}
# "SSL client : Yes" in both builds. A certificate with no extended key usage may be used for both, and says so here.
may()       { "${OPENSSL}" x509 -in "$1" -noout -purpose | grep -q "^SSL $2 : Yes"; }
# Does the certificate carry this name? A wildcard covers one label, as TLS has it.
names() {     # $1 = certificate, $2 = name
  local want san; want="$(tr '[:upper:]' '[:lower:]' <<<"$2")"
  while IFS= read -r san; do
    [[ "${san}" == "${want}" ]] && return 0
    [[ "${san}" == \*.* && "${want#*.}" == "${san#\*.}" && "${want%%.*}" != "" && "${want}" == *.* ]] && return 0
  done < <(dns_names "$1")
  return 1
}

# From a certificate upward: each certificate's issuer is the next one's subject. A name does not say which of two
# CAs signed (a renewed CA keeps its name, a cross-signed one has two issuers), so a path counts only when the leaf
# verifies against it and nothing else. Sets PATH_UP to the first such path and returns 0, or returns 1.
climb() {  # $1 = the certificate to go on from, then the path so far
  local at="$1" issuer f on; shift
  issuer="$(issuer_of "${at}")"
  if [[ $# -gt 0 && "$(subject_of "${at}")" == "${issuer}" ]]; then          # a root: the path ends here
    cat "$@" > "${WORK}/path.crt"
    "${OPENSSL}" verify -CAfile "${WORK}/path.crt" "${LEAF}" >/dev/null 2>&1 || return 1
    PATH_UP=("$@"); return 0
  fi
  for f in "${REST[@]}"; do
    for on in "$@"; do [[ "${on}" != "${f}" ]] || continue 2; done
    [[ "$(subject_of "${f}")" == "${issuer}" ]] || continue
    if climb "${f}" "$@" "${f}"; then return 0; fi
  done
  return 1
}
# The leaf, the chain in issuer order, and the checks that need no key. Sets LEAF, and writes ${WORK}/ca.crt,
# ${WORK}/tls.crt (leaf, then chain) and ${WORK}/path.crt (what the leaf is verified against).
sort_chain() {  # $1 = the leaf's file
  LEAF="$1"
  local f print seen chain=()
  REST=() PATH_UP=()
  seen=" $(print_of "${LEAF}") "
  for f in "${CERT_FILES[@]}"; do
    [[ "${f}" == "${LEAF}" ]] && continue
    print="$(print_of "${f}")"
    case "${seen}" in *" ${print} "*) continue ;; esac                       # the same certificate again: once
    seen="${seen}${print} "
    is_ca "${f}" || die "$(subject_of "${f}") is neither the certificate of this key nor a CA: one leaf to a PEM"
    REST+=("${f}")
  done
  [[ ${#REST[@]} -gt 0 ]] || die "the PEM holds no CA certificate: the leaf's chain is needed"
  climb "${LEAF}" || true
  chain=(${PATH_UP[@]+"${PATH_UP[@]}"})
  for f in "${REST[@]}"; do                                                  # a CA outside the chain is kept, last
    case " ${chain[*]+"${chain[*]}"} " in *" ${f} "*) ;; *) chain+=("${f}") ;; esac
  done
  cat "${chain[@]}" > "${WORK}/ca.crt"
  cat "${LEAF}" "${WORK}/ca.crt" > "${WORK}/tls.crt"
  # No path: every CA is offered, and verify_chain says what openssl makes of it.
  [[ ${#PATH_UP[@]} -gt 0 ]] || cp "${WORK}/ca.crt" "${WORK}/path.crt"
}
verify_chain() {
  local said
  if ! said="$("${OPENSSL}" verify -CAfile "${WORK}/path.crt" "${LEAF}" 2>&1)"; then
    die "the leaf does not verify against the CA certificates in its PEM: $(grep -iE 'error|unable' <<<"${said}" | head -1 | sed 's/^ *//'). Issuer wanted: $(issuer_of "${LEAF}")"
  fi
}

# What each role's certificate must be. Refuses by saying which rule; warns on stderr.
SERVICE_SUFFIX=".${NS}.svc.cluster.local"
fits_role() {  # $1 = role, $2 = leaf; prints the problem, or nothing
  local role="$1" leaf="$2" other
  case "${role}" in
    mongot)
      if ! may "${leaf}" server || ! may "${leaf}" client; then say "mongot's certificate must allow server and client authentication"; return; fi
      names "${leaf}" "${SEARCH}-search-0-svc${SERVICE_SUFFIX}" \
        || say "it does not name ${SEARCH}-search-0-svc${SERVICE_SUFFIX} (it names: $(dns_names "${leaf}" | tr '\n' ' ')): a certificate is issued for one namespace" ;;
    envoy)
      may "${leaf}" client || { say "Envoy's client certificate must allow client authentication"; return; }
      # It needs no name (TLS.md, 6.1). One it does carry must not say it belongs somewhere else.
      other="$(dns_names "${leaf}" | grep -E '\.svc(\.cluster\.local)?$' | grep -vF "${SERVICE_SUFFIX}" | grep -vxE "[^.]+\.${NS}\.svc" | head -1 || true)"
      [[ -z "${other}" ]] || { say "it names ${other}, a service of another namespace"; return; }
      # mongot's own certificate names mongot's service by its full name, and may name Envoy's as well (TLS.md, 6.1).
      if [[ -n "$(dns_names "${leaf}" | grep -xF "${SEARCH}-search-0-svc${SERVICE_SUFFIX}" || true)" ]] \
         || { names "${leaf}" "${SEARCH}-search-0-svc${SERVICE_SUFFIX}" && ! names "${leaf}" "${SEARCH}-search-0-proxy-svc${SERVICE_SUFFIX}"; }; then
        say "it names mongot's own service: this is the mongot PEM"
      fi ;;
    route)
      may "${leaf}" server || { say "the public certificate must allow server authentication"; return; }
      public_name "${leaf}" >/dev/null 2>&1 || say "$(public_name "${leaf}" 2>&1 >/dev/null)" ;;
  esac
}
# The hostname the public certificate serves: --hostname when given, else its one name that is a real hostname.
public_name() {  # $1 = leaf; prints the name, or says why there is none on stderr and returns 1
  local real count
  if [[ -n "${HOSTNAME_WANTED}" ]]; then
    names "$1" "${HOSTNAME_WANTED}" || { say "it does not name ${HOSTNAME_WANTED} (it names: $(dns_names "$1" | tr '\n' ' '))" >&2; return 1; }
    tr '[:upper:]' '[:lower:]' <<<"${HOSTNAME_WANTED}"; return 0
  fi
  real="$(dns_names "$1" | grep -vE '^\*\.|\.svc$|\.cluster\.local$' || true)"
  count="$(grep -c . <<<"${real}" || true)"
  case "${count}" in
    1) say "${real}" ;;
    0) say "it names no public hostname (it names: $(dns_names "$1" | tr '\n' ' ')): is this the public certificate?" >&2; return 1 ;;
    *) say "it names several hostnames ($(tr '\n' ' ' <<<"${real}")): say which with --hostname" >&2; return 1 ;;
  esac
}
warn_if_soon() { "${OPENSSL}" x509 -in "$1" -noout -checkend 2592000 >/dev/null 2>&1 || say "WARNING: it expires within 30 days ($(expiry_of "$1"))" >&2; }

# ---------------------------------------------------------------------------------------------------- the key
# The key without its password, in a variable: it is never a file of its own and never an argument.
KEY=""
open_key() {  # $1 = the PEM as the caller named it
  local passin=() said
  [[ "${KEY_BLOCKS}" == 1 ]] || die "$1 holds ${KEY_BLOCKS} private keys; it must hold exactly one"
  if [[ "${KEY_ENCRYPTED}" == yes ]]; then
    [[ -n "${PASSIN_FILE}" ]] || say "the key in $1 is encrypted: its passphrase is asked for now" >&2
    if [[ -n "${PASSIN_FILE}" ]]; then
      [[ -f "${PASSIN_FILE}" ]] || die "no passphrase file ${PASSIN_FILE}"
      [[ -r "${PASSIN_FILE}" ]] || die "the passphrase file ${PASSIN_FILE} cannot be read"
      [[ -s "${PASSIN_FILE}" ]] || die "the passphrase file ${PASSIN_FILE} is empty"
      passin=(-passin stdin)        # through a pipe, below: no copy of the passphrase on disk, no terminal looked for
    elif ! { : < /dev/tty; } 2>/dev/null; then
      die "the key is encrypted and there is no terminal to ask its passphrase on: use --passin-file <file>"
    fi
  fi
  # openssl asks for the passphrase itself. It prints its question a moment before it stops the terminal showing
  # what is typed (LibreSSL on a macOS runner showed a passphrase typed in that moment, 2026-10-08), so the terminal
  # is told here, before openssl starts, and told back after.
  local opened=yes
  if [[ "${KEY_ENCRYPTED}" == yes && -z "${PASSIN_FILE}" ]]; then TTY_STATE="$(stty -g < /dev/tty)"; stty -echo < /dev/tty; fi
  if [[ ${#passin[@]} -gt 0 ]]; then                    # tr: a CR at the end of the line would be "bad decrypt"
    KEY="$(LC_ALL=C tr -d '\r' < "${PASSIN_FILE}" | "${OPENSSL}" pkey -in "${IN}" "${passin[@]}" 2>"${WORK}/key.err")" || opened=no
  else
    KEY="$("${OPENSSL}" pkey -in "${IN}" 2>"${WORK}/key.err")" || opened=no
  fi
  if [[ -n "${TTY_STATE}" ]]; then stty "${TTY_STATE}" < /dev/tty; TTY_STATE=""; fi
  if [[ "${opened}" == no ]]; then
    if grep -qiE 'bad decrypt|bad password|maybe wrong password|mac verify' "${WORK}/key.err"; then die "wrong passphrase for the key in $1"; fi
    said="$(grep -iE 'error|unsupported|unable' "${WORK}/key.err" | head -1 || true)"
    die "this openssl ($("${OPENSSL}" version)) cannot read the key in $1: ${said:-no reason given}. Another build may: set OPENSSL"
  fi
  [[ "${KEY}" == "-----BEGIN PRIVATE KEY-----"* ]] || die "the key did not come out as an unencrypted PKCS#8 key"
}
key_public() { printf '%s\n' "${KEY}" | "${OPENSSL}" pkey -pubout 2>/dev/null; }
b64()        { "${OPENSSL}" base64 -A; }

# ---------------------------------------------------------------------------------------------------- the files
# A YAML double-quoted string. (sed, not ${var//}: bash 3.2 reads a quote inside that form differently.)
quoted() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }
head_of() {  # $1 = kind, $2 = name, then annotation pairs
  local kind="$1" name="$2"; shift 2
  say "# Made by ${ME} (chart mongodb-search-helm) for the namespace ${NS}. Do not edit: run it again."
  say "apiVersion: v1"; say "kind: ${kind}"; say "metadata:"; say "  name: ${name}"; say "  namespace: ${NS}"
  say "  labels:"; say "    app.kubernetes.io/managed-by: generate-mongodbsearch-prerequisites"
  say "  annotations:"; say "    ${NOTE}/generated-at: $(quoted "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  while [[ $# -ge 2 ]]; do say "    ${NOTE}/$1: $(quoted "$2")"; shift 2; done
}
# Written beside its place under a private umask and moved there: the file is never half there and never readable
# by another user, not even for a moment.
# The temporary name ends like the file's own, so a rule that ignores "*.secret.yaml" ignores it too.
partial_of() { say "${DIR}/.partial.$1"; }
put() {  # $1 = file name; the content on stdin
  local problem at="${DIR}/$1" part; part="$(partial_of "$1")"
  problem="$(tracked_problem "$1")"; [[ -n "${problem}" ]] || problem="$(tracked_problem ".partial.$1")"
  [[ -z "${problem}" ]] || die "${problem}"
  # A directory, or a link to one, at the file's name would have mv put the key inside it; a link at the temporary
  # name would have the key written wherever it points.
  [[ ! -d "${at}" ]] || die "${NS}/$1 is a directory, or a link to one: remove it"
  rm -f "${part}"
  ( set -o noclobber; cat > "${part}" )
  mv -f "${part}" "${at}"
}
note_in() { sed -n "s|^    ${NOTE}/$2: \"\\(.*\\)\"\$|\\1|p" "$1" | head -1; }      # an annotation of a file made here
field_in() {  # $1 = file, $2 = a key of data: the value, decoded
  sed -n "s/^  $(sed 's/\./\\./g' <<<"$2"): //p" "$1" | head -1 | tr -d '"' | "${OPENSSL}" base64 -d -A
}

# ---------------------------------------------------------------------------------------------------- the cluster
logged_in() { command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1; }
to_cluster() {  # $1 = kind (secret|configmap), $2 = name, $3 = file
  command -v oc >/dev/null 2>&1 || die "--apply needs oc on the PATH"
  local user server typed
  user="$(oc whoami 2>/dev/null)" || die "--apply needs you logged in: oc login"
  server="$(oc whoami --show-server)"
  oc get namespace "${NS}" >/dev/null 2>&1 || die "there is no namespace ${NS} on ${server}; this script never creates one"
  say "cluster ${server}, as ${user}, namespace ${NS}"
  if [[ "${YES}" != yes ]]; then
    { : < /dev/tty; } 2>/dev/null || die "no terminal to confirm on: pass --yes"
    printf 'type the namespace to go on: ' > /dev/tty; IFS= read -r typed < /dev/tty
    [[ "${typed}" == "${NS}" ]] || die "that is not ${NS}; nothing was sent"
  fi
  # create and replace, never apply: apply copies the whole object, the key with it, into an annotation.
  if oc get "$1" "$2" -n "${NS}" >/dev/null 2>&1; then
    [[ "${REPLACE}" == yes ]] || die "$1 $2 is already in ${NS}; --replace replaces it (this script restarts no pod)"
    oc replace -f "$3" -n "${NS}"
  else
    oc create -f "$3" -n "${NS}"
  fi
  say "it holds: $(oc get "$1" "$2" -n "${NS}" -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}')"
}

# ---------------------------------------------------------------------------------------------------- actions
tls_secret() {  # $1 = role, $2 = secret name
  local role="$1" name="$2" file="$2.secret.yaml" f pub leaf="" problem other host=""
  [[ -n "${MODE}" ]] || die "--${role} needs --dry-run or --apply"
  need_folder; workdir; PARTIAL="$(partial_of "${file}")"
  read_pem "${PEM}"
  [[ ${#CERT_FILES[@]} -gt 0 ]] || die "${PEM} holds no certificate"
  open_key "${PEM}"
  # The leaf is the certificate of this key. (Sorting by "CA:TRUE" alone misplaces a root with no basic
  # constraints, and a leaf marked CA.)
  pub="$(key_public)"
  for f in "${CERT_FILES[@]}"; do
    if [[ "$("${OPENSSL}" x509 -in "${f}" -noout -pubkey)" == "${pub}" ]]; then leaf="${f}"; break; fi
  done
  [[ -n "${leaf}" ]] || die "no certificate in ${PEM} belongs to its key"
  sort_chain "${leaf}"
  verify_chain
  problem="$(fits_role "${role}" "${LEAF}")"
  [[ -z "${problem}" ]] || die "${PEM} is not the ${role} certificate for ${NS}: ${problem}"
  for other in "${DIR}"/*.secret.yaml; do                 # one certificate, one role
    [[ -f "${other}" && "$(basename "${other}")" != "${file}" ]] || continue
    [[ "$(note_in "${other}" leaf-sha256)" != "$(print_of "${LEAF}")" ]] \
      || die "this certificate is already in $(basename "${other}"): each role has its own PEM"
  done
  warn_if_soon "${LEAF}"
  [[ "${role}" != route ]] || host="$(public_name "${LEAF}")"

  { head_of Secret "${name}" leaf-subject "$(subject_of "${LEAF}")" leaf-not-after "$(expiry_of "${LEAF}")" \
      leaf-sha256 "$(print_of "${LEAF}")" ${host:+public-hostname "${host}"}
    say "type: kubernetes.io/tls"; say "data:"
    # Quoted: base64 can spell a number ("4420") or "Null", which YAML would not read as text.
    say "  tls.crt: \"$(b64 < "${WORK}/tls.crt")\""
    say "  tls.key: \"$(printf '%s\n' "${KEY}" | b64)\""
    say "  ca.crt: \"$(b64 < "${WORK}/ca.crt")\""
  } | put "${file}"
  # Read back from the file: the key in it has no password and is the leaf's.
  if [[ "$(field_in "${DIR}/${file}" tls.key | "${OPENSSL}" pkey -pubout 2>/dev/null)" != "${pub}" ]]; then
    rm -f "${DIR}/${file}"
    die "${NS}/${file} did not hold the key it was given; it is removed"
  fi
  KEY=""

  say "${name} (Secret, kubernetes.io/tls) for ${NS}"
  say "  subject   $(subject_of "${LEAF}")"
  say "  names     $(dns_names "${LEAF}" | tr '\n' ' ')"
  say "  expires   $(expiry_of "${LEAF}")"
  say "  chain     $(grep -c 'BEGIN CERTIFICATE' "${WORK}/ca.crt") CA certificate(s); the leaf verifies against them; the key is the leaf's"
  [[ -z "${host}" ]] || say "  values    loadBalancer.externalHostname: ${host}"
  say "  file      ${NS}/${file}  (it holds the key with no password: $(kept_how))"
  if [[ "${MODE}" == apply ]]; then to_cluster secret "${name}" "${DIR}/${file}"; else say "  dry run: no cluster was contacted"; fi
}

trust_bundle() {
  local file="${TRUST_CM}.configmap.yaml" pem f print seen="" count=0 other said
  [[ -n "${MODE}" ]] || die "--trustca needs --dry-run or --apply"
  need_folder; workdir; PARTIAL="$(partial_of "${file}")"; : > "${WORK}/bundle.crt"
  for pem in "${TRUST_PEMS[@]}"; do
    read_pem "${pem}"                                        # the key in it, if any, is not opened
    for f in ${CERT_FILES[@]+"${CERT_FILES[@]}"}; do
      is_ca "${f}" || continue
      print="$(print_of "${f}")"
      case " ${seen} " in *" ${print} "*) continue ;; esac
      seen="${seen} ${print}"; count=$((count + 1))
      cat "${f}" >> "${WORK}/bundle.crt"; cp "${f}" "${WORK}/ca-${count}.crt"
    done
  done
  [[ ${count} -gt 0 ]] || die "no CA certificate in: ${TRUST_PEMS[*]}"
  # Every leaf already made for this namespace must verify against the bundle the pods will mount.
  for other in "${DIR}"/*.secret.yaml; do
    [[ -f "${other}" ]] && grep -q '^  tls.crt: ' "${other}" || continue
    field_in "${other}" tls.crt | awk '/BEGIN CERTIFICATE/{n++} n==1' > "${WORK}/leaf.crt"
    "${OPENSSL}" verify -CAfile "${WORK}/bundle.crt" "${WORK}/leaf.crt" >/dev/null 2>&1 \
      || die "the leaf in $(basename "${other}") does not verify against this bundle: add its CA with another --trustca"
  done
  if [[ -n "${SOURCE_HOST}" ]]; then                          # runbook Step 4: mongot checks the source mongod with it
    said="$("${OPENSSL}" s_client -connect "${SOURCE_HOST}" -servername "${SOURCE_HOST%:*}" -CAfile "${WORK}/bundle.crt" </dev/null 2>/dev/null | grep 'Verify return code' || true)"
    [[ "${said}" == *"Verify return code: 0 (ok)"* ]] || die "the source ${SOURCE_HOST} is not trusted by this bundle (${said:-no answer}): add its CA with another --trustca"
  fi
  { head_of ConfigMap "${TRUST_CM}" ca-count "${count}"
    say "data:"; say "  ca.crt: |"; sed 's/^/    /' "${WORK}/bundle.crt"
  } | put "${file}"
  say "${TRUST_CM} (ConfigMap, key ca.crt) for ${NS}: ${count} CA certificate(s)"
  local i=1; while [[ ${i} -le ${count} ]]; do say "  $(subject_of "${WORK}/ca-${i}.crt")  (expires $(expiry_of "${WORK}/ca-${i}.crt"))"; i=$((i + 1)); done
  [[ -z "${SOURCE_HOST}" ]] || say "  the source ${SOURCE_HOST} presents a certificate this bundle trusts"
  say "  file      ${NS}/${file}"
  if [[ "${MODE}" == apply ]]; then to_cluster configmap "${TRUST_CM}" "${DIR}/${file}"; else say "  dry run: no cluster was contacted"; fi
}

db_password() {
  local file="${PASSWORD_SECRET}.secret.yaml" pw again
  [[ -n "${MODE}" ]] || die "--dbcred needs --dry-run or --apply"
  need_folder; PARTIAL="$(partial_of "${file}")"
  if [[ -n "${PASSWORD_FILE}" ]]; then
    [[ -f "${PASSWORD_FILE}" ]] || die "no password file ${PASSWORD_FILE}"
    # The shell drops a NUL byte without a word: a file saved as UTF-16 would give another password.
    [[ "$(LC_ALL=C tr -d '\0' < "${PASSWORD_FILE}" | wc -c)" -eq "$(wc -c < "${PASSWORD_FILE}")" ]] \
      || die "${PASSWORD_FILE} holds a NUL byte (is it UTF-16?): save the password as plain text"
    pw="$(LC_ALL=C tr -d '\r' < "${PASSWORD_FILE}")"            # the file's content, without the newline that ends it
  else
    { : < /dev/tty; } 2>/dev/null || die "no terminal to ask the password on: use --password-file <file>"
    # The terminal stops showing what is typed before the first question and starts again after the second:
    # with "read -s" on each, what is typed between the two (or pasted at once) would be shown.
    # -r and an empty IFS: a backslash and the spaces at either end are part of a password.
    TTY_STATE="$(stty -g < /dev/tty)"; stty -echo < /dev/tty
    printf 'password of %s on the source mongod: ' "${USERNAME}" > /dev/tty; IFS= read -r pw < /dev/tty; echo > /dev/tty
    printf 'again: ' > /dev/tty; IFS= read -r again < /dev/tty; echo > /dev/tty
    stty "${TTY_STATE}" < /dev/tty; TTY_STATE=""
    [[ "${pw}" == "${again}" ]] || die "the two did not match; nothing was written"
  fi
  [[ -n "${pw}" ]] || die "an empty password; nothing was written"
  # printf '%s': no newline is added, which would become part of the password and fail the sign-in.
  { head_of Secret "${PASSWORD_SECRET}" username "${USERNAME}"
    say "type: Opaque"; say "data:"; say "  password: \"$(printf '%s' "${pw}" | b64)\""
  } | put "${file}"
  say "${PASSWORD_SECRET} (Secret, key password) for ${NS}: $(printf '%s' "${pw}" | wc -c | tr -d ' ') bytes, for ${USERNAME}"
  pw="" again=""
  say "  values    source.username: ${USERNAME}"
  say "  file      ${NS}/${file}  ($(kept_how))"
  if [[ "${MODE}" == apply ]]; then to_cluster secret "${PASSWORD_SECRET}" "${DIR}/${file}"; else say "  dry run: no cluster was contacted"; fi
}

look_at() {  # $1 = role, $2 = pem: what it holds, without its passphrase
  local f first="" problem
  read_pem "$2"
  say "  $2: ${KEY_BLOCKS} private key(s)$([[ "${KEY_ENCRYPTED}" == yes ]] && echo ', encrypted'), ${#CERT_FILES[@]} certificate(s)"
  [[ "${KEY_BLOCKS}" == 1 ]] || { say "    PROBLEM: it must hold exactly one private key"; PROBLEMS=$((PROBLEMS + 1)); }
  for f in ${CERT_FILES[@]+"${CERT_FILES[@]}"}; do is_ca "${f}" || { first="${f}"; break; }; done
  [[ -n "${first}" ]] || { say "    PROBLEM: no leaf certificate"; PROBLEMS=$((PROBLEMS + 1)); return; }
  say "    leaf     $(subject_of "${first}")"
  say "    names    $(dns_names "${first}" | tr '\n' ' ')"
  say "    expires  $(expiry_of "${first}")"
  problem="$(fits_role "$1" "${first}")"
  if [[ -n "${problem}" ]]; then say "    PROBLEM: not the $1 certificate for ${NS}: ${problem}"; PROBLEMS=$((PROBLEMS + 1)); else say "    fits     --$1 for ${NS}"; fi
}
check() {
  local p tool f name kind host="" dbuser=""
  PROBLEMS=0
  say "namespace  ${NS}"
  p="$(folder_problem)"
  if [[ -n "${p}" ]]; then say "folder     PROBLEM: ${p}"; PROBLEMS=$((PROBLEMS + 1)); else
    say "folder     ${NS}/ is here and closed to others"
    p="$(tracked_problem x.secret.yaml)"; [[ -z "${p}" ]] || { say "           PROBLEM: ${p}"; PROBLEMS=$((PROBLEMS + 1)); }
  fi
  for tool in "${OPENSSL}" awk sed; do
    command -v "${tool}" >/dev/null 2>&1 || { say "tools      PROBLEM: no ${tool} on the PATH"; PROBLEMS=$((PROBLEMS + 1)); }
  done
  say "tools      $("${OPENSSL}" version 2>/dev/null), bash ${BASH_VERSION}"
  if logged_in; then
    say "cluster    $(oc whoami --show-server), as $(oc whoami)"
    if oc get namespace "${NS}" >/dev/null 2>&1; then
      for name in "${TRUST_CM}" "${MONGOT_SECRET}" "${ENVOY_SECRET}" "${LB_SECRET}" "${PASSWORD_SECRET}"; do
        kind=secret; [[ "${name}" != "${TRUST_CM}" ]] || kind=configmap
        if p="$(oc get "${kind}" "${name}" -n "${NS}" -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}' 2>/dev/null)"; then
          say "             ${name}: there (${p% })"
        else say "             ${name}: not there"; fi
      done
    else say "           the namespace ${NS} is not there; --apply needs it, and this script never creates one"; fi
  else say "cluster    not logged in with oc (only --apply needs it)"; fi
  [[ -d "${DIR}" && ! -L "${DIR}" ]] || { say; say "${PROBLEMS} problem(s)"; return 1; }
  workdir
  say "PEM files"
  [[ -z "${CHECK_MONGOT}" ]] || look_at mongot "${CHECK_MONGOT}"
  [[ -z "${CHECK_ENVOY}" ]]  || look_at envoy  "${CHECK_ENVOY}"
  [[ -z "${CHECK_ROUTE}" ]]  || look_at route  "${CHECK_ROUTE}"
  if [[ -z "${CHECK_MONGOT}${CHECK_ENVOY}${CHECK_ROUTE}" ]]; then
    for f in "${DIR}"/*.pem; do
      [[ -f "${f}" ]] || { say "  none in ${NS}/, and none named with --mongot, --envoy or --route"; break; }
      read_pem "${f}"
      say "  ${NS}/$(basename "${f}"): ${KEY_BLOCKS} private key(s)$([[ "${KEY_ENCRYPTED}" == yes ]] && echo ', encrypted'), ${#CERT_FILES[@]} certificate(s)"
    done
  fi
  say "files made for ${NS}"
  for name in "${TRUST_CM}.configmap.yaml" "${MONGOT_SECRET}.secret.yaml" "${ENVOY_SECRET}.secret.yaml" "${LB_SECRET}.secret.yaml" "${PASSWORD_SECRET}.secret.yaml"; do
    f="${DIR}/${name}"
    if [[ -f "${f}" ]]; then
      say "  ${name}: made $(note_in "${f}" generated-at)$(p="$(note_in "${f}" leaf-not-after)"; [[ -z "${p}" ]] || printf ', leaf expires %s' "${p}")"
      [[ "${name}" != "${LB_SECRET}.secret.yaml" ]] || host="$(note_in "${f}" public-hostname)"
      [[ "${name}" != "${PASSWORD_SECRET}.secret.yaml" ]] || dbuser="$(note_in "${f}" username)"
    else say "  ${name}: not made yet"; fi
  done
  say "values for chart/mongodb-search-helm"
  say "  namespace: ${NS}"
  say "  loadBalancer:"
  say "    externalHostname: ${host:-<made known by --route>}"
  say "  source:"
  [[ -n "${dbuser}" ]] || dbuser="<made known by --dbcred; the default of the chart is mongotuser>"
  say "    username: ${dbuser}"
  say "    hostAndPorts: []        # yours to fill: the members of the source mongod"
  say; say "${PROBLEMS} problem(s)"
  [[ ${PROBLEMS} -eq 0 ]]
}

clean() {
  local f name kept=0 found=no
  need_folder
  logged_in || die "--clean removes a file only when its object is in the cluster: log in with oc"
  rm -f "${DIR}"/.partial.*.yaml 2>/dev/null || true          # what a run that was killed left half written
  for f in "${DIR}"/*.secret.yaml; do
    [[ -f "${f}" ]] || continue
    found=yes
    name="$(basename "${f}" .secret.yaml)"
    if oc get secret "${name}" -n "${NS}" >/dev/null 2>&1; then
      rm -f "${f}"; say "removed ${NS}/$(basename "${f}") (the secret ${name} is in ${NS})"
    else kept=$((kept + 1)); say "kept ${NS}/$(basename "${f}"): there is no secret ${name} in ${NS} yet"; fi
  done
  [[ "${found}" == yes ]] || { say "no secret file in ${NS}/"; return 0; }
  # rm -P does nothing on current macOS (its manual says so) and shred cannot reach a copy-on-write file system.
  say "The files are unlinked, not overwritten: on this kind of disk nothing can overwrite them in place."
  [[ ${kept} -eq 0 ]]
}

case "${ACTION}" in
  check)   check ;;
  mongot)  tls_secret mongot "${MONGOT_SECRET}" ;;
  envoy)   tls_secret envoy  "${ENVOY_SECRET}" ;;
  route)   tls_secret route  "${LB_SECRET}" ;;
  trustca) trust_bundle ;;
  dbcred)  db_password ;;
  clean)   clean ;;
esac
