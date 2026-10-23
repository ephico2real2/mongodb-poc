#!/usr/bin/env bash
# Turns the company's password-protected PEM files into the five objects this chart needs before it installs (the
# chart's README, "The prerequisites script"), as YAML files in ./<namespace>/ and, with --apply, in the cluster.
# It is packaged with the chart. helm stores a chart's files without the executable bit: run it with bash, from a
# directory OUTSIDE the chart (helm packages every file of a chart's directory).
#
#   mkdir -m 700 search-qa                        # this script never creates the folder; the PEMs may go in it
#   P=<the chart>/generate-mongodbsearch-prerequisites.sh
#
#   bash $P --check search-qa                     # finds the three PEMs and checks them; no passphrase, writes nothing
#   bash $P --all   --dry-run | --apply search-qa            # --trustca, --mongot, --envoy, --route, --dbcred in turn
#   bash $P --trustca [<pem>...] [--check-source <host:port>]  --dry-run | --apply search-qa
#   bash $P --mongot  [<pem>]                     --dry-run | --apply search-qa
#   bash $P --envoy   [<pem>] [--route-reference <public pem>] --dry-run | --apply search-qa
#   bash $P --route   [<pem>] [--hostname <fqdn>] --dry-run | --apply search-qa
#   bash $P --dbcred  [--username mongotuser]     --dry-run | --apply search-qa
#   bash $P --clean search-qa
#   bash $P --check [--mongot <pem>] [--envoy <pem> [--route-reference <public pem>]] [--route <pem>] search-qa
#
# The namespace has no default. Name it as above, with --target-namespace <ns>, or once with
# export TargetNamespace=<ns>; two that differ are refused.
#
# A PEM not named is found, and shown before any passphrase is asked. In this order:
#   its file name, the certificate's common name, in ./<ns>/ (when it holds no PEM, here):
#     mongot-search-0-svc.<ns>.svc.cluster.local.pem, mongot-search-0-proxy-svc.<ns>.svc.cluster.local.pem, and
#     <fqdn>.pem for the route when --hostname <fqdn> is given. Set MONGOT_PEM_NAME, ENVOY_PEM_NAME, ROUTE_PEM_NAME
#     for other names (tokens {search}, {ns}, {hostname}), or MONGOT_PEM, ENVOY_PEM, ROUTE_PEM to one file's path;
#   else the one PEM in ./<ns>/ (when it has none, here) whose certificate fits the role. None, or two, is refused.
# --envoy tells its PEM from the public one by the route PEM found, as --route-reference does. --trustca with no PEM
# takes the CA certificates of the three PEMs. --all stops at the first step refused. A PEM path that begins with
# "-" is written ./-..., so that it is not read as an option.
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
# The names the enterprise gives its PEM files: the certificate's common name, the namespace telling one namespace's
# from another's (docs/mongot-envoy-mtls-fresh-install-runbook.md, Step 1). The public name cannot be derived from
# the namespace: it is the one --hostname gives. Each may be set in the environment, with the tokens {search}, {ns}
# and {hostname}; MONGOT_PEM, ENVOY_PEM and ROUTE_PEM name one role's file by its path.
[[ -n "${MONGOT_PEM_NAME:-}" ]] || MONGOT_PEM_NAME='{search}-search-0-svc.{ns}.svc.cluster.local.pem'
[[ -n "${ENVOY_PEM_NAME:-}" ]]  || ENVOY_PEM_NAME='{search}-search-0-proxy-svc.{ns}.svc.cluster.local.pem'
[[ -n "${ROUTE_PEM_NAME:-}" ]]  || ROUTE_PEM_NAME='{hostname}.pem'
ME="$(basename "$0")"

