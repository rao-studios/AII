# GNR (Graph-Native Retrieval)

AII's system is not "RAG with a graph" — it is a unified filing model where vectors and graph coexist from the start, with entities extracted and stored alongside partitions, tags automatically joining the graph as concept entities, and search returning merged graph context across Thread nodes. The term needs to capture both the neural vector space and the symbolic knowledge structure, and signal that the graph is native to the retrieval model rather than an add-on.

- Graph-native: Entities and relationships are extracted and stored at filing time (AIIDocument.entities and relationships at Sources/AII/Core/Contract/AIIDocument.swift:52-53), not post-hoc. Tags join the graph automatically as concept entities (AIIDocument.graphEntities at Sources/AII/Core/Contract/
- Unified vector space: One embedding model (voyage-4@1024, AIIModels.embedding at Sources/AII/Core/Models/AIIModels.swift:108-116) for all partitions, with optional pre-computed vectors (AIIDocument.Partition.embedding at Sources/AII/Core/Contract/AIIDocument.swift:34).
- Merged graph context: Search responses include a graph field with entity and relationship hashes merged across Thread nodes (Sewn/API/Models/Responses/Search/SearchResponse.swift:9-12), resolved via POST /v1/graph.

> Neuro-Symbolic retrieval is another more academic way to look at the design decisions around this database understanding.

