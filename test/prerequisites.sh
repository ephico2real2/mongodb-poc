#!/usr/bin/env bash
# Tests for scripts/generate-mongodbsearch-prerequisites.sh, no cluster needed:  test/prerequisites.sh
# It makes a throwaway CA (a root and an intermediate) and password-protected PEMs in the company's layout
# (encrypted key, CA bundle, leaf), all in a temporary directory, and a stand-in `oc` for --apply.
# OPENSSL names the openssl to use (OpenSSL 3 or LibreSSL) and BASH_UNDER_TEST the bash that runs the script.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SCRIPT="${PWD}/scripts/generate-mongodbsearch-prerequisites.sh"
export OPENSSL="${OPENSSL:-openssl}"
SH="${BASH_UNDER_TEST:-bash}"
NS=vectordb-test
fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/prereq-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
pki="${work}/pki"; here="${work}/here"; mkdir -p "${pki}" "${here}" "${work}/bin"
echo "testing with $("${OPENSSL}" version) and $("${SH}" --version | head -1)"

# ------------------------------------------------------------------------------------------------ a throwaway CA
# Every subject comes from -subj. (With "prompt = no" and a name in the file, LibreSSL takes the file's and every
# certificate comes out with the same subject.)
cat > "${pki}/pki.cnf" <<EOF
[req]
distinguished_name = dn
[dn]
[root]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
[inter]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
[mongot]
basicConstraints = CA:FALSE
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:mongot-search-0-svc.${NS}.svc.cluster.local
[envoy]
basicConstraints = CA:FALSE
extendedKeyUsage = clientAuth
subjectAltName = DNS:mongot-search-0-proxy-svc.${NS}.svc.cluster.local
[lb]
basicConstraints = CA:FALSE
extendedKeyUsage = serverAuth
subjectAltName = DNS:Search-QA.example.test
[lbtwo]
basicConstraints = CA:FALSE
extendedKeyUsage = serverAuth
subjectAltName = DNS:search-qa.example.test, DNS:search-b.example.test, DNS:*.apps.example.test
[elsewhere]
basicConstraints = CA:FALSE
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:mongot-search-0-svc.another-ns.svc.cluster.local
[serveronly]
basicConstraints = CA:FALSE
extendedKeyUsage = serverAuth
subjectAltName = DNS:mongot-search-0-svc.${NS}.svc.cluster.local
[noname]
basicConstraints = CA:FALSE
extendedKeyUsage = clientAuth
[both]
basicConstraints = CA:FALSE
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:mongot-search-0-svc.${NS}.svc.cluster.local, DNS:mongot-search-0-proxy-svc.${NS}.svc.cluster.local
EOF
printf 'the key passphrase\n' > "${pki}/pass"; printf 'another passphrase\n' > "${pki}/wrong"
(
  cd "${pki}" || exit 1
  q() { "$@" >/dev/null 2>&1; }
  q "${OPENSSL}" genrsa -out root.key 2048
  q "${OPENSSL}" req -new -x509 -key root.key -out root.crt -days 3650 -subj "/O=Example Test/CN=Example Test Root CA" -config pki.cnf -extensions root
  q "${OPENSSL}" genrsa -out inter.key 2048
  q "${OPENSSL}" req -new -key inter.key -out inter.csr -subj "/O=Example Test/CN=Example Test Issuing CA" -config pki.cnf
  q "${OPENSSL}" x509 -req -in inter.csr -CA root.crt -CAkey root.key -CAcreateserial -out inter.crt -days 1825 -extfile pki.cnf -extensions inter
  # A second, unrelated CA, for a bundle that does not hold the leaf's issuer.
  q "${OPENSSL}" genrsa -out other.key 2048
  q "${OPENSSL}" req -new -x509 -key other.key -out other.crt -days 3650 -subj "/O=Other/CN=Other Root CA" -config pki.cnf -extensions root
  leaf() {  # leaf <name> <section> <cn> [days]: <name>.key (no password), <name>.crt
    q "${OPENSSL}" genrsa -out "$1.key" 2048
    q "${OPENSSL}" req -new -key "$1.key" -out "$1.csr" -subj "/O=Example Test/CN=$3" -config pki.cnf
    q "${OPENSSL}" x509 -req -in "$1.csr" -CA inter.crt -CAkey inter.key -CAcreateserial -out "$1.crt" -days "${4:-365}" -extfile pki.cnf -extensions "$2"
  }
  leaf mongot mongot "mongot-search-0-svc.${NS}.svc.cluster.local"
  leaf envoy envoy "mongot-search-0-proxy-svc.${NS}.svc.cluster.local"
  leaf lb lb "search-qa.example.test"
  leaf lbtwo lbtwo "search-qa.example.test"
  leaf elsewhere elsewhere "mongot-search-0-svc.another-ns.svc.cluster.local"
  leaf serveronly serveronly "mongot-search-0-svc.${NS}.svc.cluster.local"
  leaf noname noname "an envoy client with no name"
  leaf soon mongot "mongot-search-0-svc.${NS}.svc.cluster.local" 10
  leaf both both "one certificate that would fit mongot and Envoy"
  for n in mongot envoy lb lbtwo elsewhere serveronly noname soon both; do
    q "${OPENSSL}" pkcs8 -topk8 -v2 aes-256-cbc -in "$n.key" -out "$n.enc" -passout file:pass
    cat "$n.enc" inter.crt root.crt "$n.crt" > "$n.pem"                  # the company's layout
  done
  # Other shapes of the same mongot material.
  "${OPENSSL}" rsa -in mongot.key -aes256 -traditional -passout file:pass -out mongot.trad >/dev/null 2>&1 \
    || "${OPENSSL}" rsa -in mongot.key -aes256 -passout file:pass -out mongot.trad >/dev/null 2>&1
  cat mongot.trad inter.crt root.crt mongot.crt > mongot-traditional.pem
  cat mongot.crt root.crt inter.crt mongot.enc > mongot-reversed.pem      # leaf first, chain upside down, key last
  sed $'s/$/\r/' mongot.pem > mongot-crlf.pem
  q "${OPENSSL}" pkcs8 -topk8 -nocrypt -in mongot.key -out mongot.plain
  cat mongot.plain inter.crt root.crt mongot.crt > mongot-nopassword.pem
  cat mongot.enc envoy.enc inter.crt root.crt mongot.crt > two-keys.pem
  cat mongot.enc inter.crt root.crt mongot.crt mongot.csr > with-csr.pem
  cat mongot.enc inter.crt mongot.crt > no-root.pem
  cat mongot.enc other.crt mongot.crt > wrong-ca.pem
  cat envoy.enc inter.crt root.crt mongot.crt > key-of-another.pem
  # An EC key, as "ecparam -genkey" writes it: an EC PARAMETERS block, then the key.
  q "${OPENSSL}" ecparam -name prime256v1 -genkey -out ec.key
  q "${OPENSSL}" req -new -key ec.key -out ec.csr -subj "/O=Example Test/CN=mongot-search-0-svc.${NS}.svc.cluster.local" -config pki.cnf
  q "${OPENSSL}" x509 -req -in ec.csr -CA inter.crt -CAkey inter.key -CAcreateserial -out ec.crt -days 365 -extfile pki.cnf -extensions mongot
  q "${OPENSSL}" ec -in ec.key -aes256 -passout file:pass -out ec.enc
  { sed -n '/BEGIN EC PARAMETERS/,/END EC PARAMETERS/p' ec.key; cat ec.enc inter.crt root.crt ec.crt; } > mongot-ec.pem
)
[[ -s "${pki}/mongot.pem" && -s "${pki}/mongot-ec.pem" ]] || { echo "the test CA could not be made"; exit 1; }

