# mongot & Envoy mTLS Cert Runbook

Oct 5, 2026

## Overview

This runbook turns two company-signed PEM files into the Kubernetes TLS secrets that mongot and Envoy use for mTLS in namespace `dvh-gp6-rnd`. It replaces the secrets cert-manager issued from `internal-ca`.

| File | Used by | Leaf cert must allow |
| --- | --- | --- |
| `mongot-search-0-svc.dvh-gp6-rnd.svc.cluster.local.pem` | mongot | Server Auth and Client Auth |
| `mongot-search-0-proxy-svc.dvh-gp6-rnd.svc.cluster.local.pem` | Envoy (proxy) | Client Auth, plus Server Auth if mongod connects to Envoy over TLS |

Each PEM holds three things, in this order: the password-protected private key, the company CA bundle, then the leaf (service) certificate.

```mermaid
flowchart LR
  mongod["mongod<br/>Trusts: company CA<br/>(its CA ConfigMap)"]
  envoy["Envoy proxy<br/>mongot-search-lb-0<br/>Presents: envoy cert<br/>Trusts: company CA"]
  mongot["mongot<br/>mongot-search-0<br/>Presents: mongot cert<br/>Trusts: company CA"]
  ca[("Company CA<br/>ent-trust-bundle + ca.crt in each secret")]
  mongod -- "search queries" --> envoy
  envoy -- "mTLS, Envoy client cert" --> mongot
  mongot -- "sync, mongot cert as client" --> mongod
  ca -.-> mongod
  ca -.-> envoy
  ca -.-> mongot
```

Each solid arrow is a TLS connection where the caller checks the other side's cert, so all three parties need the company CA.

**Before you start**

- [ ] Logged in with `oc` and able to edit secrets and certificates in `dvh-gp6-rnd`
- [ ] The passphrase for each PEM
- [ ] Working in a private directory on your workstation; decrypted keys are created there and deleted in Step 7
- [ ] Commands below work with both OpenSSL 3 and the LibreSSL that ships with macOS (`openssl version` shows which)

**Terms used in this runbook**

- **Leaf cert**: the certificate for the service itself (mongot or Envoy), not a CA.
- **CA bundle**: the company root and intermediate CA certs that signed the leaf.
- **SAN**: Subject Alternative Name, the DNS names a cert is valid for.
- **EKU**: Extended Key Usage, what a cert may be used for (server auth, client auth).
- **mTLS**: both sides present a cert, and each side checks the other's cert against a trusted CA.

## Step 1: Set variables and check the files

Set short names once so every later command can reuse them. Run all steps in the same terminal session.

```bash
NS=dvh-gp6-rnd
MONGOT_PEM=mongot-search-0-svc.dvh-gp6-rnd.svc.cluster.local.pem
ENVOY_PEM=mongot-search-0-proxy-svc.dvh-gp6-rnd.svc.cluster.local.pem
```

Confirm what is inside each file:

```bash
grep -E 'BEGIN|END' "$MONGOT_PEM"
grep -E 'BEGIN|END' "$ENVOY_PEM"
```

Expected: one `ENCRYPTED PRIVATE KEY` (or `RSA PRIVATE KEY` followed by a `Proc-Type: 4,ENCRYPTED` line), then several `CERTIFICATE` blocks. The CA certs come first and the leaf cert is last.

Do not run `openssl x509 -in "$MONGOT_PEM"` to inspect the leaf. It reads only the first certificate in the file, which here is a CA cert. Step 3 checks the leaf after it has been split out.

## Step 2: Split the certs and remove the key passwords

**2a. Split out the certificates**

Paste this helper into your terminal once. It works in bash and zsh. It sorts the cert blocks into the leaf and the CA chain, then builds `tls.crt` with the leaf first.

