# Liquid Glass Mockup

Standalone SwiftUI app showing MetaWhisp's main screens reimagined in the
Liquid-Glass aesthetic — translucent layered materials, continuous rounded
corners, specular edges, colored depth.

Runs as an isolated package — no dependency on MetaWhisp itself. Purpose:
show the user a finished look so they can approve before we port it to the
main app as an opt-in theme.

## Run

```bash
cd mockup-liquid-glass
swift run
```

macOS 14+ (uses stock `Material` blurs + manual specular overlays — no
reliance on unreleased Tahoe-only APIs).

## What's inside

- **Sidebar** — glass rail with icon + label items
- **Dashboard** — hero status strip · Daily Summary card · screen activity
- **Settings** — tab strip + form sections (toggles, pickers, date picker)
- **Tasks** — review-candidates bin + main committed list
- **MetaChat** — message bubbles with tinted glass

A toggle in the toolbar flips between the current BLOCKS style and the new
Liquid Glass style so you can A/B side-by-side.
