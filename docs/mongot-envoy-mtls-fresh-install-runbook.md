# mongot & Envoy mTLS Fresh Install Runbook

Oct 5, 2026

## Overview

This runbook sets up mTLS for MongoDB Search in `dvh-gp6-rnd` from scratch, using company-signed certs. Use it when none of the secrets or the trust bundle exist yet. To swap certs on a running setup, use mongot & Envoy mTLS Cert Runbook instead.

**Steps 1 to 5 are also a script.** [`generate-mongodbsearch-prerequisites.sh`](../chart/mongodb-search-helm/generate-mongodbsearch-prerequisites.sh), a file of the chart, does them for any namespace, with the same checks. The decrypted key is never a file of its own there: it is only in the `*.secret.yaml` the script writes, which `--clean` removes. See [Prerequisites and Setup](prerequisite-and-setup-doc.md), Part 1. The steps below are the same thing by hand, and say what each check is for.

**A certificate is issued for one namespace.** The mongot certificate's name is `mongot-search-0-svc.<namespace>.svc.cluster.local`. Every command below names `dvh-gp6-rnd`; for another namespace the PEMs must have been issued for it, and `NS` set to it.

You create one ConfigMap, three TLS secrets and one password secret, all before mongot and Envoy are deployed:

| Object | Type | Source PEM | Used by |
| --- | --- | --- | --- |
| `ent-trust-bundle` | ConfigMap, key `ca.crt` | Company CA from any PEM | mongot and Envoy pods (mounted) |
| `ent-mongot-search-cert` | TLS secret | `mongot-search-0-svc.dvh-gp6-rnd.svc.cluster.local.pem` | mongot (`mongot-search-0`) |
| `ent-mongot-search-lb-0-client-cert` | TLS secret | `mongot-search-0-proxy-svc.dvh-gp6-rnd.svc.cluster.local.pem` | Envoy, as the client to mongot |
| `ent-mongot-search-lb-0-cert` | TLS secret | Company PEM for the public load balancer FQDN | Envoy, serving the public endpoint |
| `search-sync-source-password` | Secret, key `password` | mongotUser's password, from the source mongod owners | mongot, to sign in to the source mongod |

**Secret names must follow the operator's convention.** The MongoDBSearch resource uses `certsSecretPrefix: ent` to find the TLS secrets by name; it never lists them. The operator builds each name from the prefix and the resource name (`mongot`), so the TLS secrets must be named exactly:

| Pattern | With prefix `ent` and name `mongot` | Holds |
| --- | --- | --- |
| `<prefix>-<name>-search-cert` | `ent-mongot-search-cert` | mongot cert |
| `<prefix>-<name>-search-lb-0-cert` | `ent-mongot-search-lb-0-cert` | Envoy public endpoint cert |
| `<prefix>-<name>-search-lb-0-client-cert` | `ent-mongot-search-lb-0-client-cert` | Envoy client cert |

A typo, a different prefix or a renamed resource means the operator cannot find the secret, and mongot or Envoy will not start. `ent-trust-bundle` and `search-sync-source-password` are different: the resource names them explicitly, so they only have to match what the YAML says.

Each PEM holds the password-protected private key, the company CA bundle, then the leaf cert. This runbook assumes the public endpoint PEM uses the same layout.

<!-- markdownlint-disable MD033 -->
<img alt="What this runbook sets up: mongod servers outside OpenShift open TLS to the Route mongot-search on port 443; the passthrough Route hands each connection to one of two Envoy pods using balance roundrobin; each Envoy pod picks one of three mongot pods for every query over mTLS on port 27028; mongot syncs straight back to mongod, not through the Route or Envoy. A table lists the certificate presented on each hop." src="diagrams/mongot-runbooks/fresh-install-path.light.png">
<!-- markdownlint-enable MD033 -->

*What this runbook sets up. The router places each mongod connection on one Envoy pod; Envoy spreads every query across the three mongot pods; mongot syncs straight back to mongod.*

