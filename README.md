# ProxyMb (macOS)

A tiny SSH tunnel menu bar helper written in SwiftUI.

## Repo setup

This repo already includes:
- `.gitignore` for Xcode/Swift, to keep your repo clean.
- GitHub Actions workflows:
  - `CI` (build Release on pushes/PRs to `main`/`master`).
  - `Release` (build and upload a zipped app on tags that start with `v`).
- A local packaging script: `scripts/build_and_package.sh` to build Release, seal a staging copy with an ad-hoc signature, and verify the extracted ZIP before publishing it to `dist/`.

## Build locally

```bash
# From repo root
bash scripts/build_and_package.sh

# Output
# - Build artifacts in: build/Build/Products/Release
# - Zipped app at:      dist/ProxyMb-macos.zip
```

The Xcode build disables automatic signing. Packaging then applies a complete **ad-hoc bundle signature**, including the resource seal. This fixes signature integrity but is **not Developer ID signing or Apple notarization**. Downloaded builds may still require explicit per-app approval in macOS Privacy & Security. Do not disable Gatekeeper globally.

Packaging verifies the signature and version after ZIP extraction, then launches the extracted executable with `--smoke-test` and a fresh temporary runtime directory. The startup check creates the real SwiftUI view without loading your configuration, running spaas/SSH, or changing system proxy settings. It is not a test of Gatekeeper approval for a quarantined download.

## Bundled spaas (no system install required)

You can ship a self-contained `spaas` binary inside ProxyMb so the menu bar “spaas login” works even if users didn’t install `spaas` on their system.

How it works:
- At runtime, the app will prefer a bundled binary at `ProxyMb.app/Contents/Resources/bin/spaas`.
- If not present, it falls back to finding `spaas` on `PATH` (via `/usr/bin/env spaas`).

Include your `spaas` binary:
- Put your executable at `resources/spaas` (make sure it’s executable and built for your target architecture, e.g. arm64 on Apple Silicon).
- Copy the executable into `ProxyMb.app/Contents/Resources/bin/spaas` before running `scripts/package_app.sh`. The current build script does not copy it automatically.
- Finish all bundle modifications before signing. Changing resources after signing invalidates the resource seal.

Local Xcode runs:
- When you run from Xcode, the app bundle produced by Xcode won’t include `resources/spaas` unless you add it to the target’s Copy Bundle Resources. For quick iteration, either:
  - Add `resources/spaas` to the app target’s “Copy Bundle Resources” phase in Xcode; or
  - Ensure `spaas` is installed on your PATH so the fallback works.

Troubleshooting:
- If macOS blocks the bundled binary with “cannot be opened because the developer cannot be verified”, you may need to remove the quarantine attribute after copying the binary into `resources/spaas`:
  ```bash
  xattr -dr com.apple.quarantine resources/spaas
  ```
- Confirm the binary is executable and the right architecture:
  ```bash
  chmod +x resources/spaas
  file resources/spaas
  ```

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
- `.github/workflows/ci-pr.yml` runs on pushes and pull requests. It runs isolated
  core regression tests, builds/tests Debug, and builds Release on `macos-latest`.
  It then tests packaging, signature failures, version mismatches, and startup failures against the real built app.
  Only the verified `dist/ProxyMb-macos.zip` is uploaded as a CI artifact.
- `.github/workflows/ci.yml` provides a manual unsigned Release build.

Run the regression suite locally with `swift test`. It uses temporary directories
and controlled child processes; it does not launch the menu-bar app or change
your system proxy. Set `PROXYMB_CONFIG_FIXTURE_DIRECTORY` to a directory of
installed config JSON files to validate them read-only as well.

Config imports validate local/remote ports, endpoint syntax, duplicate local
ports, and SSH host arguments before saving or stopping any existing tunnel.
Port 1080 is reserved for the built-in SOCKS proxy. IPv6 destinations use
brackets, for example `[::1]:443`. Failed validation or saving leaves the current
configuration in place.

Stopping waits for the tracked processes before allowing another start. External
SSH tunnels are detected from actual TCP listeners, not command-line text.

Status indicators do not change the existing layout:

- Tunnel, SOCKS, and per-port lights use observed local SSH listeners, not merely a started process. Orange means waiting/stopping, green means listening, red means no listener, and gray means not checked or unavailable.
- A process that is still connecting and a partially listening tunnel both keep a usable **Stop** button. Individual port results remain visible even when the whole tunnel is not active.
- Monitoring runs every three seconds; exits invalidate older observations and trigger a fresh check. Green does not prove that the remote application behind the tunnel is healthy.
- AWS/Kubernetes command results belong to the selected system, environment, and Kubernetes context. Switching selections does not inherit another command's green light; a new run clears the previous exit code.
- spaas login, AWS, and Kubernetes lights indicate the last command's exit result, not live credential validity or cluster health. Hover over a light for its meaning. Success-looking log text does not override a failing exit code.
Quit waits for cleanup instead of reloading the app. Only system SOCKS settings
pointing to this machine's port 1080 are disabled.

## Create a Release (tag-driven)
Create a semver-style tag starting with `v` matching the app version (e.g. `v0.2.4`). The `Release` workflow will:
- Build Release with automatic signing disabled.
- Ad-hoc sign a staging copy of the complete app.
- Package it into a ZIP, extract it, and verify its signature, exact tag version, and isolated startup.
- Publish `dist/ProxyMb-macos.zip` only after all checks pass. It never uploads the historical ZIP tracked in the repository root.

```bash
# Update the app's Debug and Release marketing versions before tagging.

# Create and push tag
git tag v0.2.4
git push origin v0.2.4
```

After a few minutes, check your repo's Releases page; you should see `ProxyMb-macos.zip` attached.

Local builds and the Release workflow share `scripts/package_app.sh` and `scripts/verify_app.sh`.
Run `bash scripts/test_package_app.sh /path/to/built/ProxyMb.app` to exercise the package regression checks.

## Optional: Codesign + Notarize
For broader distribution, you should sign and notarize:
- Create a Developer ID Application certificate in your Apple Developer account.
- Export the certificate and keychain password into GitHub Secrets (e.g. `MACOS_CERT_BASE64`, `MACOS_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`).
- Update the Release workflow to import the certificate, enable signing, and add a notarization step (e.g., `xcrun notarytool`).

The current workflow does not import a Developer ID certificate or submit to Apple's notarization service. Do not describe the ad-hoc build as notarized or Gatekeeper-approved.

## Project
- Project: `ProxyMb.xcodeproj`
- Scheme: `ProxyMb`
- App target: `ProxyMb` (macOS)

## Troubleshooting

- The app version is shown beside **Tunnels** at the top and in the existing footer.
- **Short Cuts** remains below the tunnel list and is collapsed by default. Scroll down and expand it to access AWS and Kubernetes.
- Shortcuts are read directly from single-line aliases in `~/.zshrc` whenever the menu content appears. The section header shows the number of detected AWS and Kubernetes systems.
- Use **Reload** beside **Short Cuts** to reread aliases without stopping tunnels or SOCKS. The top-level **Refresh** still resets runtime state and stops connections.
- Read errors are shown in **Short Cuts**; previously loaded choices are retained until a successful reload. No shell startup file is executed during loading.

- If the GitHub runner picks a wrong Xcode, the workflow pins to `/Applications/Xcode.app`.
- If the build fails due to signing, confirm `CODE_SIGNING_ALLOWED=NO` is present.
- For local packaging script, ensure it’s executable:

```bash
chmod +x scripts/build_and_package.sh
```

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