# ------------------------------------------------------------------------------------------------ running it
# A stand-in oc: it answers what the script asks and writes down every call.
cat > "${work}/bin/oc" <<'EOF'
#!/bin/bash
echo "$*" >> "${OC_LOG}"
case "$1 ${2:-}" in
  "whoami ")              echo tester ;;
  "whoami --show-server") echo https://api.lab.test:6443 ;;
  "get namespace")        [[ "$3" == "${OC_NAMESPACE}" ]] ;;
  "get secret"|"get configmap")
    [[ -f "${OC_STATE}/$3" ]] || exit 1
    case "$*" in *go-template*) sed -n '/^data:/,$p' "${OC_STATE}/$3" | grep -E '^  [a-z.]+: ' | sed -e 's/^  //' -e 's/:.*//' | sort | tr '\n' ' ' ;; esac ;;
  "create -f")            [[ ! -f "${OC_STATE}/$(sed -n 's/^  name: //p' "$3" | head -1)" ]] || { echo AlreadyExists >&2; exit 1; }
                          cp "$3" "${OC_STATE}/$(sed -n 's/^  name: //p' "$3" | head -1)"; echo created ;;
  "replace -f")           cp "$3" "${OC_STATE}/$(sed -n 's/^  name: //p' "$3" | head -1)"; echo replaced ;;
  *) echo "the stand-in oc does not know: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "${work}/bin/oc"
export OC_LOG="${work}/oc.log" OC_STATE="${work}/cluster" OC_NAMESPACE="${NS}"
mkdir -p "${OC_STATE}"

