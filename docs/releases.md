# Release packaging

Commit source changes first, then build and package from that clean commit:

```sh
bash scripts/build.sh release
python3 scripts/package-release.py
```

The release build remaps local source paths, strips debug/local symbols and ad-hoc signs the app. Native libraries are statically linked; only macOS system frameworks/libraries are loaded dynamically. The app contains its dependency notices and a receipt identifying the source commit and dependency versions.

Packaging checks the source receipt, signature, architecture, library paths and absence of local build paths or obvious personal artifacts. It creates a ZIP, a drag-to-install DMG, a manifest and SHA-256 checksums under ignored `dist/release/`. Existing archives are not overwritten. Inspect the complete payload separately for personal host data before uploading it.

Extract the ZIP to a fresh temporary directory, verify the app signature again, and launch it with an empty `DECK_STATE_DIR`. Confirm the workspace starts empty and that the bundled MCP server can list tools and connections. Check `hdiutil verify` and inspect the mounted DMG read-only. Do not include personal profiles or live-test fixtures in either artifact.

Publish the exact clean source commit and all four artifacts through `gh release create`, using the app version as the `vVERSION` tag. Describe the supported architecture/minimum macOS version and the actual signing/notarization status. After publication, download the assets and verify their checksums against the uploaded manifest.

The current signing mode is ad-hoc. It does not establish Developer ID identity or notarization. Do not describe these builds as notarized or silently disable Gatekeeper. First-launch instructions link to Apple's per-app approval flow. A future notarized distribution requires an available Developer ID certificate and authorized notarization credentials.
