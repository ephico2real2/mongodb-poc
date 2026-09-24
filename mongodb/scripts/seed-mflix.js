// sample_mflix-shaped documents, after the dev.to "local vector search" walkthrough,
// but with EXPLICIT vectors instead of Voyage AI autoEmbed - no API key, no egress.
const db2 = db.getSiblingDB("sample_mflix");
db2.movies.drop();
db2.movies.insertMany([
  { _id: 1, title: "The Karate Kid",  year: 1984, plot: "A bullied boy learns karate from a wise handyman.",      plot_embedding: [0.9, 0.1, 0.0, 0.1, 0.0] },
  { _id: 2, title: "Rocky",           year: 1976, plot: "An underdog boxer gets a shot at the heavyweight title.", plot_embedding: [0.8, 0.2, 0.1, 0.0, 0.0] },
  { _id: 3, title: "Jaws",            year: 1975, plot: "A great white shark terrorises a seaside town.",          plot_embedding: [0.0, 0.1, 0.9, 0.0, 0.1] },
  { _id: 4, title: "Alien",           year: 1979, plot: "A creature stalks the crew of a spaceship.",              plot_embedding: [0.0, 0.0, 0.8, 0.2, 0.1] },
  { _id: 5, title: "Field of Dreams", year: 1989, plot: "A farmer builds a baseball field in his cornfield.",      plot_embedding: [0.2, 0.9, 0.0, 0.0, 0.1] },
]);
print("docs: " + db2.movies.countDocuments({}));
try { db2.movies.dropSearchIndex("vector_index"); } catch (e) {}
db2.movies.createSearchIndex("vector_index", "vectorSearch", {
  fields: [
    { type: "vector", path: "plot_embedding", numDimensions: 5, similarity: "cosine" },
    { type: "filter", path: "year" }
  ]
});
print("vector index requested -> this call traversed the load balancer");