```bash
split_pem() {   # usage: split_pem <pem file> <short name>
  awk -v p="$2" '/BEGIN CERTIFICATE/{n++;f=1} f{print > (p"-part-"n".pem")} /END CERTIFICATE/{f=0}' "$1"
  : > "$2-leaf.crt"; : > "$2-ca.crt"
  i=1
  while [ -f "$2-part-$i.pem" ]; do
    if openssl x509 -in "$2-part-$i.pem" -noout -text | grep -q 'CA:TRUE'; then
      cat "$2-part-$i.pem" >> "$2-ca.crt"     # CA cert -> chain file
    else
      cat "$2-part-$i.pem" >> "$2-leaf.crt"   # service cert -> leaf file
    fi
    rm "$2-part-$i.pem"; i=$((i+1))
  done
  cat "$2-leaf.crt" "$2-ca.crt" > "$2.crt"    # leaf first, then chain
}

split_pem "$MONGOT_PEM" mongot
split_pem "$ENVOY_PEM"  envoy
```

No passphrase is needed here. Certificates are never password-protected; only the key is.

**2b. Remove the password from each key**

`openssl pkey` reads the encrypted key out of the PEM, asks for its passphrase, and writes the key back out with no password. Leaving off a cipher option such as `-aes256` is what makes the output unencrypted.

```bash
openssl pkey -in "$MONGOT_PEM" -out mongot.key   # enter the mongot PEM passphrase
openssl pkey -in "$ENVOY_PEM"  -out envoy.key    # enter the Envoy PEM passphrase
chmod 600 mongot.key envoy.key
```

To run it without a prompt, put each passphrase in a file only you can read and use `-passin`:

```bash
openssl pkey -in "$MONGOT_PEM" -out mongot.key -passin file:mongot.pass
openssl pkey -in "$ENVOY_PEM"  -out envoy.key  -passin file:envoy.pass
```

Avoid `-passin pass:<password>`; the password ends up in shell history. Delete the `.pass` files in Step 7c along with the keys.

**2c. Confirm the password is gone**

```bash
head -1 mongot.key envoy.key        # expect: -----BEGIN PRIVATE KEY-----
openssl pkey -in mongot.key -noout && echo "mongot key: no password"
openssl pkey -in envoy.key  -noout && echo "envoy key: no password"
```

The last two commands must not prompt for a passphrase. If the first line reads `BEGIN ENCRYPTED PRIVATE KEY`, or a `Proc-Type: 4,ENCRYPTED` line follows it, the key is still encrypted: rerun 2b without any cipher option.

You now have these files for each service:

| File | Contents | Goes into secret key |
| --- | --- | --- |
| `<name>-leaf.crt` | Leaf cert only | (used for checks) |
| `<name>-ca.crt` | Company CA bundle | `ca.crt` |
| `<name>.crt` | Leaf, then CA chain | `tls.crt` |
| `<name>.key` | Private key, no password | `tls.key` |

Kubernetes TLS secrets need the key without a password; pods cannot type a passphrase at startup. That is why 2b is required.

## Step 3: Verify before touching the cluster

Every check below must pass. If one fails, stop and use Troubleshooting; a bad cert here becomes a failed handshake later.

```bash
# 1. Exactly one leaf per service (expect 1 and 1)
grep -c 'BEGIN CERTIFICATE' mongot-leaf.crt envoy-leaf.crt

# 2. Keys have no password (expect BEGIN PRIVATE KEY, not ENCRYPTED)
head -1 mongot.key envoy.key

# 3. Leaf identity, expiry, SANs and EKUs
for n in mongot envoy; do
  echo "== $n"
  openssl x509 -in $n-leaf.crt -noout -subject -issuer -enddate
  openssl x509 -in $n-leaf.crt -noout -text | grep -A1 -E 'Subject Alternative Name|Extended Key Usage'
done

# 4. Each key matches its cert (prints OK)
diff <(openssl x509 -in mongot-leaf.crt -noout -pubkey) <(openssl pkey -in mongot.key -pubout) && echo "mongot key OK"
diff <(openssl x509 -in envoy-leaf.crt  -noout -pubkey) <(openssl pkey -in envoy.key  -pubout) && echo "envoy key OK"

# 5. Chain validates against the CA bundle (prints OK)
openssl verify -CAfile mongot-ca.crt mongot-leaf.crt
openssl verify -CAfile envoy-ca.crt  envoy-leaf.crt

# 6. Both files carry the same company CA (prints same CA)
diff mongot-ca.crt envoy-ca.crt && echo "same CA"
```

