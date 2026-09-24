# Sample data

`sample_mflix`-shaped documents, after the MongoDB dev.to walkthrough
*"My first local vector search: MongoDB Community Edition"*.

**One deliberate change: the vectors are explicit.** The article uses Voyage AI
`autoEmbed`, which needs an API key and outbound HTTPS from every `mongot` pod. These
24 documents carry hand-written 5-dimension vectors instead, so the test is
self-contained, deterministic and free.

They are *not* real embeddings. Each of the five dimensions is one theme, so
nearest-neighbour ordering is predictable and assertable:

| Dim | Theme | Examples |
|---|---|---|
| 0 | underdog / martial arts | The Karate Kid, Rocky, The Wrestler |
| 1 | americana / sport | Field of Dreams, Moneyball, Bull Durham |
| 2 | creature horror | Jaws, The Thing, Predator |
| 3 | space / sci-fi | 2001, Apollo 13, The Martian |
| 4 | crime / noir | Chinatown, The Maltese Falcon, Heat |

24 documents, 6 genres, spanning 1941–2015. Enough that text relevance ranks
meaningfully (`"detective"` returns the noir films *and* Blade Runner) and that the
`year` filter can be shown excluding a document that would otherwise rank first.

| File | Purpose |
|---|---|
| `movies.json` | the documents |
| `indexes/default.json` | full-text search index (`dynamic: true`) |
| `indexes/vector_index.json` | `vectorSearch` index, 5 dims, cosine + a `year` filter |

Load with: `./scripts/load-data.sh`
