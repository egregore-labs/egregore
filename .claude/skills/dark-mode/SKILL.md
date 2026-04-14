---
name: dark-mode
description: "Use when generating or modifying any visual output that renders in a browser or artifact viewer: HTML pages, CSS, React SSR components, Egregore artifacts, markdown renderers, web components, design-system tokens, Tailwind themes, or standalone demos. Triggers on requests involving dark mode, theme toggles, color systems, card surfaces, browser rendering, or visual polish. The load-bearing lesson: if React SSR emits an inline hex color through `style={}`, CSS dark-mode overrides cannot reach it, so every theme-sensitive color must be emitted as `var(--token)` rather than a resolved hex. Do not use for TUI output, plain markdown files, or non-visual code."
---

# Dark Mode

This skill is a behavioral constraint system for Egregore visual output. It exists to stop the most common failure mode before it happens: an otherwise correct dark palette being defeated by SSR-emitted inline styles.

## The Bitter Lesson

**If React SSR renders `style="color:#2A2A2A"`, dark mode loses.** CSS variable overrides only work when the rendered value is itself a variable reference. If a color must adapt across themes, emit `var(--token)` at the render site. Not in comments. Not in a later stylesheet. In the actual rendered style.

Treat this as a hard constraint:

1. Every theme-sensitive color in CSS or inline `style` props must use `var(--token)`.
2. Theme state lives on `<html data-theme="...">`.
3. Theme restoration happens before paint, in `<head>`.

Everything else is secondary.

## When To Invoke

- Generating standalone HTML
- Building or editing React SSR output
- Writing CSS for Egregore artifacts
- Modifying markdown renderers that emit inline styles
- Adding a theme toggle
- Extending the design system with dark surfaces
- Producing any browser-rendered visual artifact

## Not This

- TUI terminal output; use `/tui-design`
- Plain markdown files that do not render styled HTML
- Backend or CLI code with no visual surface
- Non-rendered config changes unrelated to color or theme behavior

## The Egregore Dark Palette

The palette stays warm. The base dark background is `#1D1611`, not pure black. Accent colors stay the same in both modes because terracotta and muted blue already survive the transition cleanly.

### Core CSS Variables

| Token | Light | Dark | Role |
|---|---|---|---|
| `--cream` | `#F5F2ED` | `#1D1611` | Page background; inverted selection text in dark |
| `--black` | `#16100B` | `rgba(255, 255, 255, 0.92)` | Primary text, titles, completed badges |
| `--dark` | `#2A2A2A` | `rgba(255, 255, 255, 0.75)` | Body text, secondary copy, blocked badge fill |
| `--border` | `#E0D8CC` | `rgba(255, 255, 255, 0.06)` | Rules, card borders, checkbox outlines |
| `--muted` | `#8a8578` | `rgba(255, 255, 255, 0.50)` | Metadata, labels, de-emphasized text |
| `--warm-gray` | `#d4cfc5` | `rgba(255, 255, 255, 0.30)` | Tertiary marks, dim text, faint structure |
| `--terminal-bg` | `#1D1611` | `#161210` | Code blocks and terminal surfaces |

### Dark-Only Surface Helpers

Use these when a component needs separation beyond the base variable set. The current artifacts shell uses `--card-bg` and `--code-bg`; `--elevated-bg` and `--strong-border` come from the same shipped token palette and are the right extensions when extra depth is needed.

| Token | Light Fallback | Dark | Role |
|---|---|---|---|
| `--card-bg` | `#FFFFFF` | `#241E19` | Cards, pills, theme toggle background |
| `--code-bg` | `rgba(59, 45, 33, 0.06)` | `rgba(212, 135, 90, 0.08)` | Inline code background |
| `--elevated-bg` | `#FFFFFF` | `#2A231D` | Raised panels or overlays above cards |
| `--strong-border` | `#d4cfc5` | `rgba(255, 255, 255, 0.10)` | Emphasized borders when `--border` is too faint |

### Palette Rules

