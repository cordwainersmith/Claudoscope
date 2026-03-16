interface Env {
  DOWNLOAD_COUNTS: KVNamespace;
  STATS_TOKEN: string;
}

const VERSION_PATTERN = /^v\d+\.\d+\.\d+$/;
const GITHUB_BASE = "https://github.com/cordwainersmith/Claudoscope/releases/download";

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

    // Fire-and-forget KV writes
    ctx.waitUntil(
      (async () => {
        try {
          await Promise.all([
            incrementCounter(env.DOWNLOAD_COUNTS, `downloads:${version}`),
            incrementCounter(env.DOWNLOAD_COUNTS, "downloads:total"),
            incrementCounter(env.DOWNLOAD_COUNTS, `downloads:ua:${category}`),
            incrementCounter(env.DOWNLOAD_COUNTS, `downloads:type:${type}`),
          ]);
        } catch {
          // KV failure must not affect the redirect
        }
      })()
    );

    const redirectUrl = `${GITHUB_BASE}/${version}/Claudoscope.dmg`;
    return new Response(null, {
      status: 302,
      headers: {
        Location: redirectUrl,
        "Cache-Control": "no-store",
      },
    });
  },
} satisfies ExportedHandler<Env>;
