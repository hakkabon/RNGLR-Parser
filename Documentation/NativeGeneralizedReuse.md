# Phase 11: Native generalized reuse

RNGLR retains two distinct native object graphs: graph-structured-stack nodes
and shared-packed-parse-forest nodes. Both use stable engine identities and
explicit stable-token dependencies. Invalidating a token removes its direct
users and every parent whose outgoing topology reaches an invalid node;
unrelated nodes retain their class identity across the edit.

`RNGLRParser.incrementalArtifactIdentity` fingerprints the start symbol,
ordered productions, and the generated ACTION/GOTO tables, including their
numeric state mapping. An
`RNGLRIncrementalWorkspace` binds its GSS and SPPF arenas to that identity.
Changing artifacts clears both arenas in one operation and reports
`incompatibleArtifact`, preventing a graph from one automaton being paired with
a forest from another.

`invalidateWithEvidence(tokens:)` returns the exact invalidated and retained
sets for each arena. Once the caller reconstructs the missing closure,
`executionEvidence(rebuiltGraphNodes:rebuiltForestNodes:)` projects GSS and
forest reuse into the shared Phase 9 evidence schema. Differential tests compare
the rebuilt topology and payloads with clean reconstruction while also checking
that retained nodes preserve object identity.

Stable token identity remains a lexer or language-kit responsibility; RNGLR
does not infer continuity from token text or source offsets.