What check 3 must show:

| Item | mongot leaf | Envoy leaf |
| --- | --- | --- |
| SAN | `mongot-search-0-svc.dvh-gp6-rnd.svc.cluster.local` | `mongot-search-0-proxy-svc.dvh-gp6-rnd.svc.cluster.local` |
| EKU | TLS Web Server Authentication, TLS Web Client Authentication | TLS Web Client Authentication (plus Server Authentication if mongod connects to Envoy over TLS) |
| Issuer | Company CA | Company CA |
| Not After | Comfortably in the future | Comfortably in the future |

A missing SAN or EKU cannot be fixed with openssl. Ask the company signer to reissue the cert.

## Step 4: Confirm the existing secrets and stop cert-manager managing them

Keep the existing secret names. The operator and Envoy already reference them, so you only swap their contents. If cert-manager still owns a secret, it will overwrite your company cert on its next reconcile.

**4a. Set the secret names and confirm the current secrets**

```bash
ENVOY_SECRET=ent-mongot-search-lb-0-client-cert
MONGOT_SECRET=ent-mongot-search-cert
```

| Service | Known secret name | How to recognise it |
| --- | --- | --- |
| Envoy (client) | `ent-mongot-search-lb-0-client-cert` | CN `envoy-client`, issuer `internal-ca` |
| mongot | ent-mongot-search-cert | SAN or CN for `mongot-search-0-svc` |

Check both secrets: which cert-manager Certificate owns each one, and who issued the cert it holds now.

```bash
for s in $MONGOT_SECRET $ENVOY_SECRET; do
  echo "== $s"
  oc get secret $s -n $NS -o jsonpath='Owned by Certificate: {.metadata.annotations.cert-manager\.io/certificate-name}{"\n"}'
  oc get secret $s -n $NS -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -enddate
done

oc get certificate $MONGOT_SECRET $ENVOY_SECRET -n $NS
```

Before the change, the issuer shows `internal-ca`. The Certificate names printed are the ones Step 4c deletes.

**4b. Back up the current secrets**

```bash
oc get secret $ENVOY_SECRET  -n $NS -o yaml > backup-$ENVOY_SECRET.yaml
oc get secret $MONGOT_SECRET -n $NS -o yaml > backup-$MONGOT_SECRET.yaml
```

These backups contain private keys. Store them as securely as the PEM files.

**4c. Delete the cert-manager Certificate objects**

```bash
oc delete certificate $ENVOY_SECRET  -n $NS
oc delete certificate $MONGOT_SECRET -n $NS
```

The Certificate name usually matches the secret name; confirm with the `cert-manager.io/certificate-name` annotation. Deleting a Certificate normally leaves its secret in place. If the secret disappears, it had an owner reference; Step 5 recreates it.

If a Certificate comes back within a few minutes, something else creates it (the operator or a GitOps tool). Remove it at that source first.

## Step 5: Create or replace the secrets

Mirror the cert-manager format exactly: a `kubernetes.io/tls` secret with `tls.crt`, `tls.key` and `ca.crt`. The `--dry-run=client -o yaml | oc apply` pattern creates the secret if it is missing and replaces its data if it exists.

```bash
oc create secret generic $MONGOT_SECRET \
  --type=kubernetes.io/tls \
  --from-file=tls.crt=mongot.crt \
  --from-file=tls.key=mongot.key \
  --from-file=ca.crt=mongot-ca.crt \
  -n $NS --dry-run=client -o yaml | oc apply -f -

oc create secret generic $ENVOY_SECRET \
  --type=kubernetes.io/tls \
  --from-file=tls.crt=envoy.crt \
  --from-file=tls.key=envoy.key \
  --from-file=ca.crt=envoy-ca.crt \
  -n $NS --dry-run=client -o yaml | oc apply -f -
```

Confirm each secret now holds the company-signed leaf:

```bash
for s in $MONGOT_SECRET $ENVOY_SECRET; do
  echo "== $s"
  oc get secret $s -n $NS -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -enddate
done
```

