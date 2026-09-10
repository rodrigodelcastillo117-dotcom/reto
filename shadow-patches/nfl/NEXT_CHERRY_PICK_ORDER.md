# SAFE CHERRY-PICK ORDER AFTER SOCCER GATE

Do not cherry-pick while SOCCER predictive sanity is still the active P0 gate.

When auditor releases the next backend phase:

1. `nfl_factual_dossier_v1.sql` (optional precursor; v2 supersedes it)
2. `nfl_super_dossier_v2.sql`
3. `nfl_super_dossier_contract_tests.sql`
4. `fantasy_equipo_player_context_v1.sql` (optional precursor; v2 supersedes it)
5. `fantasy_player_super_context_v2.sql`
6. `fantasy_super_context_contract_tests.sql`
7. review docs/read contracts

Compile/adapt on a disposable data-safe branch first. Never apply blindly to production. Resolve any schema drift found after SOCCER changes and rerun temporal/adversarial tests before integrating into the canonical backend branch.
