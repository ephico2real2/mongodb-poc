# mongot & Envoy mTLS Cert Runbook

Oct 5, 2026

This runbook turns two company-signed PEM files into the Kubernetes TLS secrets that mongot and Envoy use for mTLS in namespace `dvh-gp6-rnd`. It replaces the secrets cert-manager issued from `internal-ca`.

## What you get

- `ent-mongot-search-cert` and `ent-mongot-search-lb-0-client-cert` holding the company-signed leaf certs, under the names the operator and Envoy already reference.
- No cert-manager Certificate left to overwrite them.
- `ent-trust-bundle` holding the company CA, mounted by the mongot and Envoy pods.
- mongot and Envoy restarted on the new certs, with no TLS errors in their logs and a `$search` query returning results.
- The decrypted key files deleted from your workstation.

## Architecture

| File | Used by | Leaf cert must allow |
| --- | --- | --- |
| `mongot-search-0-svc.dvh-gp6-rnd.svc.cluster.local.pem` | mongot | Server Auth and Client Auth |
| `mongot-search-0-proxy-svc.dvh-gp6-rnd.svc.cluster.local.pem` | Envoy (proxy) | Client Auth, plus Server Auth if mongod connects to Envoy over TLS |

Each PEM holds three things, in this order: the password-protected private key, the company CA bundle, then the leaf (service) certificate.

<!-- markdownlint-disable MD033 -->
<img alt="The three TLS parties of this runbook: mongod sends search queries to Envoy; Envoy connects to mongot with mTLS, presenting its client cert; mongot syncs from mongod, presenting the mongot cert as a client. Envoy and mongot trust the company CA in ent-trust-bundle; mongod uses its own TLS CA configuration." src="diagrams/mongot-runbooks/cert-parties.light.png">
<!-- markdownlint-enable MD033 -->

*The three parties and the certificate each one presents. The figure's “ca.crt in each secret” labels the extra copies these commands write. Envoy and mongot read trust from `ent-trust-bundle`; mongod uses its own TLS CA configuration.*

```text
① mongod --search queries--> Envoy x2 (mongot-search-lb-0), presents the Envoy cert
② Envoy  --mTLS, Envoy client cert--> mongot x3 (mongot-search-0), presents the mongot cert
③ mongot --sync, mongot cert as client--> mongod, trusts the company CA in its CA ConfigMap

Company CA: ent-trust-bundle for Envoy and mongot; mongod uses its own TLS CA configuration
```

Each numbered arrow is a TLS connection where the caller checks the other side's cert, so all three parties need the company CA.

**Terms used in this runbook**

- **Leaf cert**: the certificate for the service itself (mongot or Envoy), not a CA.
- **CA bundle**: the company root and intermediate CA certs that signed the leaf.
- **SAN**: Subject Alternative Name, the DNS names a cert is valid for.
- **EKU**: Extended Key Usage, what a cert may be used for (server auth, client auth).
- **mTLS**: both sides present a cert, and each side checks the other's cert against a trusted CA.

## Prerequisites

- [ ] Logged in with `oc` and able to edit secrets and certificates in `dvh-gp6-rnd`
- [ ] The passphrase for each PEM
- [ ] Working in a private directory on your workstation; decrypted keys are created there and deleted in Step 7
- [ ] Commands below work with both OpenSSL 3 and the LibreSSL that ships with macOS; this shows which:

  ```bash
  openssl version
  ```

## Steps

Run all steps in the same terminal session, in order:

### 1. Set variables and check the files

Set short names once so every later command can reuse them.

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

Result: expected: one `ENCRYPTED PRIVATE KEY` (or `RSA PRIVATE KEY` followed by a `Proc-Type: 4,ENCRYPTED` line), then several `CERTIFICATE` blocks. The CA certs come first and the leaf cert is last.

Do not run *openssl x509 -in "$MONGOT_PEM"* to inspect the leaf. It reads only the first certificate in the file, which here is a CA cert. Step 3 checks the leaf after it has been split out.

### 2. Split the certs and remove the key passwords

#### 2a. Split out the certificates

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

