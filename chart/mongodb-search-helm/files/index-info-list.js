// Lists every search index of the source deployment, for index-info-exporter.py: mongosh --nodb --file <this>.
// The connection string arrives in the environment, so it is in no argument list. The last line printed is
// "RESULT " and the answer as JSON.
//
// It asks for names only: the databases, their collections, and $listSearchIndexes of each collection. No document
// is read. Views and time series collections are not asked.
const source = new Mongo(process.env.SOURCE_URI);
// mongot keeps its own catalog in __mdb_internal_search: not a place a search index is made.
const skipped = new Set(["admin", "local", "config", "__mdb_internal_search"]);
const indexes = [];
let collections = 0;

for (const name of source.getDB("admin").adminCommand({listDatabases: 1, nameOnly: true}).databases.map(d => d.name)) {
  if (skipped.has(name)) continue;
  const database = source.getDB(name);
  for (const collection of database.getCollectionInfos({type: "collection"}, {nameOnly: true}).map(c => c.name)) {
    if (collection.startsWith("system.")) continue;
    collections++;
    for (const index of database.getCollection(collection).aggregate([{$listSearchIndexes: {}}]).toArray()) {
      // storedSource is true, false, {include: [...]} or {exclude: [...]}; absent means none.
      const stored = (index.latestDefinition || {}).storedSource;
      const paths = stored && (stored.include || stored.exclude) || [];
      indexes.push({
        id: index.id, database: name, collection: collection, name: index.name,
        storedSource: stored === true ? "all" : !stored ? "none" : stored.include ? "include" : stored.exclude ? "exclude" : "none",
        storedSourcePaths: paths.length,
        hosts: (index.statusDetail || []).length,
      });
    }
  }
}
print("RESULT " + JSON.stringify({collections: collections, indexes: indexes}));