```text
OUTSIDE OPENSHIFT
  mongod servers, source replica set: abc234.uat.company.net:26018, every member in hostAndPorts

NAMESPACE dvh-gp6-rnd
① mongod --TLS to mongot-search-rnd.company.net:443--> Route mongot-search (passthrough)
     Envoy presents ent-mongot-search-lb-0-cert; the Route passes the stream through untouched
② Route  --one Envoy pod per connection, balance roundrobin--> Envoy x2 (mongot-search-lb-0)
     no cert of its own; it carries the TLS session from ①
③ Envoy  --mTLS on 27028, one mongot pod per query--> mongot x3 (mongot-search-0)
     Envoy presents ent-mongot-search-lb-0-client-cert; mongot presents ent-mongot-search-cert
④ mongot --sync, not through the Route or Envoy--> mongod
     mongod presents its own cert; mongot checks it with ent-trust-bundle and signs in as mongotUser
```

The mongod box stands for every upstream mongod listed in `hostAndPorts`; only `abc234.uat.company.net:26018` is set today. On every hop the caller checks the other side's cert against the company CA, so mongod, Envoy and mongot all have to trust it.

**Before you start**

- [ ] Logged in with `oc` and able to create secrets and ConfigMaps in `dvh-gp6-rnd`
- [ ] The three PEM files and the passphrase for each
- [ ] The public FQDN the load balancer cert was issued for
- [ ] A private working directory; decrypted keys are created there and deleted in Step 7
- [ ] Commands work with OpenSSL 3 and with the LibreSSL that ships with macOS

## Step 1: Set variables and check the files

Set every name once, then run all later steps in the same terminal session. Fill in the two values in angle brackets.

```bash
NS=dvh-gp6-rnd                                  # must match metadata.namespace in the MongoDBSearch YAML

# Input PEM files
MONGOT_PEM=mongot-search-0-svc.dvh-gp6-rnd.svc.cluster.local.pem
ENVOY_CLIENT_PEM=mongot-search-0-proxy-svc.dvh-gp6-rnd.svc.cluster.local.pem
LB_PEM=<public load balancer PEM file>

# Values from the MongoDBSearch resource
PUBLIC_FQDN=mongot-search-rnd.company.net       # spec.clusters[].loadBalancer.managed.externalHostname
SOURCE_HOST=abc234.uat.company.net:26018        # spec.source.external.hostAndPorts

# Objects to create (prefix "ent" + resource name "mongot")
TRUST_CM=ent-trust-bundle
MONGOT_SECRET=ent-mongot-search-cert
ENVOY_CLIENT_SECRET=ent-mongot-search-lb-0-client-cert
LB_SECRET=ent-mongot-search-lb-0-cert
SYNC_PW_SECRET=search-sync-source-password      # key: password

# Workloads (created by the operator in Step 6)
MONGOT_STS=mongot-search-0
ENVOY_DEPLOY=mongot-search-lb-0
```

Confirm none of the objects exist yet. Each line should print `NotFound`:

```bash
oc get configmap $TRUST_CM -n $NS
oc get secret $MONGOT_SECRET $ENVOY_CLIENT_SECRET $LB_SECRET $SYNC_PW_SECRET -n $NS
```

If any already exist, this is not a fresh install; use the retrofit runbook linked in the Overview.

Confirm what is inside each PEM:

```bash
for f in "$MONGOT_PEM" "$ENVOY_CLIENT_PEM" "$LB_PEM"; do echo "== $f"; grep -E 'BEGIN|END' "$f"; done
```

Expected per file: one `ENCRYPTED PRIVATE KEY` (or `RSA PRIVATE KEY` with a `Proc-Type: 4,ENCRYPTED` line), then several `CERTIFICATE` blocks with the leaf last.

## Step 2: Split the certs and remove the key passwords

**2a. Split out the certificates**

Paste this helper once (bash or zsh). It sorts each PEM's cert blocks into the leaf and the CA chain, then builds `tls.crt` with the leaf first. No passphrase is needed; certificates are never password-protected.

