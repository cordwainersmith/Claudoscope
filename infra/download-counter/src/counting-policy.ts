export type ReleaseAvailability = "exists" | "missing" | "unknown";

export interface CountingDecision {
  shouldCount: boolean;
  cacheAvailability: "exists" | "missing" | null;
}

export function decideCounting(
  cachedAvailability: ReleaseAvailability | null,
  probedAvailability: ReleaseAvailability | null
): CountingDecision {
  if (cachedAvailability === "exists") {
    return { shouldCount: true, cacheAvailability: null };
  }

  if (cachedAvailability === "missing") {
    return { shouldCount: false, cacheAvailability: null };
  }

  if (probedAvailability === "exists") {
    return { shouldCount: true, cacheAvailability: "exists" };
  }

  if (probedAvailability === "missing") {
    return { shouldCount: false, cacheAvailability: "missing" };
  }

  return { shouldCount: false, cacheAvailability: null };
}
