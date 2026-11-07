# GNR (Graph-Native Retrieval)

AII's system is not "RAG with a graph" — it is a unified filing model where vectors and graph coexist from the start, with entities extracted and stored alongside partitions, tags automatically joining the graph as concept entities, and search returning merged graph context across Thread nodes. The term needs to capture both the neural vector space and the symbolic knowledge structure, and signal that the graph is native to the retrieval model rather than an add-on.

- Graph-native: Entities and relationships are extracted and stored at filing time (AIIDocument.entities and relationships at Sources/AII/Core/Contract/AIIDocument.swift:52-53), not post-hoc. Tags join the graph automatically as concept entities (AIIDocument.graphEntities at Sources/AII/Core/Contract/
- Unified vector space: One embedding model (voyage-4@1024, AIIModels.embedding at Sources/AII/Core/Models/AIIModels.swift:108-116) for all partitions, with optional pre-computed vectors (AIIDocument.Partition.embedding at Sources/AII/Core/Contract/AIIDocument.swift:34).
- Merged graph context: Search responses include a graph field with entity and relationship hashes merged across Thread nodes (Sewn/API/Models/Responses/Search/SearchResponse.swift:9-12), resolved via POST /v1/graph.

> Neuro-Symbolic retrieval is another more academic way to look at the design decisions around this database understanding.

## Features

**How entities and relationships are searched:**

The system uses **two different mechanisms* AND a single vector search for both:

1. **Entities are matched by text name (Deterministic)**, not by their embedding vectors. In `Database+Search.swift:63-131`, line 90 calls `graph.matchEntities(nameQuery: entityQuery)` — the query text (augmented with request entities/tags) is matched against entity names via string comparison, not vector similarity. Entities do not have an `embedding` field in `GraphStore.Entity` (`Sources/Thread/Database/Graph/GraphStore.swift:16-22`).

2. **Relationships are matched by their embedding vectors (Non-Deterministic)**. Line 92 calls `graph.matchRelationships(embedding: $0, seededBy: matchedEntityIds)` where `$0` is the query vector extracted from the embedding at line 85-87. The `Relationship` struct has an `embedding: [Float]?` field (`Sources/Thread/Database/Graph/GraphStore.swift:29-30`) — "the semantic vector for the complete subject → predicate → object assertion." The `matchRelationships(embedding:seededBy:limit:)` function at `GraphStore.swift:271-295` performs vector search on these relationship embeddings, scoring each relationship by cosine similarity to the query vector.

    1. **Predicates also have embeddings** (`Sources/Thread/Database/Graph/GraphStore.swift:38-39`) and contribute to the score. The `predicateScoreWeight: Float = 0.8` at line 52 weights predicate embedding similarity heavily in the relationship match score.

So the design is **query-based entity search + vector-based relationship search**. Entities are found by what they're named; relationships are found by semantic similarity of the assertion to the query.

**Main events that retrieve documents and partitions:**

From `Database+Search.swift:63-131` and `GraphStore.swift:342-355`:

1. **Query embedding** (`embed([query], provider:)` at line 73) — the query text is embedded into the index's vector space.

2. **Entity matching** (`graph.matchEntities(nameQuery:)` at line 90) — returns entity IDs whose names match the query text.

3. **Relationship matching** (`graph.matchRelationships(embedding:seededBy:)` at line 92) — returns relationship IDs whose embeddings are nearest to the query vector, seeded by matched entities.

4. **Predicate matching** — relationships carry predicate IDs; predicates have embeddings and contribute to the score via `predicateScoreWeight`.

5. **Partition search** (`table.search(embedding:matchedEntityIds:matchedRelationshipIds:matchedPredicateIds:identifierScores:graph:expand:...)` at `Database+Search.swift:42-53`) — the low-level index search that returns partitions filtered/adjusted by the matched graph elements.

6. **Document retrieval** via `documents(linkedToEntities:)` and `documents(linkedToRelationships:)` (`GraphStore.swift:343-355`) — unions of document IDs linked to matched entities or relationships.

> The flow is: query → embed → match entities by name, match relationships by vector → filter partitions by matched graph elements → return scored partitions with document references.

> Or a direct partition vector embedding search: query → embed → filter partitions based on embeddings.

### Classifications

**Deterministic entity search:** `graph.matchEntities(nameQuery:)` at `Database+Search.swift:90` does exact string matching on normalized names (`GraphStore.normalizeName` at `Sources/Thread/Database/Graph/GraphStore.swift:105-111` lowercases, collapses whitespace, joins components). Same query text → same matched entity IDs every time. No randomness, no approximation.

**Non-deterministic relationship search:** `graph.matchRelationships(embedding:seededBy:)` at line 92 uses cosine similarity between the query vector and relationship embeddings. The relationship embedding encodes the semantic assertion "subject → predicate → object" as a single vector (`Sources/Thread/Database/Graph/GraphStore.swift:29-30`). A query about "startup origins" or "company creation" can match a relationship like "Rao → founded → AII" even though neither "startup" nor "creation" appears in the relationship text, because the embedding captures the meaning of "founded" in context.

**Why this creates the illusion of intelligence:** The system retrieves relationships that are semantically connected to the query without being lexically present in it. When you ask about "how Rao started AII," the entity search finds "Rao" and "AII" deterministically, then the relationship search returns "founded" because its embedding is near the query vector — even though "started" was never named. The user experiences this as the system "understanding intent" rather than just matching keywords.

- This is why I usually tend to refer to Artificial Intelligence solutions as a search problem moreso. But, aren't our minds also facets of memorized lookups? Is intelligence defined by memory and lookup speed? Or is intelligence the threshold into novelty meeting practicality? Then how does novelty or the intuition to create novelty get defined?

**The seeded constraint:** `seededBy: matchedEntityIds` at line 92 constrains the relationship search to assertions involving the matched entities, preventing completely unrelated relationships from surfacing while still allowing semantic expansion within that constraint. This is why it feels intelligent rather than random — the graph structure provides grounding, and the vector search provides semantic flexibility.

> Entity matching is a lookup (same input → same output), relationship matching is a similarity search (same query vector → nearest assertions in semantic space, which may not lexically overlap with the query).
