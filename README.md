# Miniem for iOS

The iPhone side of Miniem's Home Assistant panel. Home Assistant describes cards (text,
buttons, fields, switches, sliders, selects, live entity states, images), and this app
draws them, along with a home-screen widget that shows the top card and its buttons. It
uses the same card format and the same Miniem integration as the Android launcher; see
[docs/home-assistant.md](https://github.com/klmz/miniem-android/blob/main/docs/home-assistant.md)
and [Mechanomythia/miniem-ha](https://github.com/Mechanomythia/miniem-ha) (0.2.0 or newer).

## How iOS differs from Android

| | Android launcher | iOS |
|---|---|---|
| Where cards show | Panel below home | The app, plus the **widget** (medium/large) |
| `focus: false` | Dot under the clock | Silent push: the app refreshes and the widget redraws. iOS rations these, so delivery is usually seconds and not guaranteed. |
| `focus: true` | Launcher comes up on the panel | **Time-sensitive notification**; tapping it opens the card. No iOS app may bring itself to the front. |
| Widget | n/a | Text, entity states, buttons and switches work in place (App Intents). Text fields, sliders, selects, prompts and images show "Open to answer →". |

## Layout

```
App/        the app: push handling, the panel, the card renderer
Widget/     the WidgetKit extension
Shared/     compiled into both: card model + parser, Home Assistant client,
            App Group storage (cache, config) and Keychain (token), widget App Intents
Tests/      parser tests (they also run on Linux; see below)
project.yml XcodeGen spec — the .xcodeproj is generated, never committed
```

The app and the widget share `group.nl.klmz.miniem`: the widget reads the cached cards
and the token (Keychain, after first unlock) from there.

## Building

```bash
brew install xcodegen
DEVELOPMENT_TEAM=<team id> BUILD_NUMBER=1 xcodegen generate
open Miniem.xcodeproj
```

`GoogleService-Info.plist` (Firebase, for push) goes in the repository root. Like Android's
`google-services.json` it holds no secrets. A build without it works, just without push.

CI (`.github/workflows/build.yml`) runs the tests on every push. On `main` it archives and
uploads to TestFlight using an App Store Connect API key, with Xcode's cloud signing.

## Not yet

- Live Activities for focus cards (lock screen / Dynamic Island, updated by push).