```bash
split_pem() {   # usage: split_pem <pem file> <short name>
  awk -v p="$2" '/^-----BEGIN CERTIFICATE-----/{n++;f=1} f{print > (p"-part-"n".pem")} /^-----END CERTIFICATE-----/{f=0}' "$1"
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

split_pem "$MONGOT_PEM"       mongot
split_pem "$ENVOY_CLIENT_PEM" envoy-client
split_pem "$LB_PEM"           lb
```

**2b. Remove the password from each key**

`openssl pkey` reads the encrypted key out of the PEM, asks for its passphrase, and writes the key back out with no password. Leaving off a cipher option such as `-aes256` is what makes the output unencrypted. Kubernetes needs it this way, because pods cannot type a passphrase at startup.

```bash
openssl pkey -in "$MONGOT_PEM"       -out mongot.key         # mongot PEM passphrase
openssl pkey -in "$ENVOY_CLIENT_PEM" -out envoy-client.key   # Envoy client PEM passphrase
openssl pkey -in "$LB_PEM"           -out lb.key             # public LB PEM passphrase
chmod 600 mongot.key envoy-client.key lb.key
```

To skip the prompts, put each passphrase in a file only you can read and use `-passin file:`:

```bash
chmod 600 mongot.pass envoy-client.pass lb.pass
openssl pkey -in "$MONGOT_PEM"       -out mongot.key       -passin file:mongot.pass
openssl pkey -in "$ENVOY_CLIENT_PEM" -out envoy-client.key -passin file:envoy-client.pass
openssl pkey -in "$LB_PEM"           -out lb.key           -passin file:lb.pass
```

Avoid `-passin pass:<password>`; the password ends up in shell history. Step 7d deletes the `.pass` files.

**2c. Confirm the passwords are gone**

```bash
head -1 mongot.key envoy-client.key lb.key     # expect: -----BEGIN PRIVATE KEY-----
for k in mongot envoy-client lb; do openssl pkey -in $k.key -noout && echo "$k key: no password"; done
```

None of these may prompt for a passphrase. `BEGIN ENCRYPTED PRIVATE KEY`, or a `Proc-Type: 4,ENCRYPTED` line, means the key is still encrypted: rerun 2b.

You now have, for each of `mongot`, `envoy-client` and `lb`:

| File | Contents | Goes into |
| --- | --- | --- |
| `<name>-leaf.crt` | Leaf cert only | Checks in Step 3 |
| `<name>-ca.crt` | CA bundle | `ca.crt` in the secret |
| `<name>.crt` | Leaf, then CA chain | `tls.crt` in the secret |
| `<name>.key` | Private key, no password | `tls.key` in the secret |

## Step 3: Verify the certs before touching the cluster

Every check must pass. A bad cert caught here is a failed handshake avoided later.

```bash
# 1. Exactly one leaf per PEM (expect 1, 1, 1)
grep -c 'BEGIN CERTIFICATE' mongot-leaf.crt envoy-client-leaf.crt lb-leaf.crt

# 2. Identity, expiry, SANs and EKUs of each leaf
for n in mongot envoy-client lb; do
  echo "== $n"
  openssl x509 -in $n-leaf.crt -noout -subject -issuer -enddate
  openssl x509 -in $n-leaf.crt -noout -text | grep -A1 -E 'Subject Alternative Name|Extended Key Usage'
done

# 3. The public cert covers the public FQDN (prints DNS:<fqdn>; the whole name must match, not its beginning;
#    capitals do not count, as in DNS)
openssl x509 -in lb-leaf.crt -noout -text | grep -A1 'Subject Alternative Name' | tr ',' '\n' | sed 's/^ *//' | grep -ixF "DNS:$PUBLIC_FQDN"

# 4. Each key matches its cert (prints OK three times)
for n in mongot envoy-client lb; do
  diff <(openssl x509 -in $n-leaf.crt -noout -pubkey) <(openssl pkey -in $n.key -pubout) && echo "$n key OK"
done

# 5. Each chain validates against its CA bundle (prints OK three times)
for n in mongot envoy-client lb; do openssl verify -CAfile $n-ca.crt $n-leaf.crt; done

# 6. Do all three PEMs carry the same CA?
diff mongot-ca.crt envoy-client-ca.crt && echo "envoy-client: same CA"
diff mongot-ca.crt lb-ca.crt           && echo "lb: same CA"
```