# STEP names the step of --all that is running, so that a refusal says where --all stopped. die says it with its
# reason; cleanup says it for a step ended otherwise (oc refusing the create, a full disk).
die()  { printf '%s: %s%s\n' "${ME}" "${STEP:+--all stopped at ${STEP}: }" "$*" >&2; STEP=""; exit 1; }
say()  { printf '%s\n' "$*"; }
usage() { sed -n '2,/^set +x/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------------------------------- arguments
ACTION="" MODE="" NS_FLAG="" NS_ARG="" PEM="" HOSTNAME_WANTED="" USERNAME=mongotuser PASSIN_FILE="" PASSWORD_FILE=""
SOURCE_HOST="" REPLACE=no YES=no CHECK=no ALL=no STEP=""
ROUTE_REFERENCE="" ROUTE_PRINT=""
# The PEM of each role, and how it was found: named on the command line, by its file name, or by its certificate.
# shellcheck disable=SC2034  # read as ${!var}
PEM_MONGOT="" PEM_ENVOY="" PEM_ROUTE="" HOW_MONGOT="" HOW_ENVOY="" HOW_ROUTE=""
TRUST_PEMS=() ROLES=()
action() { [[ -z "${ACTION}" || "${ACTION}" == "$1" ]] || die "one action a run: --${ACTION} and --$1 were both given"; ACTION="$1"; }
value()  { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }
upper()  { tr '[:lower:]' '[:upper:]' <<<"$1"; }
given()  { printf -v "PEM_$(upper "$1")" '%s' "$2"; printf -v "HOW_$(upper "$1")" '%s' "named on the command line"; }
# A PEM is a word that is a file, and not an option: a file called "--dry-run" is written ./--dry-run.
pem_word() { [[ "$1" != -* && -f "$1" ]]; }
ns_flag()  { [[ -z "${NS_FLAG}" || "${NS_FLAG}" == "$1" ]] || die "two namespaces were given: ${NS_FLAG} and $1"; NS_FLAG="$1"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   CHECK=yes ;;
    --all)     ALL=yes ;;
    # The next word is the role's PEM only when it is a file: without one, the script finds the PEM itself.
    --mongot|--envoy|--route)
               if [[ "${CHECK}" == yes || "${ALL}" == yes ]]; then
                 ROLES+=("${1#--}"); [[ $# -lt 2 ]] || ! pem_word "$2" || { given "${1#--}" "$2"; shift; }
               else
                 action "${1#--}"; [[ $# -lt 2 ]] || ! pem_word "$2" || { PEM="$2"; shift; }
               fi ;;
    --route-reference) value "$@"; ROUTE_REFERENCE="$2"; shift ;;
    --trustca) action trustca
               while [[ $# -ge 2 ]] && pem_word "$2"; do TRUST_PEMS+=("$2"); shift; done ;;
    --dbcred)  action dbcred ;;
    --clean)   action clean ;;
    --dry-run|--apply) [[ -z "${MODE}" || "${MODE}" == "${1#--}" ]] || die "--dry-run and --apply were both given"; MODE="${1#--}" ;;
    --target-namespace) value "$@"; ns_flag "$2"; shift ;;
    --target-namespace=*) value --target-namespace "${1#*=}"; ns_flag "${1#*=}" ;;
    --hostname)      value "$@"; HOSTNAME_WANTED="$2"; shift ;;
    --username)      value "$@"; USERNAME="$2"; shift ;;
    --passin-file)   value "$@"; PASSIN_FILE="$2"; shift ;;
    --password-file) value "$@"; PASSWORD_FILE="$2"; shift ;;
    --check-source)  value "$@"; SOURCE_HOST="$2"; shift ;;
    --replace) REPLACE=yes ;;
    --yes)     YES=yes ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown argument $1 (--help lists them)" ;;
    # A plain word is the namespace; a file there would be a PEM given no role. An empty word is what "$x" gives
    # when x is unset: refused, as before (--mongot "" needed a value), and never read as "find the PEM".
    *) [[ -n "$1" ]] || die "an empty argument (an unset variable?): name the namespace, or the PEM after its option"
       [[ ! -f "$1" ]] || die "which role is $1? --mongot, --envoy, --route or --trustca"
       [[ -z "${NS_ARG}" || "${NS_ARG}" == "$1" ]] || die "two namespaces were given: ${NS_ARG} and $1"
       NS_ARG="$1" ;;
  esac
  shift
done
[[ "${CHECK}" == no || "${ALL}" == no ]] || die "--check and --all were both given"
# --check and --all may come after the PEMs they are to use: "--mongot x.pem --check".
if [[ "${CHECK}" == yes || "${ALL}" == yes ]]; then
  case "${ACTION}" in
    mongot|envoy|route) ROLES+=("${ACTION}"); [[ -z "${PEM}" ]] || given "${ACTION}" "${PEM}"; PEM="" ;;
    "") ;; *) die "--$([[ "${CHECK}" == yes ]] && echo check || echo all) goes with --mongot, --envoy and --route only" ;;
  esac
  if [[ "${CHECK}" == yes ]]; then ACTION=check; else ACTION=all; fi