- Warm character first: dark surfaces are brown-black, not blue-black and not pure black.
- Text opacity hierarchy is fixed: `0.92` primary, `0.75` secondary, `0.50` muted, `0.30` dim.
- `--terracotta` stays `#D4875A` in both modes.
- `--blue-muted` stays `#7B9DB7` in both modes.
- Selection inverts: terracotta highlight remains, but dark mode switches the selected text to `#1D1611`.

## Anti-Patterns

| Pattern | Why It Breaks | Instead |
|---|---|---|
| `style={{ color: colors.black }}` | React resolves `colors.black` to a hex during SSR, so dark CSS cannot override it later | `style={{ color: 'var(--black)' }}` or a class that resolves to `var(--black)` |
| `style={{ color: colors.muted }}` in markdown or components | Same SSR trap, just less obvious because muted copy often escapes review | Emit `style={{ color: 'var(--muted)' }}` |
| `background: white` on cards | The card stays white in dark mode and blows out contrast | `background: var(--card-bg, white)` with a dark override on `[data-theme="dark"]` |
| `border-bottom: 1px solid rgba(224, 216, 204, 0.5)` | You hardcoded a light border into a supposedly themeable component | `border-bottom: 1px solid var(--border)` or `var(--strong-border, var(--border))` |
| `#000000` or `#111111` for dark backgrounds | Cold, dead black clashes with Egregore's warm substrate | Use `#1D1611` or `var(--cream)` once dark mode remaps it |
| `opacity: 0.5` on already-colored text | Multiplies contrast unpredictably and usually makes dark text too faint | Use the precomputed text tokens: `var(--muted)` or `var(--warm-gray)` |
| `@media (prefers-color-scheme: dark)` as the only mechanism | No manual override, no persistence, no explicit state | Use a three-state `light / auto / dark` system |
| Separate `.dark-*` classes for every component | Duplicates the design system and drifts fast | Override variables once under `[data-theme="dark"]` and keep component styles shared |
| Putting theme state on `body` or a wrapper div | Inconsistent scope; portals, overlays, and SSR shells can fall out of sync | Put `data-theme` on `<html>` |
| Restoring the saved theme after the page renders | Causes a flash of the wrong theme | Apply the saved theme in a blocking `<head>` script before paint |
| Converting CSS files to variables but leaving inline `colors.*` references behind | Mixed models create false confidence; one stray inline color is enough to break dark mode | Grep every render path for `colors.` and hardcoded hex in inline styles, then replace with `var(--token)` |

## Signature Patterns

1. Variable-first inline styles. Inline styles are allowed only when they emit CSS variables, never resolved palette values.
2. `data-theme` on `<html>`. No `body.dark`, no component-local theme root.
3. Three-state theme toggle. Support `light`, `auto`, and `dark`, with persistence.
4. Auto resolves OS preference first, then local-clock fallback. If the system exposes no preference, dark runs from `19:00` to `07:00`.
5. No-flash initialization. Restore theme state in `<head>` before anything visible paints.
6. Card elevation through background lightness, not shadow stacks. In dark mode, depth comes from surface contrast.
7. Accent colors stay stable. Terracotta and muted blue do not get separate dark variants unless there is a proven contrast failure.
8. Selection highlight inversion. The highlight stays terracotta; selected text flips to the dark background color.

## Context Modes

### Egregore Artifacts (React SSR)

- Start from `packages/egregore-artifacts/lib/shell.js`, `markdown.js`, `components.js`, and `tokens.js`.
- In render functions, replace `colors.black`, `colors.muted`, `colors.dark`, and similar inline values with `'var(--black)'`, `'var(--muted)'`, `'var(--dark)'`, and so on.
- Keep structural values such as spacing, font families, and dimensions in JS as normal. The rule is specifically about theme-sensitive colors.
- Put the dark variable remap in the shell, not on individual components.

### Standalone HTML

- Emit a full `:root` block plus a `[data-theme="dark"]` override block.
- Put the theme restore script in `<head>` before visible markup.
- Mount the toggle in fixed position and hide it in print.
- Use CSS variable strings in any inline HTML styles you generate.

### Tailwind CSS

- Configure `darkMode: ['selector', '[data-theme=\"dark\"]']`.
- Keep the root selector on `<html>`.
- Prefer CSS custom properties for brand tokens, then map Tailwind utilities to those variables.
- Do not sneak theme-sensitive hex colors into JSX `style` props just because the rest of the page uses Tailwind.