What check 2 must show:

| Item | mongot | Envoy client | Public LB |
| --- | --- | --- | --- |
| SAN | `mongot-search-0-svc.dvh-gp6-rnd.svc.cluster.local` | `mongot-search-0-proxy-svc.dvh-gp6-rnd.svc.cluster.local` | The public FQDN |
| EKU | Server Auth and Client Auth | Client Auth | Server Auth |
| Issuer | Company CA | Company CA | Company CA |
| Not After | Well in the future | Well in the future | Well in the future |

If check 6 shows the public LB cert has a different CA, that is fine; Step 4 builds the trust bundle from both. A missing SAN or EKU cannot be fixed with openssl: ask the company signer to reissue.

## Step 4: Create the ent-trust-bundle ConfigMap

`ent-trust-bundle` holds the company CA under the key `ca.crt`, and the mongot and Envoy pods mount it to check the certs they receive. This runbook treats the CA extracted in Step 2 as the company CA.

Build the bundle file. Use the line that matches the Step 3 check 6 result:

```bash
# All three PEMs share one CA (the usual case)
cp mongot-ca.crt trust-bundle.pem

# The public LB cert has a different CA: include both
cat mongot-ca.crt lb-ca.crt > trust-bundle.pem
```

Create the ConfigMap and check it:

```bash
oc create configmap $TRUST_CM --from-file=ca.crt=trust-bundle.pem -n $NS

# Count the CA certs it holds
oc get configmap $TRUST_CM -n $NS -o jsonpath='{.data.ca\.crt}' | grep -c 'BEGIN CERTIFICATE'

# Every leaf must verify against it (prints OK three times)
oc get configmap $TRUST_CM -n $NS -o jsonpath='{.data.ca\.crt}' > mounted-bundle.pem
openssl verify -CAfile mounted-bundle.pem mongot-leaf.crt envoy-client-leaf.crt lb-leaf.crt
```

**Check the bundle also trusts the source mongod.** mongot uses `ent-trust-bundle` to verify the external mongod at `abc234.uat.company.net:26018` (`spec.source.external.tls.ca` in the MongoDBSearch resource). From a machine that can reach it:

```bash
openssl s_client -connect $SOURCE_HOST -servername ${SOURCE_HOST%:*} \
  -CAfile trust-bundle.pem </dev/null 2>/dev/null | grep 'Verify return code'
```

Expected: `Verify return code: 0 (ok)`. If not, the mongod cert was signed by a CA that is not in the bundle. Get that CA, append it to `trust-bundle.pem`, and reload the ConfigMap:

```bash
oc create configmap $TRUST_CM --from-file=ca.crt=trust-bundle.pem \
  -n $NS --dry-run=client -o yaml | oc apply -f -
```

## Step 5: Create the secrets

Use the secret names exactly as set in Step 1. The operator finds the three TLS secrets by the `ent-mongot-search-*` naming convention (see the Overview), not by any reference in the YAML.

Each secret is type `kubernetes.io/tls` with three keys: `tls.crt` (leaf then chain), `tls.key` (no password) and `ca.crt` (company CA). `ca.crt` is required: Envoy uses it to verify mongot, and mongot uses it to verify its clients.

