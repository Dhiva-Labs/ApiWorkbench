# Play Console: App content answers — ApiWorkbench 1.3.0

Answers for Play Console → Policy and programs → App content, with the
reasoning behind each. They match `PRIVACY.md` (last updated 11 October 2026).

## Privacy policy

https://github.com/Dhiva-Labs/ApiWorkbench/blob/main/PRIVACY.md (public repo).

## App access

**All functionality is available without any access restrictions.** There
is no sign-in, account or paywall; requests go to whatever URL the user types.

## Ads

**No, my app does not contain ads.** No ad SDK in `pubspec.yaml` or the
merged manifest.

## Content rating (IARC questionnaire)

Category: **All other app types** (a developer utility).

| Question | Answer | Why |
| --- | --- | --- |
| Violence, blood, fear, sexuality, nudity, profanity, crude humour | No | None in the app. Chaos Mode sounds are synthesized jingles (`tool/gen_sounds.dart`); the third-party meme clips are not in the Play build. |
| Controlled substances, alcohol, tobacco | No | |
| Gambling, simulated gambling | No | |
| Users can interact or exchange content with other users | No | No chat, no accounts, no server. Requests go to servers the user chose. |
| Shares the user's location with other users | No | No location permission. |
| Digital purchases | No | Free, no in-app products. |
| Is the app a web browser or search engine | No | Responses are shown as text, JSON or headers; nothing is rendered as a web page. |
| Features or promotes online content (the Netflix / Spotify kind) | No | The app promotes nothing; it shows the raw response from an address the user typed. |
| Cash rewards, gift cards, crypto or NFTs | No | |
| Primarily a news or educational product | No | |

Result (submitted 22 October 2026): Everyone / ESRB E / PEGI 3 / USK 0 /
ClassInd L.

## AI asset declaration (store listing)

**Don't label assets.** None of the listing images is generative-AI output:
the phone screenshots are renders of the real app
(`integration_test/play_screenshots_test.dart`), and the icon and feature
graphic are drawn by `store/scripts/make_store_graphics.py` from the app's
own logo.

## Target audience and content

- Target age groups: **18 and over** (a tool for software developers).
- Appeals to children: **No**.
- So the Families policy does not apply.

## Data safety

**Does your app collect or share any of the required user data types? No.**

| What leaves the device | Where it goes | Why it is not "collected" or "shared" |
| --- | --- | --- |
| Requests, collection runs, load tests (URLs, headers, bodies, credentials the user configured) | The URLs the user entered | Sent only when the user asks, to a destination the user chose. Dhiva Labs never receives it. `lib/services/http_service.dart`. |
| HTTP/3 requests on Android | The same URLs, through Cronet from Google Play services (`cronet_http` → `play-services-cronet`) | Cronet is the network stack carrying the user's own request. Google's [data disclosure page for Play services SDKs](https://developers.google.com/android/guides/play-data-disclosure) lists only base, basement, OSS licenses and tasks (none collect data) and says nothing about Cronet. Re-check if Google publishes a disclosure for it. |
| Chaos Mode clip import from a URL | The page and audio file at the address the user gives | User-started download; nothing about the user is sent. |

Everything else stays in the app's private storage: collections,
environments (which can hold secrets the user typed), the last 100 sends,
settings, imported clips, and temporary load-test logs. On-device data is
exempt from the form.

No analytics, crash reporting, advertising ID or account. Merged-manifest
permissions: `INTERNET`, `ACCESS_NETWORK_STATE` and AndroidX's
`DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`.

Store listing result: "No data collected" and "No data shared with third
parties". With no data collected, Play does not ask about encryption in
transit or data deletion.

## Other declarations

| Declaration | Answer |
| --- | --- |
| Government app | No |
| Financial features | None of the listed features |
| Health | None of the listed features |
| News app | No |
| COVID-19 contact tracing or status | No (if still asked) |
| Advertising ID | No (the app does not use it) |
