# Claudoscope Download Counter

Cloudflare Worker that counts Homebrew cask downloads and redirects to GitHub Releases.

```
brew install --cask claudoscope
  -> GET https://dl.claudoscope.com/v0.3.7/Claudoscope.dmg
  -> CF Worker: increment KV counter (fire-and-forget)
  -> 302 redirect -> https://github.com/.../releases/download/v0.3.7/Claudoscope.dmg
```

## Setup

### 1. Install dependencies

```bash
cd infra/download-counter
npm install
```

### 2. Create KV namespace

```bash
wrangler kv namespace create DOWNLOAD_COUNTS
```

Copy the output `id` into `wrangler.toml` (replace `REPLACE_WITH_KV_NAMESPACE_ID`).

### 3. Set the stats token secret

```bash
wrangler secret put STATS_TOKEN
```

### 4. Configure custom domain

In the Cloudflare dashboard:
1. Add `dl.claudoscope.com` as a CNAME pointing to the Worker
2. Or use the Workers Routes UI to map `dl.claudoscope.com/*` to this Worker

### 5. Deploy

```bash
npm run deploy
```

## Local development

```bash
npm run dev
curl -v http://localhost:8787/v0.3.7/Claudoscope.dmg   # should 302 redirect
curl -H "Authorization: Bearer <token>" http://localhost:8787/stats
```

## Endpoints

- `GET /:version/Claudoscope.dmg` - Counts the download and redirects to GitHub Releases
- `GET /stats` - Returns download counts (requires `Authorization: Bearer <token>` header)

## How counting works

Each download request increments three KV keys (fire-and-forget, never blocks the redirect):
- `downloads:{version}` - per-version count
- `downloads:total` - total across all versions
- `downloads:ua:{category}` - by user-agent category (homebrew, curl, wget, browser, other)

Note: KV counters are not atomic. Under very high concurrency, counts may slightly undercount due to read-modify-write races. This is acceptable for download tracking.