```bash
# mongot: server and client auth
oc create secret generic $MONGOT_SECRET --type=kubernetes.io/tls \
  --from-file=tls.crt=mongot.crt \
  --from-file=tls.key=mongot.key \
  --from-file=ca.crt=mongot-ca.crt -n $NS

# Envoy: client cert it presents to mongot
oc create secret generic $ENVOY_CLIENT_SECRET --type=kubernetes.io/tls \
  --from-file=tls.crt=envoy-client.crt \
  --from-file=tls.key=envoy-client.key \
  --from-file=ca.crt=envoy-client-ca.crt -n $NS

# Envoy: server cert for the public FQDN
oc create secret generic $LB_SECRET --type=kubernetes.io/tls \
  --from-file=tls.crt=lb.crt \
  --from-file=tls.key=lb.key \
  --from-file=ca.crt=lb-ca.crt -n $NS
```

Confirm each secret holds the right leaf:

```bash
for s in $MONGOT_SECRET $ENVOY_CLIENT_SECRET $LB_SECRET; do
  echo "== $s"
  oc get secret $s -n $NS -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer -enddate
done
```

`oc create secret tls` rejects a key that does not match its cert, but `generic` does not. Step 3 check 4 is what guards against a mismatch here.

**Sync user password secret**

mongot signs in to the source mongod as `mongotUser`, using the password in `search-sync-source-password` under the key `password`. Get the password from whoever manages the source mongod; that user must already exist there with the role needed for search sync.

This prompts for the password without echoing it and keeps it out of shell history and the process list:

```bash
printf 'mongotUser password: '; stty -echo; IFS= read -r SYNC_PW; stty echo; echo
printf '%s' "$SYNC_PW" | oc create secret generic $SYNC_PW_SECRET \
  --from-file=password=/dev/stdin -n $NS
unset SYNC_PW

# Confirm the key exists and is not empty (prints the length, not the password)
oc get secret $SYNC_PW_SECRET -n $NS -o jsonpath='{.data.password}' | base64 -d | wc -c
```

`printf '%s'` matters: `echo` or a here-string would add a trailing newline, which becomes part of the password and makes sign-in fail. `IFS= read -r` matters too: a plain `read` drops the spaces at either end of what is typed and takes a backslash as an escape, and both can be part of a password.

## Step 6: Deploy mongot and Envoy, and set trust on mongod

With the ConfigMap and secrets in place, the operator finds them on the first reconcile, and the pods start without crash-looping on missing files.

The Helm chart `chart/mongodb-search-helm` does 6a, 6b and 6d in one `helm install`, and installs the operator as well: see [Prerequisites and Setup](prerequisite-and-setup-doc.md). The steps below are the same thing by hand.

**6a. Apply the MongoDBSearch resource**

The resource never names the TLS secrets directly. `certsSecretPrefix: ent` plus the resource name `mongot` tells the operator to look for `ent-mongot-search-cert`, `ent-mongot-search-lb-0-cert` and `ent-mongot-search-lb-0-client-cert`, the names created in Step 5. The sync password is referenced by name in `passwordSecretRef`.

Save this as `mongodbsearch.yaml`:

```yaml
apiVersion: mongodb.com/v1
kind: MongoDBSearch
metadata:
  name: mongot                            # TLS secret names derive from this
  namespace: dvh-gp6-rnd                  # must equal $NS
spec:
  clusters:
    - loadBalancer:
        managed:
          deployment:
            spec:
              template:
                spec:
                  containers:
                    - image: 'quay.io/ephico2real/envoy:v1.37-latest'
                      name: envoy
          externalHostname: mongot-search-rnd.company.net   # must be in the LB cert SAN
          replicas: 2
          retryPolicy:
            numRetries: 2
            perTryTimeout: 60s
      persistence:
        single:
          storage: 10Gi
          storageClass: thin-csi
      replicas: 3
      resourceRequirements:
        limits:
          cpu: '3'
          memory: 5Gi
        requests:
          cpu: '1'
          memory: 3Gi
  observability:
    metricsForwarder:
      mode: auto
      resourceRequirements:
        limits:
          cpu: 250m
          memory: 256Mi
        requests:
          cpu: 100m
          memory: 128Mi
    prometheus:
      mode: enabled
      port: 9946
  security:
    tls:
      certsSecretPrefix: ent              # operator reads the ent-mongot-search-* secrets
  source:
    external:
      hostAndPorts:                       # one entry per upstream mongod (see note below)
        - 'abc234.uat.company.net:26018'
        # - '<another source member>:26018'
      tls:
        ca:
          name: ent-trust-bundle          # ConfigMap mongot uses to verify the source mongod
    passwordSecretRef:
      key: password                       # key inside the secret
      name: search-sync-source-password   # created in Step 5
    username: mongotUser                  # sync user on the source mongod
```