The issuer must be the company CA, not `internal-ca`. `oc apply` may warn about a missing last-applied annotation the first time; that warning is harmless.

## Step 6: Make every party trust the company CA

Every party must trust the company CA before the new certs go live. A party that still trusts only `internal-ca` rejects the new certs with an unknown CA error.

| Party | What it verifies | Where the company CA must be |
| --- | --- | --- |
| mongod | mongot's or Envoy's cert when search traffic connects | mongod's TLS CA setting (the CA ConfigMap referenced by the MongoDB resource) |
| mongot | Client certs from mongod and Envoy; mongod's server cert when it syncs | `ca.crt` in its secret (Step 5) and the CA bundle mounted on its pod |
| Envoy | mongot's server cert | `ca.crt` in its secret (Step 5) and the CA bundle mounted on its pod |

**ca.crt in the secret vs the mounted bundle.** `ca.crt` says who signed this cert. The mounted bundle says whose certs this pod accepts, and can hold several CAs. Envoy reads `ca.crt` from its own secret to verify mongot, so that copy is required. Keep the company CA in both the secrets and the mounted bundle.

**6a. Create ent-trust-bundle from the company CA**

This runbook treats the `ca.crt` extracted in Step 2 as the company CA. Step 3 check 6 confirmed `mongot-ca.crt` and `envoy-ca.crt` are identical, so either file works.

```bash
TRUST_CM=ent-trust-bundle

# Create it new
oc create configmap $TRUST_CM --from-file=ca.crt=mongot-ca.crt -n $NS

# Or, if it already exists, replace its contents
oc create configmap $TRUST_CM --from-file=ca.crt=mongot-ca.crt \
  -n $NS --dry-run=client -o yaml | oc apply -f -

# Confirm what it holds
oc get configmap $TRUST_CM -n $NS -o jsonpath='{.data.ca\.crt}' | grep -c 'BEGIN CERTIFICATE'
```

Replacing the contents removes every CA that was there before, including `internal-ca`. If some pods will still present `internal-ca` certs during the change, use the cutover tip below instead.

The mongot and Envoy pods must mount this ConfigMap. Check with `oc get sts/mongot-search-0 deploy/mongot-search-lb-0 -n $NS -o yaml | grep -B2 -A2 ent-trust-bundle`. Pods load it at startup, so the restarts in Step 7 pick it up.

**6b. Check the bundle covers both leaf certs**

```bash
TRUST_CM=ent-trust-bundle

# Save the bundle locally (the CA certs are under the ca.crt key)
oc get configmap $TRUST_CM -n $NS -o jsonpath='{.data.ca\.crt}' > mounted-bundle.pem
grep -c 'BEGIN CERTIFICATE' mounted-bundle.pem   # how many CA certs it holds

# Both leaf certs must verify against it (prints OK twice)
openssl verify -CAfile mounted-bundle.pem mongot-leaf.crt envoy-leaf.crt
```

Both lines must print `OK`. If not, the CA in the PEM files does not match the leaf certs; go back to Step 3 check 5. mongod's CA ConfigMap needs the same company CA (see the table above).

**Cutover tip:** if mongod and the search pods cannot all restart at once, put both the company CA and `internal-ca` in the bundles during the change. Remove `internal-ca` once everything runs on company certs. The old CA is in your Step 4 backup:

```bash
# Pull the old CA out of the Step 4 backup
grep ' ca.crt:' backup-$ENVOY_SECRET.yaml | awk '{print $2}' | base64 -d > internal-ca.crt

# Build a bundle that trusts both CAs and load it
cat mongot-ca.crt internal-ca.crt > transition-bundle.pem
oc create configmap $TRUST_CM --from-file=ca.crt=transition-bundle.pem \
  -n $NS --dry-run=client -o yaml | oc apply -f -

# After the cutover, rerun 6a to go back to the company CA only
```

## Step 7: Restart, verify and clean up

Pods read certs at startup, so restart them after Steps 5 and 6.

**7a. Restart**

