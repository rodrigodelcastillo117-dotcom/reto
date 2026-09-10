# NFL / FANTASY TEMPORAL DATA POLICY

For any decision snapshot at time T:

- Data with explicit capture timestamp is eligible only if `captured_at <= T`.
- Current mutable aggregates without historical snapshots are never used for historical replay.
- Week-1 prior-season statistics may be shown as contextual baseline only, never as current-season form.
- Weather without a capture timestamp is current context only, not replay-safe evidence.
- Sportsbook opening/current/close is market context only. Close cannot exist pre-kickoff.
- Injury/depth status must use the latest exact player/team/week row known by T.
- Missing values remain NULL with missing_reason.
- Historical observations (PPR p25/p50/p75 etc.) cannot be relabelled as forecast floor/median/ceiling.

The future own-model and Fantasy projection brains must persist immutable feature/projection snapshots so historical truth is never recomputed from mutable current tables.