**Note on `hostAndPorts`:** it can list several upstream mongod servers, for example every member of the source replica set. List them all so mongot keeps syncing when one member is down. Every host listed must present a cert that `ent-trust-bundle` trusts; repeat the Step 4 source check for each one.

Changing `metadata.name` or `certsSecretPrefix` changes the secret names the operator expects, so recreate the TLS secrets to match. Then apply:

```bash
oc apply -f mongodbsearch.yaml -n $NS
```

**6b. Wait for the workloads and check the mounts**

```bash
oc rollout status statefulset/$MONGOT_STS  -n $NS   # 3 pods
oc rollout status deployment/$ENVOY_DEPLOY -n $NS   # 2 pods

# All four object names should appear in the pod specs
oc get sts/$MONGOT_STS deploy/$ENVOY_DEPLOY -n $NS -o yaml | grep -E 'ent-trust-bundle|ent-mongot-search'
```

**6c. Make the source mongod trust the company CA**

The source mongod runs outside this cluster at `abc234.uat.company.net:26018`, so it is not configured here. It reaches mongot through `mongot-search-rnd.company.net` and checks Envoy's public cert (`ent-mongot-search-lb-0-cert`) when it does.

Ask the mongod host owners to confirm two things:

- [ ] The CA file in mongod's TLS settings includes the company CA in `trust-bundle.pem`
- [ ] mongod's search settings point at `mongot-search-rnd.company.net` on port 443

**6d. Expose Envoy on the public FQDN with a passthrough Route**

mongod reaches Envoy through an OpenShift Route named `mongot-search` on `mongot-search-rnd.company.net`. The Route must use **passthrough**, so the router forwards the TLS stream untouched. Envoy does the SNI matching on `externalHostname` and presents `ent-mongot-search-lb-0-cert` itself. With edge or reencrypt, mongod would get the router's cert instead.

The Route targets the Service the operator already creates for Envoy. No extra Service is needed:

| Field | Value |
| --- | --- |
| Service | `mongot-search-0-proxy-svc` (owned by the MongoDBSearch resource; do not edit) |
| Type | ClusterIP |
| Selector | `app=mongot-search-lb-0` (the Envoy pods) |
| Port | `mongot-grpc`, 27028/TCP, target port 27028 |

Envoy does not need a headless Service. Only mongot is headless, because Envoy load-balances and retries across individual mongot pods. The router sends traffic straight to the Service's pod endpoints, so ClusterIP and headless behave the same behind a Route.

The Route also sets `haproxy.router.openshift.io/balance: roundrobin`. A passthrough Route defaults to `source`, which picks the Envoy pod from the client's address and can send every connection to the same pod. `roundrobin` hands new connections to the two Envoy pods in turn. It places connections, not requests; Envoy still spreads each query across the mongot pods. The reasoning and the lab measurements are in [mongot Route Balance Rationale](mongot-route-balance-rationale.md).

Save as `mongot-search-route.yaml`:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: mongot-search
  namespace: dvh-gp6-rnd
  annotations:
    haproxy.router.openshift.io/balance: roundrobin   # passthrough default is source
spec:
  host: mongot-search-rnd.company.net     # must equal externalHostname
  to:
    kind: Service
    name: mongot-search-0-proxy-svc       # operator-created Envoy Service
  port:
    targetPort: mongot-grpc               # named port on the Service (27028)
  tls:
    termination: passthrough              # Envoy terminates TLS, not the router
  wildcardPolicy: None                    # this exact host only, never a wildcard