# Every run is cut off from the terminal, so that a test started by a person never stops to ask them something
# and "no terminal" is the same here as in CI. stdout and stderr go to ${work}/out and ${work}/err.
run() {
  ( cd "${here}" && PATH="${work}/bin:${PATH}" python3 -c 'import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp(sys.argv[1], sys.argv[1:])' "${SH}" "${SCRIPT}" "$@" ) >"${work}/out" 2>"${work}/err" </dev/null
}
said() { cat "${work}/out" "${work}/err"; }
refused() {  # refused <what> <words of the message> -- <arguments>: it fails, says so, and writes nothing
  local what="$1" words="$2" before; shift 3
  before="$(ls -A "${here}/${NS}" 2>/dev/null | sort)"
  if run "$@"; then bad "${what}: it was not refused"; return; fi
  grep -qF -- "${words}" "${work}/err" || { bad "${what}: refused, but said: $(head -2 "${work}/err" | tr '\n' ' ')"; return; }
  [[ "$(ls -A "${here}/${NS}" 2>/dev/null | sort)" == "${before}" ]] || { bad "${what}: refused, but the folder changed"; return; }
  [[ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'mdbs-prereq.*' 2>/dev/null)" ]] || { bad "${what}: a temporary directory was left"; return; }
  ok "refused: ${what}"
}
field() { sed -n "s/^  $(sed 's/\./\\./g' <<<"$2"): //p" "$1" | head -1 | "${OPENSSL}" base64 -d -A; }
P=(--passin-file "${pki}/pass")
export TargetNamespace="${NS}"

# ------------------------------------------------------------------------------------------------ the namespace
( unset TargetNamespace; refused "no namespace at all" "no namespace: export TargetNamespace" -- --check )
( unset TargetNamespace; refused "no namespace, with an action" "no namespace: export TargetNamespace" -- --mongot "${pki}/mongot.pem" --dry-run "${P[@]}" )
refused "the flag and the variable disagree" "which one?" -- --target-namespace another-ns --check
( export TargetNamespace=../x; refused "a namespace that is a path" "is not a namespace name" -- --check )
refused "the folder is not there" "Create it yourself: mkdir -m 700 ${NS}" -- --mongot "${pki}/mongot.pem" --dry-run "${P[@]}"
run --check; [[ $? -ne 0 ]] && grep -q "mkdir -m 700 ${NS}" "${work}/out" && [[ ! -e "${here}/${NS}" ]] \
  && ok "--check says to create the folder, and does not create it" || bad "--check without the folder: $(said | head -3)"
ln -s "${work}" "${here}/${NS}"
refused "the folder is a link" "must be a real directory" -- --mongot "${pki}/mongot.pem" --dry-run "${P[@]}"
rm "${here}/${NS}"; mkdir -m 755 "${here}/${NS}"
refused "the folder is open to others" "chmod 700 ${NS}" -- --mongot "${pki}/mongot.pem" --dry-run "${P[@]}"
chmod 700 "${here}/${NS}"
( unset TargetNamespace; cd "${here}" && run --target-namespace "${NS}" --check ) && ok "--target-namespace alone names the namespace" || bad "--target-namespace alone: $(said | head -3)"

# ------------------------------------------------------------------------------------------------ refusals
refused "neither --dry-run nor --apply" "needs --dry-run or --apply" -- --mongot "${pki}/mongot.pem" "${P[@]}"
refused "--dry-run and --apply together" "both given" -- --mongot "${pki}/mongot.pem" --dry-run --apply "${P[@]}"
refused "two actions in one run" "one action a run" -- --mongot "${pki}/mongot.pem" --envoy "${pki}/envoy.pem" --dry-run "${P[@]}"
refused "a wrong passphrase" "wrong passphrase" -- --mongot "${pki}/mongot.pem" --dry-run --passin-file "${pki}/wrong"
refused "no terminal and no passphrase file" "no terminal to ask its passphrase on" -- --mongot "${pki}/mongot.pem" --dry-run
refused "two private keys in the PEM" "holds 2 private keys" -- --mongot "${pki}/two-keys.pem" --dry-run "${P[@]}"
refused "a certificate request in the PEM" "does not take: CERTIFICATE REQUEST" -- --mongot "${pki}/with-csr.pem" --dry-run "${P[@]}"
refused "a bundle without its root" "does not verify against the CA certificates" -- --mongot "${pki}/no-root.pem" --dry-run "${P[@]}"
refused "a bundle of another CA" "does not verify against the CA certificates" -- --mongot "${pki}/wrong-ca.pem" --dry-run "${P[@]}"
refused "a key that is not the certificate's" "no certificate in" -- --mongot "${pki}/key-of-another.pem" --dry-run "${P[@]}"
refused "a certificate for another namespace" "a certificate is issued for one namespace" -- --mongot "${pki}/elsewhere.pem" --dry-run "${P[@]}"
refused "the Envoy PEM given to --mongot" "is not the mongot certificate" -- --mongot "${pki}/envoy.pem" --dry-run "${P[@]}"
refused "a server-only certificate given to --mongot" "must allow server and client authentication" -- --mongot "${pki}/serveronly.pem" --dry-run "${P[@]}"
refused "the mongot PEM given to --envoy" "this is the mongot PEM" -- --envoy "${pki}/mongot.pem" --dry-run "${P[@]}"
refused "another namespace's certificate given to --envoy" "a service of another namespace" -- --envoy "${pki}/elsewhere.pem" --dry-run "${P[@]}"
refused "the public certificate given to --envoy" "must allow client authentication" -- --envoy "${pki}/lb.pem" --dry-run "${P[@]}"
refused "the mongot PEM given to --route" "names no public hostname" -- --route "${pki}/mongot.pem" --dry-run "${P[@]}"
refused "the Envoy PEM given to --route" "must allow server authentication" -- --route "${pki}/envoy.pem" --dry-run "${P[@]}"
refused "several hostnames and no --hostname" "say which with --hostname" -- --route "${pki}/lbtwo.pem" --dry-run "${P[@]}"
refused "a --hostname the certificate does not name" "does not name search-z.example.test" -- --route "${pki}/lb.pem" --hostname search-z.example.test --dry-run "${P[@]}"
refused "a file that is not a PEM" "holds no PEM block" -- --mongot "${pki}/pki.cnf" --dry-run "${P[@]}"
# A key whose encryption this build does not have is not called a wrong passphrase. OpenSSL 3 can write the old
# PBE cipher with its legacy provider and cannot read it without; LibreSSL cannot write a key it cannot read.
if "${OPENSSL}" pkcs8 -topk8 -v1 PBE-MD5-DES -provider legacy -provider default -in "${pki}/mongot.key" -out "${pki}/old.enc" -passout "file:${pki}/pass" >/dev/null 2>&1; then
  cat "${pki}/old.enc" "${pki}/inter.crt" "${pki}/root.crt" "${pki}/mongot.crt" > "${pki}/old-cipher.pem"
  refused "a key in a cipher this openssl does not have" "cannot read the key" -- --mongot "${pki}/old-cipher.pem" --dry-run "${P[@]}"
  grep -q "wrong passphrase" "${work}/err" && bad "an unreadable key was called a wrong passphrase"
else
  ok "skipped: this openssl cannot make a key it cannot read"
fi
refused "--trustca with no CA in it" "no CA certificate in" -- --trustca "${pki}/mongot.crt" --dry-run
refused "--dbcred with no terminal and no file" "no terminal to ask the password on" -- --dbcred --dry-run
: > "${work}/empty"
refused "an empty password" "an empty password" -- --dbcred --dry-run --password-file "${work}/empty"

# ------------------------------------------------------------------------------------------------ what it makes
tls_file() {  # tls_file <role flag> <pem> <secret name> <key the leaf was made with> <what>
  local flag="$1" pem="$2" name="$3" key="$4" what="$5" f="${here}/${NS}/$3.secret.yaml" why=""
  shift 5
  run "${flag}" "${pem}" --dry-run "${P[@]}" "$@" || { bad "${what}: $(said | head -3 | tr '\n' ' ')"; return; }
  [[ -f "${f}" ]] || { bad "${what}: no file"; return; }
  [[ "$(ls -l "${f}" | cut -c1-10)" == "-rw-------" ]] || why="${why} mode;"
  grep -qx "kind: Secret" "${f}" && grep -qx "  name: ${name}" "${f}" && grep -qx "  namespace: ${NS}" "${f}" \
    && grep -qx "type: kubernetes.io/tls" "${f}" || why="${why} kind, name, namespace or type;"
  [[ "$(grep -cE '^  (tls\.crt|tls\.key|ca\.crt): ' "${f}")" == 3 ]] || why="${why} the three keys;"
  [[ "$(field "${f}" tls.key | head -1)" == "-----BEGIN PRIVATE KEY-----" ]] || why="${why} the key still has a password;"
  [[ "$(field "${f}" tls.key | "${OPENSSL}" pkey -pubout 2>/dev/null)" == "$("${OPENSSL}" pkey -in "${key}" -pubout 2>/dev/null)" ]] || why="${why} not the key it was given;"
  # tls.crt: the leaf first, then the issuing CA, then the root; ca.crt: the two CAs in that order.
  field "${f}" tls.crt > "${work}/tls.crt"; field "${f}" ca.crt > "${work}/ca.crt"
  [[ "$(awk '/BEGIN CERT/{n++} n==1' "${work}/tls.crt" | "${OPENSSL}" x509 -noout -pubkey)" == "$("${OPENSSL}" pkey -in "${key}" -pubout 2>/dev/null)" ]] || why="${why} the leaf is not first;"
  [[ "$(grep -c 'BEGIN CERTIFICATE' "${work}/tls.crt")" == 3 && "$(grep -c 'BEGIN CERTIFICATE' "${work}/ca.crt")" == 2 ]] || why="${why} the counts;"
  cmp -s "${work}/ca.crt" <(cat "${pki}/inter.crt" "${pki}/root.crt") || why="${why} the chain is not issuing CA then root;"
  [[ -z "$(find "${here}/${NS}" -mindepth 1 ! -name '*.yaml')" ]] || why="${why} something else was left in the folder;"
  grep -q "no cluster was contacted" "${work}/out" && [[ ! -s "${OC_LOG}" ]] || why="${why} oc was called in a dry run;"
  [[ -z "${why}" ]] && ok "${what}" || bad "${what}:${why}"
}
: > "${OC_LOG}"
tls_file --mongot "${pki}/mongot.pem" ent-mongot-search-cert "${pki}/mongot.key" "--mongot makes ent-mongot-search-cert"
tls_file --envoy  "${pki}/envoy.pem"  ent-mongot-search-lb-0-client-cert "${pki}/envoy.key" "--envoy makes ent-mongot-search-lb-0-client-cert"
tls_file --route  "${pki}/lb.pem"     ent-mongot-search-lb-0-cert "${pki}/lb.key" "--route makes ent-mongot-search-lb-0-cert"
grep -q "loadBalancer.externalHostname: search-qa.example.test" "${work}/out" \
  && ok "--route gives the chart its hostname, in lower case" || bad "--route hostname: $(said | head -8 | tr '\n' ' ')"
tls_file --route "${pki}/lbtwo.pem" ent-mongot-search-lb-0-cert "${pki}/lbtwo.key" "--route with --hostname, when the certificate names several" --hostname search-b.example.test
grep -q "loadBalancer.externalHostname: search-b.example.test" "${work}/out" || bad "--hostname was not the one given"
tls_file --route "${pki}/lbtwo.pem" ent-mongot-search-lb-0-cert "${pki}/lbtwo.key" "--hostname under a wildcard name of the certificate" --hostname console.apps.example.test
refused "a --hostname two labels under the wildcard" "does not name a.b.apps.example.test" -- --route "${pki}/lbtwo.pem" --hostname a.b.apps.example.test --dry-run "${P[@]}"
# One certificate that would fit two roles is taken for the first and refused for the second.
run --mongot "${pki}/both.pem" --dry-run "${P[@]}" || bad "a certificate that fits mongot and Envoy, as mongot's: $(said | head -3 | tr '\n' ' ')"
refused "one certificate for two roles" "already in ent-mongot-search-cert.secret.yaml" -- --envoy "${pki}/both.pem" --dry-run "${P[@]}"
# The same material in other shapes gives the same key.
for shape in traditional reversed crlf nopassword; do
  tls_file --mongot "${pki}/mongot-${shape}.pem" ent-mongot-search-cert "${pki}/mongot.key" "a mongot PEM, ${shape}"
done
tls_file --mongot "${pki}/mongot-ec.pem" ent-mongot-search-cert "${pki}/ec.key" "an EC key with its EC PARAMETERS block"
run --mongot "${pki}/soon.pem" --dry-run "${P[@]}" && grep -q "expires within 30 days" "${work}/err" \
  && ok "a certificate that expires in 10 days is made, with a warning" || bad "the expiry warning: $(said | head -3 | tr '\n' ' ')"
run --mongot "${pki}/mongot.pem" --dry-run "${P[@]}"                    # back to the real one for what follows
run --envoy "${pki}/noname.pem" --dry-run "${P[@]}" && ok "an Envoy client certificate with no name is taken (TLS.md, 6.1)" || bad "envoy with no name: $(said | head -3 | tr '\n' ' ')"
run --envoy "${pki}/envoy.pem" --dry-run "${P[@]}"
refused "the mongot certificate again, as Envoy's" "this is the mongot PEM" -- --envoy "${pki}/mongot.pem" --dry-run "${P[@]}"

# The trust bundle: CA certificates only, each once, and every leaf made so far verifies against it.
f="${here}/${NS}/ent-trust-bundle.configmap.yaml"
run --trustca "${pki}/mongot.pem" --trustca "${pki}/lb.pem" --dry-run || bad "--trustca: $(said | head -3 | tr '\n' ' ')"
sed -n 's/^    //p' "${f}" > "${work}/bundle.pem"
grep -qx "kind: ConfigMap" "${f}" && grep -qx "  name: ent-trust-bundle" "${f}" && grep -qx "  namespace: ${NS}" "${f}" \
  && grep -qx "  ca.crt: |" "${f}" && [[ "$(grep -c 'BEGIN CERTIFICATE' "${work}/bundle.pem")" == 2 ]] \
  && ! grep -q 'PRIVATE KEY' "${f}" \
  && "${OPENSSL}" verify -CAfile "${work}/bundle.pem" "${pki}/mongot.crt" "${pki}/envoy.crt" "${pki}/lb.crt" >/dev/null 2>&1 \
  && ok "--trustca makes ent-trust-bundle: the two CAs once each, no key, and the three leaves verify against it" \
  || bad "--trustca content: $(said | head -4 | tr '\n' ' ')"
refused "a trust bundle that a leaf already made does not verify against" "does not verify against this bundle" -- --trustca "${pki}/other.crt" --dry-run

# The database password: byte for byte, with nothing added.
printf '%s\n' ' p\ss "w0rd" ñ $x  ' > "${work}/pw"
f="${here}/${NS}/search-sync-source-password.secret.yaml"
run --dbcred --username syncUser --dry-run --password-file "${work}/pw" || bad "--dbcred: $(said | head -3 | tr '\n' ' ')"
[[ "$(field "${f}" password | od -c)" == "$(printf '%s' ' p\ss "w0rd" ñ $x  ' | od -c)" ]] \
  && grep -qx "  name: search-sync-source-password" "${f}" && grep -qx "type: Opaque" "${f}" \
  && [[ "$(grep -cE '^  [a-z.]+: ' <(sed -n '/^data:/,$p' "${f}"))" == 1 ]] \
  && grep -q "source.username: syncUser" "${work}/out" \
  && ok "--dbcred keeps the password byte for byte (backslash, quotes, spaces at both ends, non-ASCII), adds no newline, and holds only 'password'" \
  || bad "--dbcred content: $(field "${f}" password | od -c | head -2)"
run --dbcred --dry-run --password-file "${work}/pw" && grep -q "source.username: mongotUser" "${work}/out" \
  && ok "--username defaults to mongotUser" || bad "the default user name"

# ------------------------------------------------------------------------------------------------ nothing leaks
secret_bits() {  # the passphrase, the password, and a line from the middle of each decrypted key
  printf '%s\n' "the key passphrase" 'p\ss "w0rd"'
  for k in mongot envoy lb; do "${OPENSSL}" pkey -in "${pki}/$k.key" 2>/dev/null | sed -n '3p'; done
}
leak=""
for a in "--mongot ${pki}/mongot.pem" "--envoy ${pki}/envoy.pem" "--route ${pki}/lb.pem"; do
  # shellcheck disable=SC2086
  ( cd "${here}" && "${SH}" -x "${SCRIPT}" ${a} --dry-run "${P[@]}" ) >"${work}/out" 2>"${work}/err" </dev/null
  while IFS= read -r bit; do grep -qF -- "${bit}" "${work}/out" "${work}/err" && leak="${leak} ${a%% *}"; done < <(secret_bits)
done
( cd "${here}" && "${SH}" -x "${SCRIPT}" --dbcred --dry-run --password-file "${work}/pw" ) >"${work}/out" 2>"${work}/err" </dev/null
while IFS= read -r bit; do grep -qF -- "${bit}" "${work}/out" "${work}/err" && leak="${leak} --dbcred"; done < <(secret_bits)
[[ -z "${leak}" ]] && ok "what it prints, also under bash -x, holds no key, no passphrase and no password" || bad "it printed secret material:${leak}"
[[ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'mdbs-prereq.*' 2>/dev/null)" ]] && ok "no temporary directory is left" || bad "a temporary directory was left"

# ------------------------------------------------------------------------------------------------ --check
run --check --mongot "${pki}/mongot.pem" --envoy "${pki}/envoy.pem" --route "${pki}/lb.pem" \
  && grep -q "fits     --mongot for ${NS}" "${work}/out" && grep -q "fits     --envoy" "${work}/out" && grep -q "fits     --route" "${work}/out" \
  && grep -q "externalHostname: search-b.example.test\|externalHostname: console.apps.example.test\|externalHostname: search-qa.example.test" "${work}/out" \
  && grep -q "namespace: ${NS}" "${work}/out" && grep -q "username: mongotUser" "${work}/out" && grep -q "^0 problem" "${work}/out" \
  && ok "--check reads the three PEMs without their passphrase, lists the files made and prints the chart's values" \
  || bad "--check: $(said | tr '\n' '|' | cut -c1-600)"
run --check --mongot "${pki}/elsewhere.pem"; [[ $? -ne 0 ]] && grep -q "PROBLEM: not the mongot certificate for ${NS}" "${work}/out" \
  && ok "--check fails on a PEM for another namespace, before any passphrase is asked" || bad "--check on a wrong PEM: $(said | head -12 | tr '\n' '|')"

# ------------------------------------------------------------------------------------------------ --apply
: > "${OC_LOG}"; rm -f "${OC_STATE}"/*
refused "--apply with no terminal and no --yes" "pass --yes" -- --mongot "${pki}/mongot.pem" --apply "${P[@]}"
grep -qE '^(create|replace)' "${OC_LOG}" && bad "something was sent to the cluster without the confirmation"
: > "${OC_LOG}"
run --mongot "${pki}/mongot.pem" --apply --yes "${P[@]}" && grep -q "^create -f .*ent-mongot-search-cert.secret.yaml -n ${NS}$" "${OC_LOG}" \
  && grep -q "cluster https://api.lab.test:6443, as tester, namespace ${NS}" "${work}/out" && grep -q "it holds: ca.crt tls.crt tls.key" "${work}/out" \
  && ok "--apply names the cluster, the user and the namespace, and creates the secret" || bad "--apply: $(said | tr '\n' '|' | cut -c1-400) / $(tr '\n' '|' < "${OC_LOG}")"
! grep -qE '^apply|-o yaml|--dry-run=server' "${OC_LOG}" && ok "oc apply is never used (it would copy the key into an annotation)" || bad "oc was called with apply: $(tr '\n' '|' < "${OC_LOG}")"
refused "--apply over a secret that is there, without --replace" "--replace replaces it" -- --mongot "${pki}/mongot.pem" --apply --yes "${P[@]}"
: > "${OC_LOG}"
run --mongot "${pki}/mongot.pem" --apply --yes --replace "${P[@]}" && grep -q "^replace -f " "${OC_LOG}" && ok "--replace replaces it" || bad "--replace: $(said | head -3 | tr '\n' ' ')"
( export OC_NAMESPACE=some-other; refused "--apply when the namespace is not in the cluster" "this script never creates one" -- --envoy "${pki}/envoy.pem" --apply --yes "${P[@]}" )
run --trustca "${pki}/mongot.pem" --apply --yes && run --dbcred --apply --yes --password-file "${work}/pw" \
  && [[ -f "${OC_STATE}/ent-trust-bundle" && -f "${OC_STATE}/search-sync-source-password" ]] \
  && ok "--trustca and --dbcred are created the same way" || bad "--trustca or --dbcred --apply: $(said | head -3 | tr '\n' ' ')"
run --clean      # it ends non-zero: two secret files are kept, their secrets are not in the cluster
[[ ! -f "${here}/${NS}/ent-mongot-search-cert.secret.yaml" && -f "${here}/${NS}/ent-mongot-search-lb-0-cert.secret.yaml" && -f "${here}/${NS}/ent-trust-bundle.configmap.yaml" ]] \
  && ok "--clean removes the secret files whose secret is in the cluster, and keeps the others" || bad "--clean: $(said | tr '\n' '|' | cut -c1-300)"

# ------------------------------------------------------------------------------------------------ at a terminal
# The prompts themselves, on a pseudo-terminal: typed <what the screen shows> <what is typed> ... -- <arguments>.
# What the screen showed goes to ${work}/screen.
cat > "${work}/typed.py" <<'EOF'
import os, pty, select, sys, time
split = sys.argv.index("--")
pairs, command = sys.argv[1:split], sys.argv[split + 1:]
answers = [(pairs[i].encode(), pairs[i + 1].encode() + b"\n") for i in range(0, len(pairs), 2)]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)
seen, shown, until = b"", b"", time.time() + 60
while time.time() < until:
    if not select.select([fd], [], [], 0.5)[0]:
        continue
    try:
        data = os.read(fd, 4096)
    except OSError:
        break
    if not data:
        break
    seen += data
    shown += data
    if answers and answers[0][0] in seen:
        os.write(fd, answers.pop(0)[1])
        seen = b""
else:
    os.kill(pid, 9)
sys.stdout.buffer.write(shown)
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
EOF
typed() {
  local pairs=()
  while [[ "$1" != "--" ]]; do pairs+=("$1"); shift; done; shift
  ( cd "${here}" && PATH="${work}/bin:${PATH}" python3 "${work}/typed.py" ${pairs[@]+"${pairs[@]}"} -- "${SH}" "${SCRIPT}" "$@" ) >"${work}/screen" 2>&1 </dev/null
}
rm -f "${here}/${NS}"/*.yaml; rm -f "${OC_STATE}"/*; : > "${OC_LOG}"
f="${here}/${NS}/ent-mongot-search-cert.secret.yaml"
typed "pass phrase" "the key passphrase" -- --mongot "${pki}/mongot.pem" --dry-run \
  && [[ "$(field "${f}" tls.key | "${OPENSSL}" pkey -pubout 2>/dev/null)" == "$("${OPENSSL}" pkey -in "${pki}/mongot.key" -pubout 2>/dev/null)" ]] \
  && ! grep -qF "the key passphrase" "${work}/screen" \
  && ok "the passphrase is asked for at the terminal, is not shown, and opens the key" || bad "the passphrase prompt: $(tr '\n' '|' < "${work}/screen" | cut -c1-300)"
rm -f "${f}"
typed "pass phrase" "not the passphrase" -- --mongot "${pki}/mongot.pem" --dry-run
[[ $? -ne 0 && ! -f "${f}" ]] && grep -q "wrong passphrase" "${work}/screen" \
  && ok "a wrong passphrase typed at the terminal is refused, and nothing is written" || bad "a wrong passphrase typed: $(tr '\n' '|' < "${work}/screen" | cut -c1-300)"
f="${here}/${NS}/search-sync-source-password.secret.yaml"
typed "on the source mongod" 's3cr\et pass' "again" 's3cr\et pass' -- --dbcred --username syncUser --dry-run \
  && [[ "$(field "${f}" password)" == 's3cr\et pass' ]] && grep -q "password of syncUser on the source mongod" "${work}/screen" \
  && ! grep -qF 's3cr' "${work}/screen" \
  && ok "the database password is asked for twice, is not shown, and is kept as typed" || bad "the password prompt: $(tr '\n' '|' < "${work}/screen" | cut -c1-300)"
rm -f "${f}"
typed "on the source mongod" "one" "again" "another" -- --dbcred --dry-run
[[ $? -ne 0 && ! -f "${f}" ]] && grep -q "did not match" "${work}/screen" && ok "two different passwords are refused" || bad "two different passwords: $(tr '\n' '|' < "${work}/screen" | cut -c1-300)"
typed "pass phrase" "the key passphrase" "type the namespace" "some-other-namespace" -- --mongot "${pki}/mongot.pem" --apply
[[ $? -ne 0 ]] && grep -q "nothing was sent" "${work}/screen" && ! grep -qE '^(create|replace)' "${OC_LOG}" \
  && ok "--apply asks for the namespace to be typed, and sends nothing when it is another" || bad "the confirmation, wrong: $(tr '\n' '|' < "${work}/screen" | cut -c1-300)"
typed "pass phrase" "the key passphrase" "type the namespace" "${NS}" -- --mongot "${pki}/mongot.pem" --apply \
  && grep -q "^create -f " "${OC_LOG}" && ok "--apply goes on when the namespace is typed" || bad "the confirmation, right: $(tr '\n' '|' < "${work}/screen" | cut -c1-300)"

# ------------------------------------------------------------------------------------------------ a public repository
git -C "${here}" init -q . 2>/dev/null
refused "a folder git would track" "git would track ${NS}/ent-mongot-search-cert.secret.yaml" -- --mongot "${pki}/mongot.pem" --dry-run "${P[@]}"
echo "/${NS}/" > "${here}/.gitignore"
run --mongot "${pki}/mongot.pem" --dry-run "${P[@]}" && ok "the same folder, once git ignores it" || bad "an ignored folder: $(said | head -3 | tr '\n' ' ')"
git check-ignore -q x.secret.yaml && git check-ignore -q x.configmap.yaml && git check-ignore -q x.pass \
  && ok "this repository ignores *.secret.yaml, *.configmap.yaml and *.pass" || bad "this repository's .gitignore lacks a rule"

shellcheck -S warning "${SCRIPT}" >/dev/null 2>&1 && ok "shellcheck: no warning" || { command -v shellcheck >/dev/null 2>&1 && bad "shellcheck warns about the script" || ok "shellcheck: not installed, skipped"; }

[[ ${fails} -eq 0 ]] && echo "all passed" || { echo "${fails} failed"; exit 1; }
