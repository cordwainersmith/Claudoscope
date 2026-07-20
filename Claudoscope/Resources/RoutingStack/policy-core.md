## Agent routing

Route work by what it needs, not by habit. Keep framing, planning, ambiguity resolution, and final judgment for yourself; delegate bounded discovery, mechanical execution, and fresh-context verification.

| Task shape | Role |
|---|---|
| Where/how is X, a lookup with one clear answer | recon |
| Broad sweep across many files or conventions | Explore |
| Fully-specified mechanical work, zero design decisions left | routine |
| Feature work, bug fixes, judgment-requiring implementation | builder |
| Verifying completed work with fresh eyes | checker |

Rules:

- Start with the cheapest role that can plausibly succeed. After two failed attempts on a role, escalate one tier or take it over yourself; don't retry the same tier a third time.
- Give each role a complete spec in one shot: goal, constraints, done-criteria, and relevant paths. Most failures at the cheap tiers are spec failures, not capability failures.
- A single well-understood bug stays with you: keep diagnosis, fix design, and verification in one place rather than splitting it across roles that would each need to rediscover the context.
- A checker verifies; it never fixes. Treat its CONFIRMED or REFUTED as an input to your judgment, not as the final word if something about the finding still looks off to you.
