# Cost Estimation

Claude Code Rewinder estimates session costs from raw token counts stored in JSONL session files. Costs are never billed or metered; they are informational estimates based on published API pricing.

## How it works

### 1. Token extraction (server)

The JSONL session parser (`server/services/session-parser.ts`) reads each message in a session file and accumulates four token counters from the `usage` field on assistant responses:

- `totalInputTokens` - prompt tokens sent to the model
- `totalOutputTokens` - completion tokens returned by the model
- `totalCacheReadTokens` - tokens served from prompt cache (cheaper than input)
- `totalCacheCreationTokens` - tokens written into prompt cache (more expensive than input on Anthropic, free on Vertex)

It also records the `primaryModel` string (e.g. `claude-opus-4-6-20250313`).

### 2. Model family detection

`getModelFamily()` in `shared/pricing.ts` maps a model ID string to a pricing family:

| Pattern | Family | Example model IDs |
|---|---|---|
| Contains `opus` + version 4.5+ | `opus` | `claude-opus-4-5-20250120`, `claude-opus-4-6-20250313` |
| Contains `opus` + older version | `opus4` | `claude-opus-4-0-20250115` |
| Contains `haiku` + version 4.5+ | `haiku` | `claude-haiku-4-5-20251001` |
| Contains `haiku` + older version | `haiku3` | `claude-haiku-3-5-20241022` |
| Contains `sonnet` | `sonnet` | `claude-sonnet-4-5-20250514` |
| No match | falls back to `sonnet` | - |

The version split matters because Opus 4.5+ and Haiku 4.5+ have significantly different pricing from their predecessors.

### 3. Pricing tables

Three pricing tables are defined in `shared/pricing.ts`, all in dollars per million tokens (MTok):

**Anthropic API (direct)**

| Family | Input | Output | Cache Read | Cache Creation |
|---|---|---|---|---|
| opus | $5.00 | $25.00 | $0.50 | $6.25 |
| opus4 | $15.00 | $75.00 | $1.50 | $18.75 |
| sonnet | $3.00 | $15.00 | $0.30 | $3.75 |
| haiku | $1.00 | $5.00 | $0.10 | $1.25 |
| haiku3 | $0.25 | $1.25 | $0.025 | $0.3125 |

**Vertex AI (Global region)**

Same input/output/cache-read rates as Anthropic, but **cache creation is $0** (Vertex does not separately bill cache writes).

**Vertex AI (Regional: us-east5, europe-west1, asia-southeast1)**

10% surcharge over global rates on input, output, and cache read. Cache creation remains $0.

### 4. Cost formula

For a single session:

```
cost = (inputTokens / 1,000,000) * rate.input
     + (outputTokens / 1,000,000) * rate.output
     + (cacheReadTokens / 1,000,000) * rate.cacheRead
     + (cacheCreationTokens / 1,000,000) * rate.cacheCreation
```

This is implemented in `estimateCostFromTokens()` in `shared/pricing.ts`.

### 5. Where costs are calculated

Costs are computed in two places, both using the same shared pricing logic:

**Server-side (analytics)**
`server/services/analytics-engine.ts` computes aggregate costs for the analytics dashboard. The client sends `provider` and `region` as query parameters when fetching `/api/analytics`. The engine builds a pricing table from those params, then iterates all sessions in the time range, calling `estimateCostFromTokens()` per session to produce daily totals, per-project breakdowns, and per-model splits.

**Client-side (per-session display)**
`client/components/chat/ChatView.tsx` and `client/utils/format-tokens.ts` use `getPricingTable()` with the current `pricingConfig` from the Zustand store to show cost estimates inline in the chat view.

### 6. User configuration

Users configure pricing via **Settings > Pricing** in the UI. Two options:

- **Provider**: Anthropic or Vertex AI
- **Region** (Vertex only): Global, us-east5, europe-west1, asia-southeast1

Changes require clicking **Apply** before taking effect. The selection is persisted to `localStorage` under the `rewinder-settings` key. The default is `Vertex AI / Global`.

When the pricing config changes, the analytics dashboard re-fetches data from the server with the new provider/region params, and all per-session cost displays update on the client side.

### Key caveat

These are estimates. The actual billed amount depends on factors Rewinder cannot observe, such as batch vs. real-time pricing tiers, committed-use discounts, or billing adjustments. The estimates assume standard on-demand rates.
