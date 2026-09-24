const db2 = db.getSiblingDB("search_demo");
const r = db2.movies.aggregate([
  { $search: { index: "default", text: { query: "gold", path: { wildcard: "*" } } } },
  { $project: { _id: 1, title: 1, score: { $meta: "searchScore" } } }
]).toArray();
print("=== $search results: " + r.length + " ===");
r.forEach(d => print("  _id=" + d._id + "  " + d.title + "  score=" + d.score.toFixed(3)));