#### 2b. Remove the password from each key

openssl's `pkey` command reads the encrypted key out of the PEM, asks for its passphrase, and writes the key back out with no password. Leaving off a cipher option such as `-aes256` is what makes the output unencrypted.

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

#### 2c. Confirm the password is gone

```bash
head -1 mongot.key envoy.key        # expect: -----BEGIN PRIVATE KEY-----
openssl pkey -in mongot.key -noout && echo "mongot key: no password"
openssl pkey -in envoy.key  -noout && echo "envoy key: no password"
```

Result: `-----BEGIN PRIVATE KEY-----` on each key, then `mongot key: no password` and `envoy key: no password`. The last two commands must not prompt for a passphrase. If the first line reads `BEGIN ENCRYPTED PRIVATE KEY`, or a `Proc-Type: 4,ENCRYPTED` line follows it, the key is still encrypted: rerun 2b without any cipher option.

You now have these files for each service:

| File | Contents | Goes into secret key |
| --- | --- | --- |
| `<name>-leaf.crt` | Leaf cert only | (used for checks) |
| `<name>-ca.crt` | Company CA bundle | `ca.crt` |
| `<name>.crt` | Leaf, then CA chain | `tls.crt` |
| `<name>.key` | Private key, no password | `tls.key` |

Kubernetes TLS secrets need the key without a password; pods cannot type a passphrase at startup. That is why 2b is required.

### 3. Verify before touching the cluster

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

Result: each check prints what its comment says, and check 3 shows:

| Item | mongot leaf | Envoy leaf |
| --- | --- | --- |
| SAN | `mongot-search-0-svc.dvh-gp6-rnd.svc.cluster.local` | `mongot-search-0-proxy-svc.dvh-gp6-rnd.svc.cluster.local` |
| EKU | TLS Web Server Authentication, TLS Web Client Authentication | TLS Web Client Authentication (plus Server Authentication if mongod connects to Envoy over TLS) |
| Issuer | Company CA | Company CA |
| Not After | Comfortably in the future | Comfortably in the future |

A missing SAN or EKU cannot be fixed with openssl. Ask the company signer to reissue the cert.

### 4. Confirm the existing secrets and stop cert-manager managing them

Keep the existing secret names. The operator and Envoy already reference them, so you only swap their contents. If cert-manager still owns a secret, it will overwrite your company cert on its next reconcile.

#### 4a. Set the secret names and confirm the current secrets

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

Result: before the change, the issuer shows `internal-ca`. The Certificate names printed are the ones Step 4c deletes.

#### 4b. Back up the current secrets

```bash
oc get secret $ENVOY_SECRET  -n $NS -o yaml > backup-$ENVOY_SECRET.yaml
oc get secret $MONGOT_SECRET -n $NS -o yaml > backup-$MONGOT_SECRET.yaml
```

These backups contain private keys. Store them as securely as the PEM files.

#### 4c. Delete the cert-manager Certificate objects

```bash
oc delete certificate $ENVOY_SECRET  -n $NS
oc delete certificate $MONGOT_SECRET -n $NS
```

The Certificate name usually matches the secret name; confirm with the `cert-manager.io/certificate-name` annotation. Deleting a Certificate normally leaves its secret in place. If the secret disappears, it had an owner reference; Step 5 recreates it.

If a Certificate comes back within a few minutes, something else creates it (the operator or a GitOps tool). Remove it at that source first.

### 5. Create or replace the secrets

Write a `kubernetes.io/tls` secret with `tls.crt` and `tls.key`. These commands also retain a harmless `ca.crt` copy, matching the cert-manager format; peer verification uses the mounted trust ConfigMap (Step 6). The `--dry-run=client -o yaml | oc apply` pattern creates the secret if it is missing and replaces its data if it exists.

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

Result: the issuer must be the company CA, not `internal-ca`. oc's `apply` may warn about a missing last-applied annotation the first time; that warning is harmless.

### 6. Make every party trust the company CA

Every party must trust the company CA before the new certs go live. A party that still trusts only `internal-ca` rejects the new certs with an unknown CA error.

