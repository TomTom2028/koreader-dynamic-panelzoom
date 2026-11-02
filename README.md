# KOReader Dynamic Panel Zoom

A KOReader plugin that automatically detects and displays comic and manga panels one by one for a seamless reading experience on E-Ink devices. 

No pre-processing, external scripts, or JSON files required—it analyzes the page on the fly.

<p align="center">
  <img src="https://github.com/user-attachments/assets/839285a6-00c0-4308-82cb-ba637a2e0284" width="300" alt="Demo GIF showing Dynamic Panel Zoom in action" style="border: 5px solid #ccc; border-radius: 4px;">
</p>

## Features
- **🤖 Real-time Detection:** Analyzes pages instantly using KOReader's native engine.
- **📖 Focused View:** Centers each panel and masks adjacent content to reduce distractions.
- **⚡ Smart Pre-loading:** Renders the next panel in the background for zero-lag transitions.
- **🔄 Reading Direction:** Supports Left-to-Right (Western) and Right-to-Left (Manga).
- **🔍 Hold-to-Zoom Mode:** Long-press on any panel to instantly enter a free-zoom state with smart text padding to read cut-off speech bubbles or admire wide landscape art.
- **🧱 Row View:** Read a whole row (or two, or as many as fit) at a time instead of panel by panel — handy in landscape. When a page ends on a single leftover row, the first row of the next page is pulled up to fill the empty half so the layout stays full.

## Installation
1. Download the latest `dynamic_panelzoom.koplugin.zip` from [Releases](https://github.com/JorgeTheFox/koreader-dynamic-panelzoom/releases).
2. Unzip and copy the `dynamic_panelzoom.koplugin` folder to your KOReader's `plugins/` directory.
3. Restart KOReader.

## Usage
1. Open a comic (`.cbz`, `.pdf`, etc.) in "full page mode": fit = full and view mode = page (see the gif above).
2. Go to the top menu, tap on the document tab and check **Allow panel zoom**.
3. Select **Reading direction**:
   - **Left-to-Right (LTR)** for Western comics
   - **Right-to-Left (RTL)** for Manga/Eastern comics
4. **Standard panel settings** (Optional):
   - **Show adjacent page content:** Toggle whether parts of the page outside the current panel are masked or visible.
   - **Padding around panel:** Adds a margin (`0%` to `10%`) around the detected panel for the standard panel view.
5. **Hold-to-Zoom settings** (Optional):
   - **Hold-to-Zoom padding:** Adds a safe margin (`2%` to `20%`) around the detected panel to capture overlapping speech bubbles when long-pressing.
   - **Initial zoom level:** Choose how the zoom mode starts (`1.0x Fit` to `2.0x Heavy Zoom`).
6. **Row view** (Optional):
   - Choose **Off**, **One row**, **Two rows**, or **Auto** (fit as many rows as the screen allows).
   - **Fill last row from next page:** in Two-row and Auto modes, when a page ends on a lonely row, pull the next page's first row up to fill the layout.
   - **Landscape only:** restrict row view to landscape orientation.
7. **One-tap landscape start** (Optional):
   - **Start panel view in landscape** (top of the panel zoom menu) rotates to landscape if needed and opens panel view on the current page.
   - For a true one-tap start, bind the action **Panel view in landscape** to a gesture or Quick Menu: *Settings → Taps and gestures → Gesture manager → (pick a gesture) → Fixed layout documents*.
   - It rotates to whichever landscape side you last used, so if it picks the wrong side once, rotate to the right one yourself and it will remember.
8. **Navigation:**
   - Long-press on a panel to enable panel view.
   - Tap the **edges** of the screen to move between panels or pages.
   - **Hold (Long-press)** anywhere while viewing a panel to trigger the **Free Zoom Mode**.
   - Tap the **center** to exit panel view.

## Known Issues
- **Full page mode Only:** If you use the plugin without full page view, you may see some repeated panels.

- *Tested primarily on Linux (Native/AppImage) and Kindle Colorsoft (2025).*

## Performance logging
Every press is traced in KOReader's log so a sluggish page turn can be attributed
to a phase instead of guessed at. Grep the log (`crash.log`, or stdout on
desktop) for `DPZPERF`:

```
DPZPERF [7] BEGIN tap-right panel 5/5, page 42
DPZPERF [7]   . END OF PAGE (panel 5 of 5) -> full page turn, nothing for the next page is preloaded (+1 ms)
DPZPERF [7]   . page change START (diff=1) -- presses are queued from here on (+2 ms)
DPZPERF [7]   + onGotoViewRel              412.7 ms  diff=1 (KOReader re-renders the full page here)
DPZPERF [7]   . PRESS 'right' QUEUED, not acted on now (1 press(es) queued since the last handled one) -- page change in flight for 655 ms (+657 ms)
DPZPERF [7]   + analyze page (CACHE MISS) 1380.4 ms  page 43, 6 raw panels, default sorter
DPZPERF [7]   +   getPagePix               890.2 ms  full-page bitmap 1536x2048
DPZPERF [7]   +   leptonica gray+CC        460.1 ms
DPZPERF [7]   + draw panel image           210.6 ms  panel 1/6 on page 43
DPZPERF [7] TOTAL tap-right 2065.9 ms landed on page 43, panel 1/6 | ...
```

Reading it:

| Marker | Meaning |
| --- | --- |
| `BEGIN` / `TOTAL` | One press, and how long it took to become a visible panel. `TOTAL` ends with a breakdown of every span inside it. |
| `+` | A completed span, with its duration. Indented names are sub-phases of the span above them. |
| `.` | A point-in-time note, stamped with how long the press has been running. |
| `~` | Background work with no press waiting on it (preloads, painting, inputs). |
| `PRESS ... QUEUED` | A press that arrived while the previous one was still in flight, plus the guard that swallowed it and how long that guard had been up. Only the last queued press is replayed, so several presses inside one slow window advance a single step. |
| `INPUT #n received by PanelViewer` | Counts inputs that actually reached the viewer. Fewer of these than presses means the presses never got to the plugin. |
| `NO PRELOAD` | The current panel is the last on its page, so the next forward press pays for a full page turn: `onGotoViewRel` + panel analysis + render. |

## Credits & License
Inspired by Kaito0's [panelreader.koplugin](https://github.com/Kaito0/panelreader.koplugin), but built from scratch to use on-the-fly detection via Leptonica instead of pre-generated JSON files.

Licensed under the MIT License.
