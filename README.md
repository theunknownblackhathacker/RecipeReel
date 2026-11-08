# RecipeReel

iPhone app that turns a recipe video (a saved Reel or a screen recording) plus its caption into an
ingredient list, cooking steps and macros — entirely on-device, free to run.

## How it's built (no Mac needed)

- `project.yml` is the Xcode project definition ([XcodeGen](https://github.com/yonaskolb/XcodeGen)).
  The `.xcodeproj`, `Info.plist` and `.entitlements` files are generated in CI and git-ignored.
- **Build** workflow: every push to `main` runs the RecipeCore tests, builds the unsigned app and publishes
  **https://github.com/theunknownblackhathacker/RecipeReel/releases/download/latest/RecipeReel.ipa**
  (also on the `builds` branch). A readable build summary goes to the `build-logs` branch.
- **Release IPA** workflow (optional, numbered builds): run it manually (Actions → Release IPA → Run workflow). It publishes the
  **unsigned** `.ipa` as a GitHub Release: https://github.com/theunknownblackhathacker/RecipeReel/releases/latest/download/RecipeReel.ipa
- Sign and install the `.ipa` yourself (e.g. Feather). Keep the bundle IDs unchanged and keep the
  app extension (PlugIns) so the share extension is re-signed too.

## AI

- Default: **Apple Intelligence** on the iPhone — free, private, offline.
- Optional: **your own API key** (Settings → AI): Claude (Anthropic) or any OpenAI-compatible provider
  (OpenAI, Google Gemini, OpenRouter, …). The key is pasted in the app and stored only in the iPhone's
  Keychain — it is never in this repo, the builds or exported logs. Only recipe text (caption, transcript,
  on-screen text) is sent; the video stays on the phone. Macros always come from the bundled food tables.

## Layout

| Path | What |
|---|---|
| `App/` | SwiftUI app: import screen, item detail, Diagnostics |
| `ShareExtension/` | Share extension: copies video/link + caption into the App Group inbox |
| `Packages/RecipeCore/` | Shared code: Inbox (App Group handoff), Diagnostics log, provisioning info |

## IDs

- App: `com.kevin.recipereel` · Share extension: `com.kevin.recipereel.share`
- App Group: `group.com.kevin.recipereel`

## Data

Nutrition data is bundled as `App/Resources/fdc.sqlite` by the **Build FDC database** workflow
(`tools/build_fdc.py`, `tools/eu_foods.py`). European tables are searched first; USDA fills the gaps.
Carbohydrate is stored EU-style (available carbohydrate, fibre excluded) for every food.

- **Ciqual 2025** — French food composition table, © ANSES, [Licence Ouverte / Open Licence 2.0](https://www.etalab.gouv.fr/licence-ouverte-open-licence/)
  ([doi:10.57745/RDMHWY](https://doi.org/10.57745/RDMHWY)).
- **CoFID 2021** — McCance and Widdowson's Composition of Foods Integrated Dataset (UK). Contains public sector
  information licensed under the [Open Government Licence v3.0](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).
- **USDA FoodData Central** — Foundation Foods, SR Legacy and FNDDS survey foods (public domain, CC0).

Ciqual and CoFID have no household measures, so each European food borrows the cup/spoon/piece weights of a
closely matching USDA food. Values in the bundled database are derived from these sources (selected columns,
fibre-free carbohydrate for USDA foods); see `tools/` for exactly how.

Missing or branded products can come from [Open Food Facts](https://world.openfoodfacts.org) (ODbL; barcode scan
or name search, online, products sold in Greece first) or be typed from a label; these are saved on the phone as
"My foods". The app lists these credits under Settings → Nutrition data → Data sources.
