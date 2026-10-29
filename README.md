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

Nutrition data will come from USDA FoodData Central (public domain, CC0).