```

Apply and check it:

```bash
oc apply -f mongot-search-route.yaml -n $NS

oc get route mongot-search -n $NS                      # TERMINATION column must read passthrough
oc get endpoints mongot-search-0-proxy-svc -n $NS      # lists both Envoy pod IPs on 27028

# Balance algorithm set on the Route (prints roundrobin)
oc get route mongot-search -n $NS \
  -o jsonpath='{.metadata.annotations.haproxy\.router\.openshift\.io/balance}{"\n"}'

# Router hostname to give the DNS owner for the CNAME
oc get route mongot-search -n $NS -o jsonpath='{.status.ingress[0].routerCanonicalHostname}{"\n"}'
```

Ask the DNS owner to point `mongot-search-rnd.company.net` at that router hostname. mongod then connects to `mongot-search-rnd.company.net:443`; the router listens on 443 and forwards to Envoy on 27028.

If you use an Ingress instead of a Route, it needs the passthrough annotation. Without it, OpenShift defaults to edge. Set the balance annotation on the Ingress as well; OpenShift copies the Ingress annotations onto the Route it generates:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mongot-search
  namespace: dvh-gp6-rnd
  annotations:
    route.openshift.io/termination: passthrough
    haproxy.router.openshift.io/balance: roundrobin
spec:
  rules:
    - host: mongot-search-rnd.company.net
      http:
        paths:
          - path: ''
            pathType: ImplementationSpecific
            backend:
              service:
                name: mongot-search-0-proxy-svc
                port:
                  name: mongot-grpc
```

```bash
oc apply -f mongot-search-ingress.yaml -n $NS
oc get route -n $NS        # the generated Route must show passthrough

# Name, termination and balance of each Route (the generated one prints passthrough and roundrobin)
oc get route -n $NS \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.tls.termination}{"  "}{.metadata.annotations.haproxy\.router\.openshift\.io/balance}{"\n"}{end}'
```

## Step 7: Verify end to end, then clean up

**7a. Check the logs for TLS errors**

```bash
oc logs -n $NS -l app=mongot-search-0-svc --all-containers --prefix --since=10m | grep -iE 'tls|ssl|certificate|handshake'
oc logs -n $NS -l app=mongot-search-lb-0  --all-containers --prefix --since=10m | grep -iE 'tls|ssl|certificate|handshake'
```

No handshake or verify errors means the internal mTLS hop is working.

**7b. Test the public endpoint**

From a machine that can reach the public FQDN (the Route listens on 443):

```bash
openssl s_client -connect $PUBLIC_FQDN:443 -servername $PUBLIC_FQDN \
  -CAfile trust-bundle.pem </dev/null 2>/dev/null | grep -E 'subject=|issuer=|Verify return code'
```

Expected: the subject shows the public FQDN, the issuer is the company CA, and `Verify return code: 0 (ok)`. A `certificate required` alert means the endpoint also wants a client cert; that part is mongod's and is not tested here.

**7c. Confirm search works**

Run a `$search` query against a collection that has a search index. Results back means every hop is working.

To see which Envoy pod carried the queries, count the requests each one logged:

```bash
for p in $(oc get pods -n $NS -l app=mongot-search-lb-0 -o name); do
  echo "$p $(oc logs -n $NS $p -c envoy --since=1h | grep -c '"upstream_host"')"
done
```

Each mongod keeps one long-lived connection, and a connection stays on the Envoy pod it first landed on. With one mongod sending queries, one pod showing every request and the other showing 0 is expected. Once several mongod servers are connected, a pod that stays at 0 means the connections are not being spread: check the balance annotation from Step 6d.

**7d. Delete the decrypted keys**

```bash
rm -f mongot.key envoy-client.key lb.key *.pass
```