### Vanilla CSS

- Define light tokens in `:root`.
- Override only variables under `[data-theme="dark"]`.
- Component rules should read like `color: var(--black)` and `border-color: var(--border)`.

### Email HTML

- This is the one context where `@media (prefers-color-scheme: dark)` with `!important` is correct.
- Do not build a JS toggle for email.
- Accept that support is partial and optimize for legibility, not full parity.

## Calibration Examples

### 1. React Component Color Reference

**Off target**

```js
h('span', { style: { color: colors.muted, fontSize: '13px' } }, `(${author})`)
```

**On point**

```js
h('span', { style: { color: 'var(--muted)', fontSize: '13px' } }, `(${author})`)
```

Why: the first version serializes to a fixed hex during SSR. The second survives theme remapping.

### 2. Card Background And Elevation

**Off target**

```css
.card {
  background: white;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.24);
}
```

**On point**

```css
.card {
  background: var(--card-bg, white);
  border: 1px solid var(--border);
}

[data-theme="dark"] .card {
  --card-bg: #241E19;
}
```

Why: dark separation comes from a warmer surface step, not a generic shadow preset.

### 3. Code Block In A Markdown Renderer

**Off target**

```js
h('code', {
  style: {
    background: 'rgba(59, 45, 33, 0.06)',
    color: colors.black,
    padding: '2px 5px',
  },
}, text)
```

**On point**

```js
h('code', {
  className: 'eg-code',
}, text)
```

```css
.eg-code {
  background: var(--code-bg, rgba(59, 45, 33, 0.06));
  color: var(--black);
}

[data-theme="dark"] .eg-code {
  --code-bg: rgba(212, 135, 90, 0.08);
  color: var(--terracotta);
}
```

Why: inline code needs a dedicated surface token in dark mode; a light-only rgba wash will disappear.

## Toggle Reference Implementation

This is the canonical Egregore pattern: one HTML attribute, one variable override block, one small engine. Keep the structure; adapt only if the host environment forces it.

### JS Engine

```html
<script>
  (function() {
    var MODES = ['light', 'auto', 'dark'];
    var ICONS = ['\u2600', '\u25D0', '\u263D'];
    var LABELS = ['light', 'auto', 'dark'];

    function resolveAuto() {
      if (window.matchMedia('(prefers-color-scheme: dark)').matches) return 'dark';
      if (window.matchMedia('(prefers-color-scheme: light)').matches) return 'light';
      var h = new Date().getHours();
      return (h >= 19 || h < 7) ? 'dark' : 'light';
    }

    function applyTheme(mode) {
      var resolved = mode === 'auto' ? resolveAuto() : mode;
      document.documentElement.setAttribute('data-theme', resolved);
    }

    function updateToggle(mode) {
      var idx = MODES.indexOf(mode);
      var btn = document.querySelector('.eg-theme-toggle');
      if (!btn) return;
      btn.querySelector('.eg-t-icon').textContent = ICONS[idx];
      btn.querySelector('.eg-t-label').textContent = LABELS[idx];
    }

    var saved = localStorage.getItem('eg-theme-mode') || 'auto';
    applyTheme(saved);

    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function() {
      if ((localStorage.getItem('eg-theme-mode') || 'auto') === 'auto') applyTheme('auto');
    });

    window.__egTheme = {
      cycle: function() {
        var cur = localStorage.getItem('eg-theme-mode') || 'auto';
        var next = MODES[(MODES.indexOf(cur) + 1) % 3];
        localStorage.setItem('eg-theme-mode', next);
        applyTheme(next);
        updateToggle(next);
      },
      init: function() { updateToggle(saved); }
    };
  })();
</script>
```

### CSS Shell

