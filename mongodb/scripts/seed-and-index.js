const db2 = db.getSiblingDB("search_demo");
db2.movies.drop();
db2.movies.insertMany([
  { _id: 1, title: "Gold market report",      body: "gold prices rose sharply" },
  { _id: 2, title: "Silver mining quarterly", body: "silver output declined" },
  { _id: 3, title: "Copper futures",          body: "copper demand steady" },
  { _id: 4, title: "Golden age of cinema",    body: "classic films retrospective" },
  { _id: 5, title: "Platinum standard",       body: "platinum reserves grew" },
]);
print("docs inserted: " + db2.movies.countDocuments({}));
try {
  db2.movies.createSearchIndex("default", { mappings: { dynamic: true } });
  print("createSearchIndex issued -> this call traversed the MetalLB VIP");
} catch (e) {
  print("createSearchIndex ERROR: " + e.message);
}
