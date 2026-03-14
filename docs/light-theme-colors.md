# Light Theme Colors

All color tokens are defined as CSS custom properties in `client/styles/globals.css` under `:root`. Tailwind classes reference these via the mappings in `tailwind.config.ts`.

---

## Backgrounds

| Token | Value | Usage |
|---|---|---|
| `--color-background-primary` | `#ffffff` | Main content area, cards |
| `--color-background-secondary` | `#F0F0EB` | Sidebar, secondary panels |
| `--color-background-tertiary` | `#E6E6E1` | Body/page background, skeleton loaders |

The palette uses warm-neutral beige-tinted grays rather than pure cool grays.

## Text

| Token | Value | Usage |
|---|---|---|
| `--color-text-primary` | `#1a1a1a` | Main body text |
| `--color-text-secondary` | `#737373` | Secondary labels, metadata |
| `--color-text-tertiary` | `#999999` | Placeholders, disabled text |

## Borders (alpha-based)

| Token | Value | Usage |
|---|---|---|
| `--color-border-tertiary` | `rgba(0, 0, 0, 0.08)` | Subtle dividers |
| `--color-border-secondary` | `rgba(0, 0, 0, 0.15)` | Standard borders, scrollbar thumb |
| `--color-border-primary` | `rgba(0, 0, 0, 0.25)` | Strong borders, scrollbar hover |

## Semantic Colors

Each semantic category has a background, text, and border token.

### Info
| Token | Value |
|---|---|
| `--color-background-info` | `#E8F0FE` (soft blue) |
| `--color-text-info` | `#1967D2` (Google blue) |
| `--color-border-info` | `#1967D2` |

### Success
| Token | Value |
|---|---|
| `--color-background-success` | `#E6F4EA` (soft green) |
| `--color-text-success` | `#137333` (forest green) |
| `--color-border-success` | `#137333` |

### Warning
| Token | Value |
|---|---|
| `--color-background-warning` | `#FEF7E0` (soft yellow) |
| `--color-text-warning` | `#BA7517` (amber) |
| `--color-border-warning` | `#BA7517` |

### Danger
| Token | Value |
|---|---|
| `--color-background-danger` | `#FCE8E6` (soft red) |
| `--color-text-danger` | `#C5221F` (crimson) |
| `--color-border-danger` | `#C5221F` |

## Chart Colors (shared across themes)

Defined directly in `tailwind.config.ts`, not as CSS custom properties.

| Name | Value | Tailwind Class |
|---|---|---|
| Purple | `#7F77DD` | `text-chart-purple`, `bg-chart-purple` |
| Teal | `#5DCAA5` | `text-chart-teal`, `bg-chart-teal` |
| Blue | `#85B7EB` | `text-chart-blue`, `bg-chart-blue` |
| Coral | `#D85A30` | `text-chart-coral`, `bg-chart-coral` |
| Pink | `#D4537E` | `text-chart-pink`, `bg-chart-pink` |
| Amber | `#BA7517` | `text-chart-amber`, `bg-chart-amber` |
| Gray | `#B4B2A9` | `text-chart-gray`, `bg-chart-gray` |

## Other Tokens

| Token | Value |
|---|---|
| `--border-radius-sm` | `4px` |
| `--border-radius-md` | `8px` |
| `--border-radius-lg` | `12px` |
| `--border-radius-pill` | `99px` |
| `--font-sans` | `-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif` |
| `--font-mono` | `"SF Mono", "Fira Code", "JetBrains Mono", monospace` |