elif [[ -n "${PEM}" ]]; then
  given "${ACTION}" "${PEM}"
fi
# --check with no role named looks at all three.
[[ -z "${ROUTE_REFERENCE}" || "${ACTION}" == envoy || "${ACTION}" == all \
   || ( "${ACTION}" == check && ( ${#ROLES[@]} -eq 0 || " ${ROLES[*]+"${ROLES[*]}"} " == *" envoy "* ) ) ]] \
  || die "--route-reference goes with --envoy only"
[[ -n "${ACTION}" ]] || { usage >&2; exit 2; }
# Both go into an annotation of the file, on one line: a newline in either would give YAML that oc reads otherwise.
[[ "${USERNAME}${HOSTNAME_WANTED}" != *[[:cntrl:]]* ]] || die "--username and --hostname take no control character (a newline is one)"

# ---------------------------------------------------------------------------------------------------- namespace
# Hard rule: the namespace is named by the caller, on the command line or in TargetNamespace. Nothing is assumed, and
# the project `oc` happens to be on is never used. Two names that differ are refused, whichever two they are.
NAME_RE='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
# A plain word that is not a name is most likely a PEM path mistyped: said before any disagreement with the others.
[[ -z "${NS_ARG}" || ( "${NS_ARG}" =~ ${NAME_RE} && ${#NS_ARG} -le 63 ) ]] \
  || die "'${NS_ARG}' is not a namespace name (lower-case letters, digits and '-'), nor a file here"
NS="${NS_ARG:-${NS_FLAG:-${TargetNamespace:-}}}"
[[ -n "${NS}" ]] || die "no namespace: export TargetNamespace=<namespace>, pass --target-namespace <namespace>, or name it after the action (--check <namespace>)"
[[ -z "${NS_FLAG}" || -z "${TargetNamespace:-}" || "${NS_FLAG}" == "${TargetNamespace}" ]] \
  || die "--target-namespace says ${NS_FLAG} and TargetNamespace says ${TargetNamespace}: which one?"
[[ -z "${NS_ARG}" || -z "${TargetNamespace:-}" || "${NS_ARG}" == "${TargetNamespace}" ]] \
  || die "the command line says ${NS_ARG} and TargetNamespace says ${TargetNamespace}: which one?"
[[ -z "${NS_ARG}" || -z "${NS_FLAG}" || "${NS_ARG}" == "${NS_FLAG}" ]] \
  || die "the command line says ${NS_ARG} and --target-namespace says ${NS_FLAG}: which one?"
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
  local rc=$?
  trap '' HUP INT QUIT TERM         # the tidying is not stopped half way (bash hangs up its own group a second time)
  [[ -z "${STEP}" || ${rc} -eq 0 ]] \
    || printf '%s: --all stopped at %s (exit status %s); what the steps before it made is kept\n' "${ME}" "${STEP}" "${rc}" >&2
  [[ -z "${TTY_STATE}" ]] || stty "${TTY_STATE}" < /dev/tty 2>/dev/null || true       # stopped while asking a secret
  [[ -z "${WORK}" ]] || rm -rf "${WORK}"
  [[ -z "${PARTIAL}" ]] || rm -f "${PARTIAL}"                 # this run's own, in a folder that passed need_folder
}
trap cleanup EXIT
# Without these two the EXIT trap is not run: bash 5 skips it when a hangup arrives inside $(...), as when the
# terminal is closed at the passphrase prompt, and bash 3.2 dies of SIGQUIT (Ctrl-\) where bash 5 ignores it.
trap 'exit 129' HUP
trap 'exit 131' QUIT
# --all runs one action after another: each starts from a work directory of its own, the last one's removed.
workdir() { [[ -z "${WORK}" ]] || rm -rf "${WORK}"; WORK="$(mktemp -d "${TMPDIR:-/tmp}/mdbs-prereq.XXXXXX")"; }

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
# Match OpenSSL 3 for a self-issued root of version 3: it refuses one whose basic constraints say CA:FALSE, and one
# with no basic constraints that has neither a key usage with Certificate Sign nor a Netscape CA type ("invalid CA
# certificate", error 79), where LibreSSL takes most of them. Such a root is refused here on every build, so that
# one PEM has one answer. A version 1 root has no extensions at all, and every build takes it.
root_problem() {  # $1 = a CA certificate; prints why it cannot be a root, or nothing
  local bc ku
  [[ "$(subject_of "$1")" == "$(issuer_of "$1")" ]] || return 0
  [[ "$("${OPENSSL}" x509 -in "$1" -noout -text | awk '/^ *Version:/ {print $2; exit}')" == 3 ]] || return 0
  bc="$(extension "$1" 'X509v3 Basic Constraints')" ku="$(extension "$1" 'X509v3 Key Usage')"
  [[ "${bc}" != CA:TRUE* ]] || return 0
  [[ -n "${bc}" || "${ku}" != *"Certificate Sign"* ]] || return 0
  [[ -n "${bc}${ku}" || "$(extension "$1" 'Netscape Cert Type')" != *" CA"* ]] || return 0
  say "the root certificate $(subject_of "$1") is version 3 and its basic constraints do not say CA:TRUE, with either explicit non-CA constraints or no Certificate Sign key usage: the script refuses it with every openssl build. Ask its issuer for the root with basicConstraints CA:TRUE"
}
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
  local f print seen why chain=()
  REST=() PATH_UP=()
  seen=" $(print_of "${LEAF}") "
  for f in "${CERT_FILES[@]}"; do
    [[ "${f}" == "${LEAF}" ]] && continue
    print="$(print_of "${f}")"
    case "${seen}" in *" ${print} "*) continue ;; esac                       # the same certificate again: once
    seen="${seen}${print} "
    is_ca "${f}" || die "$(subject_of "${f}") is neither the certificate of this key nor a CA: one leaf to a PEM"
    why="$(root_problem "${f}")"; [[ -z "${why}" ]] || die "${why}"
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
        say "it names mongot's own service: this is the mongot PEM"; return
      fi
      if may "${leaf}" server && [[ -z "${ROUTE_PRINT}" ]]; then
        say "a certificate allowing both server and client authentication, or with no EKU, cannot be distinguished from the public certificate: name the public PEM with --route-reference <pem>"
      elif [[ -n "${ROUTE_PRINT}" && "$(print_of "${leaf}")" == "${ROUTE_PRINT}" ]]; then
        say "this is the public certificate named by --route-reference: give --envoy its own client PEM"
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
route_reference() {
  [[ -n "${ROUTE_REFERENCE}" ]] || return 0
  local f leaf="" problem
  read_pem "${ROUTE_REFERENCE}"
  for f in ${CERT_FILES[@]+"${CERT_FILES[@]}"}; do
    is_ca "${f}" && continue
    [[ -z "${leaf}" ]] || die "--route-reference ${ROUTE_REFERENCE} must hold exactly one leaf certificate"
    leaf="${f}"
  done
  [[ -n "${leaf}" ]] || die "--route-reference ${ROUTE_REFERENCE} holds no leaf certificate"
  # In a subshell, so that a refusal of the chain says it is the reference's and not the PEM of the role.
  problem="$( (STEP=""; sort_chain "${leaf}"; verify_chain) 2>&1 >/dev/null )" \
    || die "--route-reference ${ROUTE_REFERENCE}: ${problem#"${ME}: "}"
  problem="$(fits_role route "${leaf}")"
  [[ -z "${problem}" ]] || die "--route-reference ${ROUTE_REFERENCE}: ${problem}"
  ROUTE_PRINT="$(print_of "${leaf}")"
}
warn_if_soon() { "${OPENSSL}" x509 -in "$1" -noout -checkend 2592000 >/dev/null 2>&1 || say "WARNING: it expires within 30 days ($(expiry_of "$1"))" >&2; }

# ---------------------------------------------------------------------------------------------------- which PEM
# A role's PEM, when none is named on the command line: the file of the role's name (MONGOT_PEM_NAME and the others,
# or MONGOT_PEM and the others by path) in ./<ns>/ (when it holds no PEM, here), else the one PEM whose certificate
# fits the role.
# Only certificates are read, which are plaintext: no key is opened and no passphrase asked until the PEM is shown.
CAND=() CAND_LEAF=() FIT_MONGOT=() FIT_ENVOY=() FIT_ROUTE=() DISCOVERED=no SETTLED=no ENVOY_READY=no WHY="" REFERENCE_FOUND=""
first_leaf() {  # after read_pem: the first certificate that is not a CA's
  local f
  for f in ${CERT_FILES[@]+"${CERT_FILES[@]}"}; do is_ca "${f}" || { say "${f}"; return 0; }; done
  return 1
}
# In a subshell, so that a file read_pem refuses is reported and does not end the run.
leaf_into() {  # $1 = pem, $2 = the file its leaf is copied to; prints why it has none, or nothing
  local said
  said="$( (STEP=""; read_pem "$1"; f="$(first_leaf)" || { say "it holds no leaf certificate"; exit 0; }; cp "${f}" "$2") 2>&1 )" || true
  [[ -z "${said}" ]] || say "${said#"${ME}: "}"
}
folder_has_pem() { local f; for f in "${NS}"/*.pem; do [[ ! -f "${f}" ]] || return 0; done; return 1; }
fit_at() {  # $1 = role, $2 = a candidate's index: why it does not fit the role, or nothing
  case "$1" in mongot) say "${FIT_MONGOT[$2]}" ;; envoy) say "${FIT_ENVOY[$2]}" ;; route) say "${FIT_ROUTE[$2]}" ;; esac
}
roles_of() {  # $1 = a candidate's index: the roles it fits
  local r out=""
  for r in mongot envoy route; do [[ -n "$(fit_at "${r}" "$1")" ]] || out="${out} ${r}"; done
  say "${out# }"
}
# Once: the candidates are ./<ns>/*.pem, or ./*.pem when the folder has none; each with its leaf and the roles it
# fits. Envoy's fit depends on the public certificate: until settle_reference has it, it is left for later.
discover_pems() {
  [[ "${DISCOVERED}" == no ]] || return 0
  DISCOVERED=yes
  local f i=0 why
  for f in "${NS}"/*.pem; do [[ ! -f "${f}" ]] || CAND+=("${f}"); done
  if [[ ${#CAND[@]} -eq 0 ]]; then for f in ./*.pem; do [[ ! -f "${f}" ]] || CAND+=("${f}"); done; fi
  for f in ${CAND[@]+"${CAND[@]}"}; do
    why="$(leaf_into "${f}" "${WORK}/candidate-${i}.crt")"
    if [[ -n "${why}" ]]; then
      CAND_LEAF+=(""); FIT_MONGOT+=("${why}"); FIT_ENVOY+=("${why}"); FIT_ROUTE+=("${why}")
    else
      CAND_LEAF+=("${WORK}/candidate-${i}.crt"); FIT_ENVOY+=("not looked at yet")
      [[ "${ENVOY_READY}" == no ]] || FIT_ENVOY[i]="$(fits_role envoy "${WORK}/candidate-${i}.crt")"
      FIT_MONGOT+=("$(fits_role mongot "${WORK}/candidate-${i}.crt")"); FIT_ROUTE+=("$(fits_role route "${WORK}/candidate-${i}.crt")")
    fi
    i=$((i + 1))
  done
}
# Envoy's PEM is told from the public one by the public one's fingerprint (fits_role). With no --route-reference, the
# route PEM found stands for it when it passes the reference's checks; else Envoy's is judged as with no reference.
settle_reference() {
  [[ "${SETTLED}" == no ]] || return 0
  SETTLED=yes
  local i=0
  if [[ -z "${ROUTE_REFERENCE}" ]] && pick route && ( STEP=""; ROUTE_REFERENCE="${PEM_ROUTE}"; route_reference ) >/dev/null 2>&1; then
    ROUTE_REFERENCE="${PEM_ROUTE}" REFERENCE_FOUND="${PEM_ROUTE}"
  fi
  route_reference
  ENVOY_READY=yes                                             # for candidates read from now on, and those read so far
  while [[ ${i} -lt ${#CAND[@]} ]]; do
    [[ -z "${CAND_LEAF[$i]}" ]] || FIT_ENVOY[i]="$(fits_role envoy "${CAND_LEAF[$i]}")"
    i=$((i + 1))
  done
}
pick() {  # $1 = role: sets PEM_<ROLE> and HOW_<ROLE>, or WHY and returns 1
  local role="$1" up var name="" file="" how="" why i n=0 fitting="" others="" fits where other
  up="$(upper "${role}")"; var="PEM_${up}"; WHY=""
  [[ -z "${!var}" ]] || return 0
  [[ "${role}" == route ]] || settle_reference
  var="${up}_PEM"
  if [[ -n "${!var:-}" ]]; then
    [[ -f "${!var}" ]] || { WHY="${var} names ${!var}, and there is no such file"; return 1; }
    file="${!var}" how="${var}"
  else
    var="${up}_PEM_NAME"; name="${!var}"
    name="${name//\{search\}/${SEARCH}}"; name="${name//\{ns\}/${NS}}"
    if [[ "${name}" == *"{hostname}"* ]]; then                 # no --hostname: the public name is not known
      if [[ -n "${HOSTNAME_WANTED}" ]]; then name="${name//\{hostname\}/${HOSTNAME_WANTED}}"; else name=""; fi
    fi
    # Here only when the folder holds no PEM, as for a PEM found by its certificate: a file of the name left here
    # (last year's) is never taken over the folder's.
    if [[ -n "${name}" && -f "${NS}/${name}" ]]; then file="${NS}/${name}"
    elif [[ -n "${name}" && -f "${name}" ]] && ! folder_has_pem; then file="${name}"; fi
    how="its name (${var})"
  fi
  if [[ -n "${file}" ]]; then                                  # a file found by its name must still fit its role
    why="$(leaf_into "${file}" "${WORK}/named.crt")"
    [[ -n "${why}" ]] || why="$(fits_role "${role}" "${WORK}/named.crt")"
    [[ -z "${why}" ]] || { WHY="${file}, found by ${how}, is not the ${role} certificate for ${NS}: ${why}"; return 1; }
    if [[ "${how}" == "its name ("* ]]; then                   # a name is no choice of role: one path given is
      fits=""
      for other in mongot envoy route; do [[ -n "$(fits_role "${other}" "${WORK}/named.crt")" ]] || fits="${fits} ${other}"; done
      fits="${fits# }"
      [[ "${fits}" != *" "* ]] || { WHY="${file}: it fits ${fits// / and }, and is given to neither: name it with the option of its role"; return 1; }
    fi
    printf -v "PEM_${up}" '%s' "${file}"; printf -v "HOW_${up}" '%s' "found by ${how}"; return 0
  fi
  discover_pems
  if [[ ${#CAND[@]} -eq 0 ]]; then
    WHY="no PEM for the ${role} role: none named with --${role} <pem>, ${name:+no ${name}, }and no *.pem in ${NS}/ or in this directory"
    return 1
  fi
  where="${NS}/"; [[ "${CAND[0]}" == "${NS}/"* ]] || where="this directory"
  i=0
  while [[ ${i} -lt ${#CAND[@]} ]]; do
    why="$(fit_at "${role}" "${i}")"
    if [[ -n "${why}" ]]; then others="${others}; ${CAND[$i]}: ${why}"
    else
      fits="$(roles_of "${i}")"
      if [[ "${fits}" == *" "* ]]; then                        # reported, not assigned
        others="${others}; ${CAND[$i]}: it fits ${fits// / and }, and is given to neither: name it with the option of its role"
      else n=$((n + 1)); fitting="${fitting}, ${CAND[$i]}"; file="${CAND[$i]}"; fi
    fi
    i=$((i + 1))
  done
  case "${n}" in
    1) printf -v "PEM_${up}" '%s' "${file}"; printf -v "HOW_${up}" '%s' "found by its certificate"; return 0 ;;
    0) WHY="no PEM fits the ${role} role in ${where} (${others#; })" ;;
    2) WHY="two PEMs fit the ${role} role: ${fitting#, }: name one with --${role} <pem>" ;;
    *) WHY="${n} PEMs fit the ${role} role: ${fitting#, }: name one with --${role} <pem>" ;;
  esac
  return 1
}
say_reference() { [[ -z "${REFERENCE_FOUND}" ]] || say "  the route PEM ${REFERENCE_FOUND} is Envoy's --route-reference: Envoy's PEM is told from it"; }
resolve() {  # $@ = roles: the PEM of each, or a refusal; then what was chosen, before any passphrase is asked
  local role up file how
  for role in "$@"; do pick "${role}" || die "${WHY}"; done
  say "PEM files for ${NS}"
  for role in "$@"; do
    up="PEM_$(upper "${role}")"; file="${!up}"; up="HOW_$(upper "${role}")"; how="${!up}"
    say "  $(printf '%-7s' "${role}") ${file}, ${how}"
    [[ -n "$(leaf_into "${file}" "${WORK}/shown.crt")" ]] && continue
    say "          leaf   $(subject_of "${WORK}/shown.crt")"
    say "          names  $(dns_names "${WORK}/shown.crt" | tr '\n' ' ')"
  done
}

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
  local role="$1" name="$2" file="$2.secret.yaml" f pub leaf="" problem other host="" var
  [[ -n "${MODE}" ]] || die "--${role} needs --dry-run or --apply"
  need_folder; workdir; PARTIAL="$(partial_of "${file}")"
  var="PEM_$(upper "${role}")"
  PEM="${!var}"; [[ -n "${PEM}" ]] || { resolve "${role}"; PEM="${!var}"; }
  [[ "${role}" != envoy ]] || { settle_reference; say_reference; }
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
  local file="${TRUST_CM}.configmap.yaml" pem f print seen="" count=0 other said why
  [[ -n "${MODE}" ]] || die "--trustca needs --dry-run or --apply"
  need_folder; workdir; PARTIAL="$(partial_of "${file}")"; : > "${WORK}/bundle.crt"
  # With no PEM named, the CA certificates of the three PEMs of the namespace.
  [[ ${#TRUST_PEMS[@]} -gt 0 ]] || { resolve mongot envoy route; TRUST_PEMS=("${PEM_MONGOT}" "${PEM_ENVOY}" "${PEM_ROUTE}"); }
  for pem in "${TRUST_PEMS[@]}"; do
    read_pem "${pem}"                                        # the key in it, if any, is not opened
    for f in ${CERT_FILES[@]+"${CERT_FILES[@]}"}; do
      is_ca "${f}" || continue
      why="$(root_problem "${f}")"; [[ -z "${why}" ]] || die "${pem}: ${why}"
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
  for f in ${CERT_FILES[@]+"${CERT_FILES[@]}"}; do
    problem="$(root_problem "${f}")"; [[ -z "${problem}" ]] || { say "    PROBLEM: ${problem}"; PROBLEMS=$((PROBLEMS + 1)); }
  done
  first="$(first_leaf)" || true
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
  # The roles named, or all three, each PEM named or found as an action would find it.
  local roles=(mongot envoy route) role var how whys="" nothing=0
  [[ ${#ROLES[@]} -eq 0 ]] || roles=("${ROLES[@]}")
  [[ " ${roles[*]} " != *" envoy "* ]] || { settle_reference; say_reference; }
  for role in "${roles[@]}"; do
    if pick "${role}"; then
      var="PEM_$(upper "${role}")"; f="${!var}"; var="HOW_$(upper "${role}")"; how="${!var}"
      [[ "${how}" == "named on the command line" ]] || say "  ${role}: ${f}, ${how}"
      look_at "${role}" "${f}"
    else
      [[ "${WHY}" != "no PEM for the "* ]] || nothing=$((nothing + 1))
      whys="${whys}${WHY}"$'\n'
    fi
  done
  if [[ ${#ROLES[@]} -eq 0 && ${nothing} -eq 3 ]]; then
    say "  none in ${NS}/ or here, and none named with --mongot, --envoy or --route"
  else
    while IFS= read -r p; do [[ -z "${p}" ]] || { say "    PROBLEM: ${p}"; PROBLEMS=$((PROBLEMS + 1)); }; done <<<"${whys}"
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

# The five actions in order, each as it runs on its own, with the PEMs found once and shown before the first.
step() { STEP="--$1 (step $2 of 5)"; say; say "step $2 of 5: --$1"; }
all() {
  [[ -n "${MODE}" ]] || die "--all needs --dry-run or --apply"
  need_folder; workdir
  resolve mongot envoy route
  TRUST_PEMS=("${PEM_MONGOT}" "${PEM_ENVOY}" "${PEM_ROUTE}")
  step trustca 1; trust_bundle
  step mongot 2;  tls_secret mongot "${MONGOT_SECRET}"
  step envoy 3;   tls_secret envoy  "${ENVOY_SECRET}"
  step route 4;   tls_secret route  "${LB_SECRET}"
  step dbcred 5;  db_password
  STEP=""
  say; say "the five objects for ${NS} are made$([[ "${MODE}" == apply ]] || echo ' as files: a dry run')"
}

case "${ACTION}" in
  check)   check ;;
  all)     all ;;
  mongot)  tls_secret mongot "${MONGOT_SECRET}" ;;
  envoy)   tls_secret envoy  "${ENVOY_SECRET}" ;;
  route)   tls_secret route  "${LB_SECRET}" ;;
  trustca) trust_bundle ;;
  dbcred)  db_password ;;
  clean)   clean ;;
esac
