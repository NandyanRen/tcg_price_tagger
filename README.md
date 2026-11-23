# TCG Price Tagger

A Windows desktop app (Flutter) for putting prices on photos of the trading cards you're selling, with automatic card recognition and price lookup.

- **One Piece & Digimon:** prices from the [Yuyu-tei](https://yuyu-tei.jp) selling price × your multiplier (default ×0.35).
- **Riftbound:** TCGplayer market price (via [tcgcsv.com](https://tcgcsv.com)) converted to PHP (default ₱58/USD).
- Any card can also be priced by hand.

## Setup

Requirements: Flutter (stable) and Visual Studio with the **Desktop development with C++** workload.

```cmd
cd /d D:\Projects\tcg_price_tagger
flutter pub get
flutter test
flutter run -d windows
```

To build a standalone app: `flutter build windows`. The `.exe` is in `build\windows\x64\runner\Release\` and needs the other files in that folder next to it.

For **Auto-detect**, add a Claude API key from [console.anthropic.com](https://console.anthropic.com) under *Pricing & tag settings*. The key is stored in the app's settings on your PC, not in this project.

## Pricing a photo by hand

1. **Open** a photo (Ctrl+O).
2. **Click a card** in the photo, choose the game, and search:
   - a card code, e.g. `EB05-061`: shows every print of that number, including parallels, SP and promo-pack versions;
   - a set code, e.g. `EB05`: the whole set;
   - a set plus a name, e.g. `EB05 ナミ`;
   - a card name for Riftbound, e.g. `Noxus Hopeful`.
3. Pick the right print and **Save tag**. Drag tags to move them, double-click to edit, right-click or press Delete to remove.
4. **Export PNG** (Ctrl+S) saves the photo with tags at full resolution. You can turn on a total banner in settings. **Copy list** copies a text price list for your post caption.

Changing the multiplier or exchange rate and pressing **Recalculate tags** reprices every tag that came from a search. Prices you typed by hand stay as they are.

## Auto-detect

Click **Auto-detect prices**. The app:

1. **Reads the photo** with Claude's vision API: one entry per pile of copies, with the printed code, name, whether it looks parallel or SP, how many copies, and where it is.
2. **Finds candidates** on Yuyu-tei, mainly **by name**, since card numbers read through sleeves and toploaders are often wrong. It loads the set pages from your hint and from the codes read, and also runs Yuyu-tei's **search by card number**, which finds promo-pack and SP prints listed outside the card's own set.
3. **Runs a picture check**: each pile is cropped from the full-resolution photo and compared with Yuyu-tei's picture of every candidate. Only a confirmed match gets a price. If nothing matches, the tag shows **₱?** rather than a wrong price.

Auto-detected tags have an **orange outline** until you open and save them. Opening a ₱? tag starts the search for you. Running auto-detect again replaces the orange tags you haven't checked, and keeps tags you've edited or added yourself.

### Set / pack hint

The box above Auto-detect takes set codes, words from a product name, or both, e.g. `EB05`, `EX Vol.5`, or `EB05, EX Vol.5`. It's remembered between runs.

- **SP cards** keep the card number of their original set (e.g. Perona `SP OP14-033 SR` from EB05), and Yuyu-tei lists them on the page of the set they were reprinted in. Put that set in the hint (`EB05`). SP cards are marked by a small `SP` box before the card number. Their design differs from set to set.
- **Promo-pack cards** are listed under names like `チョンマゲ(パラレル)(プロモーションパックEX Vol.5)`, often with only a "Now Printing" picture. Put the pack name in the hint (`EX Vol.5`). Listings whose name contains it go to the top, and Claude is told the cards come from that pack.

### Learning from your corrections

When you fix a ₱? or wrong auto-detected tag by picking the right listing, or confirm a correct one by opening it and saving, the app remembers:

- what auto-detect read for that pile and which listing it really was;
- a crop of that card from your photo (up to 3 per listing).

Next time, a pile that reads the same way gets that listing as a top candidate, with a fresh price from Yuyu-tei. Your crop stands in as the picture when Yuyu-tei only has a placeholder, so promo cards can be confirmed too. *Pricing & tag settings → Learned cards → Forget* clears it. Prices typed by hand aren't learned, because they aren't linked to a listing.

### Cost

Each auto-detect usually makes 2–3 Claude API requests (reading the photo, an occasional card-list lookup, and the picture check, which is split into more requests for very large photos), plus one Yuyu-tei page per set and one search per card number read. The default model is `claude-opus-5-5`; you can change it in settings.

## Debugging

When run with `flutter run` (debug mode), each auto-detect writes a `debug_last_run/` folder in the project: the Yuyu-tei pages downloaded and what was parsed from them, the photo crops and store pictures compared, Claude's requests and replies, and a summary of each pile's match. It isn't created by release builds and is excluded from git.

## Code layout

| File | What it does |
|---|---|
| `lib/services/card_recognizer.dart` | Claude vision calls: reads piles from the photo, matches unclear piles to a card list, and runs the picture check (full-resolution crops vs. store pictures, placeholder detection). |
| `lib/services/auto_pricer.dart` | Candidate finding and ranking (name matching, set/pack hints, SP/parallel), and set/hint parsing. |
| `lib/services/yuyutei_service.dart` | Yuyu-tei set pages and search by card number; HTML parsing of card boxes (code, name, rarity section, ¥ price, card picture). Caches for 30 minutes. |
| `lib/services/tcgcsv_service.dart` | Riftbound catalog and prices from tcgcsv.com. Caches on disk for 12 hours. |
| `lib/services/learned_store.dart` | Remembers corrected/confirmed cards and your crops of them. |
| `lib/ui/editor_page.dart` | Photo canvas, draggable tags, side panel, and the auto-detect flow. |
| `lib/ui/price_dialog.dart` | Search and pick a card, or enter a price by hand. |
| `lib/ui/settings_panel.dart` | Multipliers, exchange rate, rounding, tag style, API key, learned cards. |
| `lib/ui/tag_painter.dart` | Draws tags; shared by the preview and the export so both look the same. |
| `lib/exporter.dart` | Renders the tagged photo at full resolution. |
| `lib/pricing.dart` | Source price → ₱, rounding, formatting, totals. |
| `lib/settings.dart` | Saved settings. |
| `lib/debug_log.dart` | The `debug_last_run/` output. |

## If a lookup breaks

- **Yuyu-tei** has no API, so the parser reads the HTML. It doesn't rely on exact class names: it finds the card-code text, climbs to the box holding the "円" price, takes the rarity from the section heading, and uses the box's card picture (not the ☆ icon). If Yuyu-tei changes its layout, update `parseYuyuteiHtml` and `test/fixtures/yuyutei_sample.html`, and use `debug_last_run/` to see what the app downloaded.
- **Riftbound:** if tcgcsv names the category differently, change "Riftbound category name" in settings.
