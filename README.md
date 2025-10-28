# ProxyMb (macOS)

A tiny SSH tunnel menu bar helper written in SwiftUI.

## Repo setup

This repo already includes:
- `.gitignore` for Xcode/Swift, to keep your repo clean.
- GitHub Actions workflows:
  - `CI` (build Release on pushes/PRs to `main`/`master`).
  - `Release` (build and upload a zipped app on tags that start with `v`).
- A local packaging script: `scripts/build_and_package.sh` to build unsigned Release and zip the app.

## Build locally

```bash
# From repo root
bash scripts/build_and_package.sh

# Output
# - Build artifacts in: build/Build/Products/Release
# - Zipped app at:      dist/ProxyMb-macos.zip
```

Note: The local build and CI builds are unsigned (CODE_SIGNING_ALLOWED=NO). If you plan to distribute to other Macs, consider adding Developer ID signing and notarization (see below).

## Push to your personal GitHub repo

```bash
# Initialize (if not already)
git init

git add .

# First commit
git commit -m "feat: initial commit (ProxyMb + CI/Release)"

# Add your remote (replace YOUR_NAME and REPO)
git remote add origin git@github.com:YOUR_NAME/REPO.git

# Push the code
git branch -M main
git push -u origin main
```

## Continuous Integration (CI)
- Triggers: push/PR to `main` or `master`.
- Workflow: `.github/workflows/ci.yml` builds an unsigned Release with Xcode on `macos-latest`.

## Create a Release (tag-driven)
Create a semver-style tag starting with `v` (e.g. `v0.1.0`). The `Release` workflow will:
- Build a Release (unsigned),
- Package `ProxyMb.app` into `ProxyMb-macos.zip`,
- Publish a GitHub Release and upload the zip as an asset.

```bash
# Bump version (optional): update your app version in Xcode if desired

# Create and push tag
git tag v0.1.0
git push origin v0.1.0
```

After a few minutes, check your repo's Releases page; you should see `ProxyMb-macos.zip` attached.

## Optional: Codesign + Notarize
For broader distribution, you should sign and notarize:
- Create a Developer ID Application certificate in your Apple Developer account.
- Export the certificate and keychain password into GitHub Secrets (e.g. `MACOS_CERT_BASE64`, `MACOS_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`).
- Update the Release workflow to import the certificate, enable signing, and add a notarization step (e.g., `xcrun notarytool`).

This repo uses unsigned builds by default to keep setup simple.

## Project
- Project: `ProxyMb.xcodeproj`
- Scheme: `ProxyMb`
- App target: `ProxyMb` (macOS)

## Troubleshooting
- If the GitHub runner picks a wrong Xcode, the workflow pins to `/Applications/Xcode.app`.
- If the build fails due to signing, confirm `CODE_SIGNING_ALLOWED=NO` is present.
- For local packaging script, ensure it’s executable:

```bash
chmod +x scripts/build_and_package.sh
```

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
