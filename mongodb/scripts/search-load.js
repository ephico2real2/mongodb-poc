const db2 = db.getSiblingDB("search_demo");
const terms = ["gold","silver","copper","golden","platinum"];
let ok = 0;
for (let i = 0; i < 40; i++) {
  const t = terms[i % terms.length];
  const r = db2.movies.aggregate([
    { $search: { index: "default", text: { query: t, path: { wildcard: "*" } } } },
    { $project: { _id: 1 } }
  ]).toArray();
  ok += (r.length >= 0) ? 1 : 0;
}
print("queries completed: " + ok + "/40");