```css
:root {
  --cream: #F5F2ED;
  --black: #16100B;
  --dark: #2A2A2A;
  --border: #E0D8CC;
  --muted: #8a8578;
  --warm-gray: #d4cfc5;
  --terminal-bg: #1D1611;
  --terracotta: #D4875A;
  --blue-muted: #7B9DB7;
}

[data-theme="dark"] {
  --cream: #1D1611;
  --black: rgba(255, 255, 255, 0.92);
  --dark: rgba(255, 255, 255, 0.75);
  --border: rgba(255, 255, 255, 0.06);
  --muted: rgba(255, 255, 255, 0.50);
  --warm-gray: rgba(255, 255, 255, 0.30);
  --terminal-bg: #161210;
}

::selection { background: var(--terracotta); color: var(--cream); }
[data-theme="dark"] ::selection { color: #1D1611; }

.eg-theme-toggle {
  position: fixed;
  top: 1.25rem;
  right: 1.25rem;
  width: 36px;
  height: 36px;
  border-radius: 50px;
  border: 1px solid var(--border);
  background: var(--card-bg, white);
  cursor: pointer;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 15px;
  line-height: 1;
  transition: background 0.2s, border-color 0.2s, width 0.2s;
  z-index: 100;
  padding: 0;
  gap: 6px;
  overflow: hidden;
}
.eg-theme-toggle:hover {
  border-color: var(--terracotta);
  width: 92px;
  padding: 0 12px;
}
[data-theme="dark"] .eg-theme-toggle { --card-bg: #241E19; }
.eg-theme-toggle .eg-t-icon { flex-shrink: 0; }
.eg-theme-toggle .eg-t-label {
  font-family: var(--font-mono);
  font-size: 10px;
  letter-spacing: 0.04em;
  color: var(--muted);
  white-space: nowrap;
  width: 0;
  overflow: hidden;
  transition: width 0.2s, opacity 0.2s;
  opacity: 0;
}
.eg-theme-toggle:hover .eg-t-label { width: 32px; opacity: 1; }

@media print {
  body { background: white; }
  .eg-artifact { padding: 1rem; max-width: none; }
  .eg-card { break-inside: avoid; }
  .eg-theme-toggle { display: none; }
}

@media (max-width: 640px) {
  .eg-artifact { padding: 2rem 1.25rem 3rem; }
  .eg-title { font-size: 28px; }
  .eg-section-title { font-size: 20px; }
  .eg-meta-row { gap: 10px; }
  .eg-theme-toggle { top: 0.75rem; right: 0.75rem; width: 32px; height: 32px; font-size: 14px; }
}
```

### HTML Hookup

```html
<html lang="en" data-theme="light">
  <head>
    <!-- theme restore script goes here -->
  </head>
  <body>
    <button class="eg-theme-toggle" aria-label="Toggle theme" onclick="__egTheme.cycle()">
      <span class="eg-t-icon">&#9680;</span>
      <span class="eg-t-label">auto</span>
    </button>
    <script>__egTheme.init();</script>
  </body>
</html>
```

## Pre-Ship Checklist

1. Grep for hardcoded hex colors and `colors.` references in render paths that emit inline styles.
2. Verify every theme-sensitive inline color is a `var(--token)` string.
3. Verify both `:root` and `[data-theme="dark"]` blocks exist.
4. Verify `data-theme` is set on `<html>`, not `body`.
5. Verify the saved theme is restored in `<head>` before visible markup paints.
6. Verify the toggle cycles `light -> auto -> dark` and persists to `localStorage`.
7. Verify auto mode follows OS preference first and local time second.
8. Verify no surface uses pure black or a cool gray dark background.
9. Verify cards, code, and elevated surfaces separate by warm lightness steps rather than shadow spam.
10. Verify selection, print, and mobile behavior still work after the theme system is added.

## Reference Files

Read these conditionally, depending on the task:

- `packages/egregore-artifacts/lib/shell.js` for the canonical shell structure, variable overrides, and toggle wiring.
- `packages/egregore-artifacts/lib/tokens.js` for the shipped light and dark token values.
- `packages/egregore-artifacts/lib/markdown.js` for the inline-style `var(--token)` conversion pattern.
- `packages/egregore-artifacts/lib/components.js` for component-level inline style usage that must stay variable-first.
- `packages/design-system/tokens.css` for the broader design-system token vocabulary.

If the current checkout does not yet contain the merged dark-mode implementation in those artifact files, inspect the shipped worktree copies under `.claude/worktrees/soul-document-design/packages/egregore-artifacts/lib/`.