| Party | What it verifies | Where the company CA must be |
| --- | --- | --- |
| mongod | mongot's or Envoy's cert when search traffic connects | mongod's TLS CA setting (the CA ConfigMap referenced by the MongoDB resource) |
| mongot | Client certs from mongod and Envoy; mongod's server cert when it syncs | `ca.crt` from the source trust ConfigMap (`ent-trust-bundle`), mounted on its pod |
| Envoy | mongot's server cert | `ca.crt` from the source trust ConfigMap (`ent-trust-bundle`), mounted on its pod |

**ca.crt in the secret vs the mounted bundle.** The TLS secrets' `ca.crt` is not read for peer verification. The mounted trust bundle determines whose certificates Envoy and mongot accept and can hold several CAs. Keep the company CA in `ent-trust-bundle`. Where the operator reads it: [Operator source references](#operator-source-references).

#### 6a. Create ent-trust-bundle from the company CA

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

The mongot and Envoy pods must mount this ConfigMap. Check with:

```bash
oc get sts/mongot-search-0 deploy/mongot-search-lb-0 -n $NS -o yaml | grep -B2 -A2 ent-trust-bundle
```

Pods load it at startup, so the restarts in Step 7 pick it up.

#### 6b. Check the bundle covers both leaf certs

```bash
TRUST_CM=ent-trust-bundle

# Save the bundle locally (the CA certs are under the ca.crt key)
oc get configmap $TRUST_CM -n $NS -o jsonpath='{.data.ca\.crt}' > mounted-bundle.pem
grep -c 'BEGIN CERTIFICATE' mounted-bundle.pem   # how many CA certs it holds

# Both leaf certs must verify against it (prints OK twice)
openssl verify -CAfile mounted-bundle.pem mongot-leaf.crt envoy-leaf.crt
```

Result: both lines must print `OK`. If not, the CA in the PEM files does not match the leaf certs; go back to Step 3 check 5. mongod's CA ConfigMap needs the same company CA (see the table above).

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

### 7. Restart mongot and Envoy

