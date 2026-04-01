import { decideCounting, type ReleaseAvailability } from "../src/counting-policy";

type CacheValue = "exists" | "missing" | null;

interface Scenario {
  name: string;
  cached: ReleaseAvailability | null;
  probed: ReleaseAvailability | null;
  expectedShouldCount: boolean;
  expectedCache: CacheValue;
}

const scenarios: Scenario[] = [
  {
    name: "cached exists always counts",
    cached: "exists",
    probed: null,
    expectedShouldCount: true,
    expectedCache: null,
  },
  {
    name: "cached missing always skips",
    cached: "missing",
    probed: null,
    expectedShouldCount: false,
    expectedCache: null,
  },
  {
    name: "cached missing wins even if probe says exists",
    cached: "missing",
    probed: "exists",
    expectedShouldCount: false,
    expectedCache: null,
  },
  {
    name: "cache miss and probe exists counts and caches exists",
    cached: null,
    probed: "exists",
    expectedShouldCount: true,
    expectedCache: "exists",
  },
  {
    name: "cache miss and probe missing skips and caches missing",
    cached: null,
    probed: "missing",
    expectedShouldCount: false,
    expectedCache: "missing",
  },
  {
    name: "cache miss and probe unknown skips without caching",
    cached: null,
    probed: "unknown",
    expectedShouldCount: false,
    expectedCache: null,
  },
];

for (const scenario of scenarios) {
  const actual = decideCounting(scenario.cached, scenario.probed);
  if (
    actual.shouldCount !== scenario.expectedShouldCount ||
    actual.cacheAvailability !== scenario.expectedCache
  ) {
    throw new Error(
      `Scenario failed: ${scenario.name}. got shouldCount=${String(actual.shouldCount)} cache=${String(actual.cacheAvailability)}`
    );
  }
}