This unlinks the files; nothing overwrites them. On current macOS `rm -P` does nothing (its manual page says "This flag has no effect"), and on a solid-state or copy-on-write disk `shred` cannot overwrite a file in place either. Do this work in a directory on an encrypted disk.

Keep the original PEM files somewhere access-controlled.

- [ ] mongot (3 pods) and Envoy (2 pods) Running and Ready
- [ ] No TLS errors in mongot or Envoy logs
- [ ] Public endpoint returns `Verify return code: 0 (ok)`
- [ ] `$search` query returns results
- [ ] Decrypted key files deleted

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `bad decrypt` in Step 2 | Wrong passphrase | Rerun 2b with the correct passphrase |
| `unsupported`, or `unable to load key` with no `bad decrypt`, in Step 2 | The key's encryption is one this openssl build does not have (an old PBE cipher on OpenSSL 3, scrypt on LibreSSL) | Use the other build, for example `/opt/homebrew/bin/openssl` in place of the system's |
| Leaf count is 0 or 2 in Step 3 | Leaf marked as CA, or the PEM layout differs | Run `openssl x509 -noout -subject -text` on each cert block and sort them by hand |
| No `DNS:<fqdn>` in Step 3 check 3 | Public cert issued for a different name | Confirm the FQDN; reissue if wrong |
| `unable to get local issuer certificate` | CA bundle missing an intermediate or the root | Get the full chain from the company signer |
| `AlreadyExists` in Step 4 or 5 | Object already there; not a fresh install | Use the retrofit runbook |
| Pods stuck in `ContainerCreating` | A secret or ConfigMap name in the spec is wrong or missing | `oc describe pod` shows the missing name; compare with Step 1 |
| `unsupported certificate purpose` in logs | EKU missing Server or Client Auth | Reissue with the right EKU |
| `hostname mismatch` or SAN error | SAN does not match the name being called | Reissue with the correct SAN |
| `unknown ca` or `certificate verify failed` | A party does not trust the CA | Step 4 for mongot and Envoy; Step 6c for mongod |
| Step 7b times out | DNS not pointing at the load balancer, or a firewall | Step 6d; check `nslookup $PUBLIC_FQDN` |
| `-ext` option not recognised | macOS LibreSSL | Use the `-text \| grep` forms in this runbook |
| Operator reports a missing secret, or mongot or Envoy pods never start | TLS secret name does not follow the `certsSecretPrefix` convention | Compare `oc get secret -n $NS \| grep ent-mongot-search` with the Overview naming table; recreate any misnamed secret |
| Step 7b shows the router's certificate, not the company-signed one | Route uses edge or reencrypt termination | Step 6d: set `tls.termination: passthrough` on the `mongot-search` Route |
| One Envoy pod logs every request and the other logs none, with several mongod servers connected | Route has no balance annotation, so the router uses `source` | Step 6d: set `haproxy.router.openshift.io/balance: roundrobin`; connections already open move only when they reconnect |

Commands referenced in the table:

```bash
# Why a pod is stuck (look for a missing secret or ConfigMap under Events)
oc describe pod <pod name> -n $NS

# Which ent-mongot-search secrets exist, to compare with the naming table
oc get secret -n $NS | grep ent-mongot-search

# Does the public FQDN resolve to the router
nslookup $PUBLIC_FQDN

# Inspect each cert block in a PEM by hand
awk '/BEGIN CERTIFICATE/{n++;f=1} f{print > ("cert-"n".pem")} /END CERTIFICATE/{f=0}' "$MONGOT_PEM"
for c in cert-*.pem; do echo "== $c"; openssl x509 -in $c -noout -subject -text | grep -E '^subject|CA:'; done
rm cert-*.pem
```

## Diagram sources

The figure in the Overview comes from `diagrams/mongot-runbooks/source.html`, rendered to a light and a dark PNG; this document embeds the light one. The page holds two figures, in this order: `fresh-install-path` and `cert-parties`. To change a figure, edit the page, re-render both PNGs, and update its `alt` text and its `text` twin in the same commit.
