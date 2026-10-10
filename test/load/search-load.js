// Concurrent $search queries through mongod, in steps of concurrency: the generator of test/load/run.sh.
// Run with mongosh --nodb. Env: MONGO_URI; STEPS ("1,4,16"), SECONDS (a step), PAUSE (between steps), DB, COLL,
// INDEX, TERMS (comma separated), LIMIT.
// It prints one JSON line a step: the concurrency, the searches completed and failed, searches a second, and the
// latency in ms as the caller saw it. The queries go through the Node driver inside mongosh, so that they really
// run at once: mongosh's own shell methods wait for each other. One mongosh is one thread: analyze.py shows the
// load pod's CPU, and at about one core the generator is what limits the run.
const env = process.env;
const steps = (env.STEPS || "1,4,16").split(",").map(Number);
const seconds = Number(env.SECONDS || 60);
const terms = (env.TERMS || "detective,love,war,space,family,murder,king,night").split(",");
const limit = Number(env.LIMIT || 10);
const shell = new Mongo(env.MONGO_URI);
const client = shell._serviceProvider.mongoClient;
const coll = client.db(env.DB || "sample_mflix").collection(env.COLL || "movies");
const pipeline = (q) => [{ $search: { index: env.INDEX || "default", text: { query: q, path: { wildcard: "*" } } } },
                         { $limit: limit }, { $project: { _id: 1, title: 1 } }];
const pct = (a, p) => a.length ? a[Math.min(a.length - 1, Math.floor(a.length * p))] : null;
const r1 = (x) => (typeof x === "number" ? Math.round(x * 10) / 10 : null);

async function step(concurrency) {
  const lat = []; let failed = 0, docs = 0, firstError = "";
  const end = Date.now() + seconds * 1000; const t0 = Date.now();
  const worker = async (w) => {
    let i = w;
    while (Date.now() < end) {
      const s = process.hrtime.bigint();
      try { const r = await coll.aggregate(pipeline(terms[i++ % terms.length])).toArray(); docs += r.length;
            lat.push(Number(process.hrtime.bigint() - s) / 1e6); }
      catch (e) { failed++; if (!firstError) firstError = String(e.message || e).slice(0, 160); }
    }
  };
  await Promise.all(Array.from({ length: concurrency }, (_, w) => worker(w)));
  const took = (Date.now() - t0) / 1000; lat.sort((a, b) => a - b);
  print(JSON.stringify({ step: "done", concurrency, start: new Date(t0).toISOString(), end: new Date().toISOString(),
    ok: lat.length, failed, per_second: r1(lat.length / took), docs,
    ms: { p50: r1(pct(lat, 0.5)), p95: r1(pct(lat, 0.95)), p99: r1(pct(lat, 0.99)), max: r1(lat.length ? lat[lat.length - 1] : null) },
    first_error: firstError }));
}
(async () => {
  print(JSON.stringify({ step: "start", steps, seconds, terms: terms.length, limit, at: new Date().toISOString() }));
  for (const c of steps) { await step(c); await new Promise((r) => setTimeout(r, Number(env.PAUSE || 15) * 1000)); }
  print(JSON.stringify({ step: "end", at: new Date().toISOString() }));
  await client.close(); quit(0);
})().catch((e) => { print(JSON.stringify({ step: "error", error: String(e) })); quit(1); });
