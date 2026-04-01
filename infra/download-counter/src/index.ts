import { decideCounting, type ReleaseAvailability } from "./counting-policy";

interface Env {
  DOWNLOAD_COUNTS: KVNamespace;
  STATS_TOKEN: string;
}

const VERSION_PATTERN = /^v\d+\.\d+\.\d+$/;
const GITHUB_BASE = "https://github.com/cordwainersmith/Claudoscope/releases/download";
const RELEASE_EXISTS_CACHE_PREFIX = "release:exists:";
const RELEASE_EXISTS_TTL_SECONDS = 60 * 60 * 24 * 7;
const RELEASE_MISSING_TTL_SECONDS = 120;

function classifyUserAgent(ua: string): string {
  const lower = ua.toLowerCase();
  if (lower.includes("homebrew")) return "homebrew";
  if (lower.includes("curl")) return "curl";
  if (lower.includes("wget")) return "wget";
  if (lower.includes("mozilla") || lower.includes("chrome") || lower.includes("safari")) return "browser";
  return "other";
}

async function incrementCounter(kv: KVNamespace, key: string): Promise<void> {
  const current = parseInt((await kv.get(key)) || "0", 10);
  await kv.put(key, String(current + 1));
}

async function getCachedReleaseAvailability(
  kv: KVNamespace,
  version: string
): Promise<ReleaseAvailability | null> {
  const value = await kv.get(`${RELEASE_EXISTS_CACHE_PREFIX}${version}`);
  if (value === "1") return "exists";
  if (value === "0") return "missing";
  return null;
}

async function setCachedReleaseAvailability(
  kv: KVNamespace,
  version: string,
  availability: Exclude<ReleaseAvailability, "unknown">
): Promise<void> {
  const ttl = availability === "exists" ? RELEASE_EXISTS_TTL_SECONDS : RELEASE_MISSING_TTL_SECONDS;
  const value = availability === "exists" ? "1" : "0";
  await kv.put(`${RELEASE_EXISTS_CACHE_PREFIX}${version}`, value, { expirationTtl: ttl });
}

async function checkReleaseAvailability(redirectUrl: string): Promise<ReleaseAvailability> {
  try {
    const response = await fetch(redirectUrl, {
      method: "HEAD",
      redirect: "follow",
    });

    if (response.ok) return "exists";
    if (response.status === 404) return "missing";
    return "unknown";
  } catch {
    return "unknown";
  }
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    // GET /badge - public shields.io endpoint badge
    if (url.pathname === "/badge") {
      const totalRaw = parseInt((await env.DOWNLOAD_COUNTS.get("downloads:total")) || "0", 10);
      let message: string;
      if (totalRaw >= 1000) {
        message = (totalRaw / 1000).toFixed(1).replace(/\.0$/, "") + "k";
      } else {
        message = String(totalRaw);
      }

      return new Response(
        JSON.stringify({
          schemaVersion: 1,
          label: "downloads",
          message,
          color: "blue",
        }),
        {
          headers: {
            "Content-Type": "application/json",
            "Cache-Control": "max-age=300",
          },
        }
      );
    }

    // GET /stats - protected stats endpoint
    if (url.pathname === "/stats") {
      const auth = request.headers.get("Authorization");
      if (!auth || auth !== `Bearer ${env.STATS_TOKEN}`) {
        return new Response("Unauthorized", { status: 401 });
      }

      const keys = await env.DOWNLOAD_COUNTS.list({ prefix: "downloads:" });
      const stats: Record<string, number> = {};
      for (const key of keys.keys) {
        const value = await env.DOWNLOAD_COUNTS.get(key.name);
        stats[key.name] = parseInt(value || "0", 10);
      }

      return new Response(JSON.stringify(stats, null, 2), {
        headers: { "Content-Type": "application/json" },
      });
    }

    // GET /:version/Claudoscope.dmg - download redirect
    const match = url.pathname.match(/^\/([^/]+)\/Claudoscope\.dmg$/);
    if (!match) {
      return new Response("Not Found", { status: 404 });
    }

    const version = match[1];
    if (!VERSION_PATTERN.test(version)) {
      return new Response("Not Found", { status: 404 });
    }

    const ua = request.headers.get("User-Agent") || "";
    const category = classifyUserAgent(ua);
    const type = url.searchParams.get("type") === "update" ? "update" : "download";
    const redirectUrl = `${GITHUB_BASE}/${version}/Claudoscope.dmg`;

    // Fire-and-forget validation and KV writes
    ctx.waitUntil(
      (async () => {
        try {
          const cachedAvailability = await getCachedReleaseAvailability(env.DOWNLOAD_COUNTS, version);
          const probedAvailability =
            cachedAvailability === null ? await checkReleaseAvailability(redirectUrl) : null;
          const decision = decideCounting(cachedAvailability, probedAvailability);

          if (decision.cacheAvailability !== null) {
            await setCachedReleaseAvailability(env.DOWNLOAD_COUNTS, version, decision.cacheAvailability);
          }

          if (!decision.shouldCount) return;

          await Promise.all([
            incrementCounter(env.DOWNLOAD_COUNTS, `downloads:${version}`),
            incrementCounter(env.DOWNLOAD_COUNTS, "downloads:total"),
            incrementCounter(env.DOWNLOAD_COUNTS, `downloads:ua:${category}`),
            incrementCounter(env.DOWNLOAD_COUNTS, `downloads:type:${type}`),
          ]);
        } catch {
          // Background validation/counting failure must not affect the redirect
        }
      })()
    );

    return new Response(null, {
      status: 302,
      headers: {
        Location: redirectUrl,
        "Cache-Control": "no-store",
      },
    });
  },
} satisfies ExportedHandler<Env>;
