# Sample data

`sample_mflix`-shaped documents, after the MongoDB dev.to walkthrough
*"My first local vector search: MongoDB Community Edition"*.

**One deliberate change: the vectors are explicit.** The article uses Voyage AI
`autoEmbed`, which needs an API key and outbound HTTPS from every `mongot` pod. These
five documents carry hand-written 5-dimension vectors instead, so the test is
self-contained, deterministic and free.

They are *not* real embeddings. They are positioned so nearest-neighbour ordering is
predictable and assertable — enough to prove the vector path end to end, not to
demonstrate semantic quality.

| File | Purpose |
|---|---|
| `movies.json` | the documents |
| `indexes/default.json` | full-text search index (`dynamic: true`) |
| `indexes/vector_index.json` | `vectorSearch` index, 5 dims, cosine + a `year` filter |

Load with: `./scripts/load-data.sh`