Step 7a; 7b is under [Verify](#verify) and 7c under [Clean up](#clean-up). Pods read certs at startup, so restart them after Steps 5 and 6.

```bash
MONGOT_STS=mongot-search-0        # StatefulSet, 3 pods (label app=mongot-search-0-svc)
ENVOY_DEPLOY=mongot-search-lb-0   # Deployment, 2 pods (label app=mongot-search-lb-0)

oc rollout restart statefulset/$MONGOT_STS -n $NS
oc rollout restart deployment/$ENVOY_DEPLOY -n $NS
oc rollout status  statefulset/$MONGOT_STS -n $NS
oc rollout status  deployment/$ENVOY_DEPLOY -n $NS
```

Result: mongot's 3 pods and Envoy's 2 pods Running and Ready.

Both workloads are created by the MongoDB operator. If the operator reverts the restart, delete the pods one at a time instead and wait for each to return Ready, then do the same for Envoy's two pods; the second command lists their names:

```bash
oc delete pod mongot-search-0-0 -n $NS          # then -1, then -2
oc get pods -l app=mongot-search-lb-0 -n $NS
```

## Verify

### 7b. Check the logs for TLS errors

```bash
oc logs -n $NS -l app=mongot-search-0-svc --all-containers --prefix --since=10m | grep -iE 'tls|ssl|certificate|handshake'
oc logs -n $NS -l app=mongot-search-lb-0  --all-containers --prefix --since=10m | grep -iE 'tls|ssl|certificate|handshake'
```

No handshake or verify errors means mTLS is working. Confirm end to end by running a `$search` query against a collection with a search index.

- [ ] Both pods Running and Ready
- [ ] No TLS errors in mongot or Envoy logs
- [ ] `$search` query returns results
- [ ] Decrypted key files deleted

## Reference

### Operator source references

Operator 1.13.0 projects Envoy's trusted CA from the source CA volume ([`mongodbsearchenvoy_controller.go:628–633`](https://github.com/mongodb/mongodb-kubernetes/blob/1.13.0/controllers/operator/mongodbsearchenvoy_controller.go#L628-L633)). For an external source, that volume uses `ca.crt` from the ConfigMap named by `spec.source.external.tls.ca` ([`external_search_source.go:41–42`](https://github.com/mongodb/mongodb-kubernetes/blob/1.13.0/controllers/searchcontroller/external_search_source.go#L41-L42)); mongot's `CertificateAuthorityFile` points at the same CA mount ([`mongodbsearch_reconcile_helper.go:1918–2061`](https://github.com/mongodb/mongodb-kubernetes/blob/1.13.0/controllers/searchcontroller/mongodbsearch_reconcile_helper.go#L1918-L2061)).

### Concepts and FAQ

**Why does only the key have a password?** Certificates are public by design, so a PEM never encrypts them. Only the private key is protected. (PKCS#12 `.p12` or `.pfx` files are different: the whole container is password-protected.)

**Why not just run openssl x509 -in file.pem -out file.crt?** openssl's `x509` command outputs only the first certificate in the file. In these PEMs the first cert is a CA, so you would get the wrong cert and lose the chain.

**Why must the leaf come first in `tls.crt`?** TLS sends the chain in file order and expects the server's own cert first. A chain that starts with a CA cert fails validation.

**Why not pass the whole PEM as the cert?** The secret needs the cert and the key in separate fields. Passing the PEM would put the encrypted key inside `tls.crt`.

**Do we need `ca.crt` in the secret?** No, for Operator 1.13.0. The commands retain that harmless copy, but Envoy and mongot verify peers using the source trust ConfigMap (`ent-trust-bundle` here). See [Operator source references](#operator-source-references) for the pinned operator source references.

**Why keep the old secret names?** The MongoDBSearch resource and Envoy config already reference them. New names would mean editing those resources too.

### Diagram sources

The figure under Architecture comes from `diagrams/mongot-runbooks/source.html`, rendered to a light and a dark PNG; this document embeds the light one. The page holds two figures, in this order: `fresh-install-path` and `cert-parties`. To change a figure, edit the page, re-render both PNGs, and update its `alt` text and its `text` twin in the same commit.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `bad decrypt` or `unable to load key` in Step 2 | Wrong passphrase | Rerun `split_pem` with the correct passphrase |
| Leaf count is 0 or 2 in Step 3 | Leaf marked as CA, or the PEM layout differs | Run the command below on each cert block and sort them by hand |
| `unable to get local issuer certificate` in Step 3 | CA bundle missing an intermediate or the root | Get the full chain from the company signer |
| `key values mismatch` or Step 3 diff prints differences | Key and cert from different requests | Use the matching key, or reissue the cert |
| `unsupported certificate purpose` in logs | EKU missing Server or Client Auth | Reissue with the right EKU |
| `hostname mismatch` or SAN error in logs | SAN does not match the service DNS name | Reissue with the correct SAN |
| `unknown ca` or `certificate verify failed` in logs | A party does not trust the company CA | Step 6: add the company CA to that party's bundle |
| Secret reverts to `internal-ca` after a few minutes | cert-manager Certificate still exists | Step 4c: delete it, or remove it at its source |
| `-ext` option not recognised | macOS LibreSSL | Use the `-text \| grep` forms in this runbook |

Command referenced in the table:

```bash
openssl x509 -noout -subject -text    # on each cert block
```

## Clean up

### 7c. Delete the decrypted keys

```bash
rm -f mongot.key envoy.key *.pass
# This unlinks the files; nothing overwrites them. On current macOS "rm -P" does nothing (its manual page says so),
# and on a solid-state or copy-on-write disk shred cannot overwrite in place either: work on an encrypted disk.
```

Keep the original PEM files and Step 4 backups somewhere access-controlled. Delete the backups once the change has been stable for an agreed period.

## What's next

- To set up mTLS where none of the secrets or the trust bundle exist yet: the [fresh install runbook](mongot-envoy-mtls-fresh-install-runbook.md).
- The five prerequisites made by a script, then the chart: [Prerequisites and Setup](prerequisite-and-setup-doc.md).
