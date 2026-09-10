# SUPER PAGE IMPLEMENTATION STATUS

This branch is intentionally parallel/shadow and does not touch production.

HEAD includes:
- NFL factual dossier v1
- NFL super dossier v2
- NFL super dossier invariants
- Fantasy player context v1
- Fantasy player super context v2
- Fantasy context invariants
- NFL super-page read contract
- implementation/data-gap handoff

The UI target is the same shared visual pattern already staged in Lovable for Soccer/MLB/NFL: hero + probability graph (disabled for NFL until own model) + expected score block when real + ordered accordions/tabs.

This backend work is designed so the future UI can replace many placeholder `PENDIENTE` states with real data while preserving fail-close semantics.
