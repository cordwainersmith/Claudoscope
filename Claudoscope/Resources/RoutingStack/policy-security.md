| Task shape | Role |
|---|---|
| Pre-approval security evidence: authn/authz, secrets, crypto, validation | security-review |
| Approved security-sensitive implementation | security-build |

Route security-sensitive work away from the general roles above. security-review only gathers evidence; it never implements. security-build only runs after you've approved a stable, scoped contract, never before.
