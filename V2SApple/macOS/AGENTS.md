# V2S macOS project rules

- This is the independent V2S macOS product root. Keep the app brand, target names, and user-facing copy as V2S.
- Use the current V2S Android source as the feature reference. Keep Google Play Billing and Google purchase verification out of Apple targets.
- Do not add or redirect work to unrelated Apple projects. The supported VPN engine dependency is the shared `LibXray.xcframework` bundled in this project.
- Do not claim tunnel, purchase, server location, privacy, or subscription behavior as verified until tested on a signed macOS build with the required Apple entitlements and live service.
- Never log or expose full proxy links, UUIDs, passwords, subscription URLs, transaction tokens, or generated Xray JSON.
- Keep premium server access fail-closed until Apple transactions are verified by the V2S service and entitlement revocation/expiry behavior is tested.
