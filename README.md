# Digidropp Upload Action

Upload your Android APK or iOS IPA to [Digidropp](https://digidropp.online) from GitHub Actions.
On pull requests it comments an install link and QR code, and updates that comment on every push.

- **Builds from `main` (or any push)** update your app's install link, so testers always get the latest.
- **Builds from a pull request** are previews: they get their own link and don't replace the main one.

## Setup

1. In Digidropp, open **Settings → Upload tokens** and create a token.
2. In your GitHub repo, add it as a secret named `DIGIDROPP_TOKEN` (Settings → Secrets and variables → Actions).
3. Add a workflow like one of the examples below.

## Android (Gradle)

```yaml
name: Preview build
on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read
  pull-requests: write   # to comment on the PR

jobs:
  android:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with: { distribution: temurin, java-version: 17 }
      - run: ./gradlew assembleDebug
      - uses: digidropp/upload-action@v1
        with:
          api-token: ${{ secrets.DIGIDROPP_TOKEN }}
          api-url: https://api.digidropp.online/api
          file: app/build/outputs/apk/debug/*.apk
```

Use the same signing key for every build (for example a shared debug keystore committed to the repo, or your
release key from secrets). Otherwise testers have to uninstall between builds, and Digidropp will warn you.

## iOS (Xcode)

iOS only installs builds signed with an **Ad Hoc, Development or Enterprise** profile, and only on devices
registered in that profile (Enterprise: any device). App Store-signed builds must go through TestFlight.

```yaml
  ios:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      # Import your certificate and Ad Hoc provisioning profile here, then:
      - run: |
          xcodebuild -scheme MyApp -archivePath build/MyApp.xcarchive archive
          xcodebuild -exportArchive -archivePath build/MyApp.xcarchive \
            -exportOptionsPlist ExportOptions.plist -exportPath build/ipa
      - uses: digidropp/upload-action@v1
        with:
          api-token: ${{ secrets.DIGIDROPP_TOKEN }}
          api-url: https://api.digidropp.online/api
          file: build/ipa/*.ipa
```

## Flutter / React Native

Point `file` at the output of your build command, e.g. `build/app/outputs/flutter-apk/app-release.apk`
(Flutter) or `android/app/build/outputs/apk/release/app-release.apk` (React Native).

## Inputs

| Input | Required | Description |
|---|---|---|
| `api-token` | yes | Digidropp upload token (store as a secret) |
| `api-url` | yes | Digidropp API URL, ending in `/api` |
| `file` | yes | Path or glob matching exactly one `.apk` or `.ipa` |
| `release-notes` | no | Defaults to the PR title, or the latest commit message |
| `comment-on-pr` | no | `true` (default) to comment the install link on PRs |
| `github-token` | no | Defaults to `github.token`; needs `pull-requests: write` |

## Outputs

`install-url` (latest main build), `build-url` (this exact build), `qr-url` (PNG QR code).

## Notes

- Pull requests from forks don't get repository secrets, so the upload is skipped there by GitHub.
- The QR code image in the comment is served by your Digidropp API, so it must be publicly reachable over HTTPS.
