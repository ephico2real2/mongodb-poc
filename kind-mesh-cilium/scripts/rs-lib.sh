# Shared by the election tuning scripts: mongosh through the replica set from mesh1's member, and a settings reconfig.
# Sourced after kind-mesh/scripts/lib.sh's lab_env; expects $out. The password goes on stdin, never in an argument.
# shellcheck shell=bash disable=SC2034,SC2154  # rs_defaults is for the sourcing scripts; they set $out
rs_plain="mongodb://mongo-mesh0.mongodb.svc.cluster.local,mongo-mesh1.mongodb.svc.cluster.local,mongo-mesh2.mongodb.svc.cluster.local/?replicaSet=rs0&tls=true&tlsCAFile=/run/mongod/ca.crt"
rs_defaults="electionTimeoutMillis=10000 catchUpTimeoutMillis=-1 heartbeatTimeoutSecs=10"
rs_eval() { # script on stdin, logged in
  local pw
  pw=$(kubectl --context kind-mesh0 -n mongodb get secret mongo-admin -o jsonpath='{.data.password}' | base64 -d)
  { printf 'db.getSiblingDB("admin").auth("labAdmin", "%s");\n' "$pw"; cat; } \
    | kubectl --context kind-mesh1 -n mongodb exec -i mongo-0 -c mongod -- mongosh --quiet "$rs_plain" --file /dev/stdin 2>&1
}
# Sets <key=value ...> in the replica set's settings, on its primary; logs the settings after, with the time.
reconfig() {
  local js="const cfg = rs.conf();" kv
  for kv in "$@"; do js+=" cfg.settings.${kv%%=*} = ${kv#*=};"; done
  { date -u +"# %FT%TZ: $*"
    printf '%s\n%s\n' "$js" \
      'const r = rs.reconfig(cfg), c = rs.conf(), s = c.settings; print("reconfig ok: " + r.ok + "; version " + c.version + "; electionTimeoutMillis " + s.electionTimeoutMillis + ", catchUpTimeoutMillis " + s.catchUpTimeoutMillis + ", heartbeatTimeoutSecs " + s.heartbeatTimeoutSecs)' \
      | rs_eval
  } | tee -a "$out/election-tuning-reconfig.txt"
}
# "<term> <primary member>", e.g. "9 mongo-mesh0".
rs_term() { printf 'const s = rs.status(); print(s.term + " " + ((s.members.find(m => m.stateStr === "PRIMARY") || {name: "none"}).name.split(".")[0]))' | rs_eval; }