```bash
MONGOT_STS=mongot-search-0        # StatefulSet, 3 pods (label app=mongot-search-0-svc)
ENVOY_DEPLOY=mongot-search-lb-0   # Deployment, 2 pods (label app=mongot-search-lb-0)

oc rollout restart statefulset/$MONGOT_STS -n $NS
oc rollout restart deployment/$ENVOY_DEPLOY -n $NS
oc rollout status  statefulset/$MONGOT_STS -n $NS
oc rollout status  deployment/$ENVOY_DEPLOY -n $NS
```

Both workloads are created by the MongoDB operator. If the operator reverts the restart, delete the pods one at a time instead and wait for each to return Ready: `oc delete pod mongot-search-0-0 -n $NS`, then `-1`, then `-2`. Do the same for Envoy's two pods; `oc get pods -l app=mongot-search-lb-0 -n $NS` lists their names.

**7b. Check the logs for TLS errors**

```bash
oc logs -n $NS -l app=mongot-search-0-svc --all-containers --prefix --since=10m | grep -iE 'tls|ssl|certificate|handshake'
oc logs -n $NS -l app=mongot-search-lb-0  --all-containers --prefix --since=10m | grep -iE 'tls|ssl|certificate|handshake'
```

No handshake or verify errors means mTLS is working. Confirm end to end by running a `$search` query against a collection with a search index.

**7c. Delete the decrypted keys**

```bash
rm -P mongot.key envoy.key; rm -f *.pass        # macOS
# shred -u mongot.key envoy.key *.pass          # Linux
```

Keep the original PEM files and Step 4 backups somewhere access-controlled. Delete the backups once the change has been stable for an agreed period.

- [ ] Both pods Running and Ready
- [ ] No TLS errors in mongot or Envoy logs
- [ ] `$search` query returns results
- [ ] Decrypted key files deleted

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `bad decrypt` or `unable to load key` in Step 2 | Wrong passphrase | Rerun `split_pem` with the correct passphrase |
| Leaf count is 0 or 2 in Step 3 | Leaf marked as CA, or the PEM layout differs | Run `openssl x509 -noout -subject -text` on each cert block and sort them by hand |
| `unable to get local issuer certificate` in Step 3 | CA bundle missing an intermediate or the root | Get the full chain from the company signer |
| `key values mismatch` or Step 3 diff prints differences | Key and cert from different requests | Use the matching key, or reissue the cert |
| `unsupported certificate purpose` in logs | EKU missing Server or Client Auth | Reissue with the right EKU |
| `hostname mismatch` or SAN error in logs | SAN does not match the service DNS name | Reissue with the correct SAN |
| `unknown ca` or `certificate verify failed` in logs | A party does not trust the company CA | Step 6: add the company CA to that party's bundle |
| Secret reverts to `internal-ca` after a few minutes | cert-manager Certificate still exists | Step 4c: delete it, or remove it at its source |
| `-ext` option not recognised | macOS LibreSSL | Use the `-text \| grep` forms in this runbook |

## Concepts and FAQ

**Why does only the key have a password?** Certificates are public by design, so a PEM never encrypts them. Only the private key is protected. (PKCS#12 `.p12` or `.pfx` files are different: the whole container is password-protected.)

**Why not just run `openssl x509 -in file.pem -out file.crt`?** `openssl x509` outputs only the first certificate in the file. In these PEMs the first cert is a CA, so you would get the wrong cert and lose the chain.

**Why must the leaf come first in `tls.crt`?** TLS sends the chain in file order and expects the server's own cert first. A chain that starts with a CA cert fails validation.

**Why not pass the whole PEM as the cert?** The secret needs the cert and the key in separate fields. Passing the PEM would put the encrypted key inside `tls.crt`.

**Do we need `ca.crt` in the secret?** Yes, in both. Envoy uses `ca.crt` from its secret to verify mongot's server cert; without it the Envoy-to-mongot handshake fails. mongot needs the CA to verify the client certs from Envoy and mongod. Keep the same company CA in `ent-trust-bundle` too (Step 6).

**Why keep the old secret names?** The MongoDBSearch resource and Envoy config already reference them. New names would mean editing those resources too.
