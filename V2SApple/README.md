# V2S Apple 1.0.2 (181) source milestone

Independent V2S macOS and iOS/iPadOS sources. The original RayLink tree and local working index are preserved. These sources are mirrored under V2SApple, not merged into the unrelated V2Teh targets.

Build macOS: xcodebuild -project macOS/V2S.xcodeproj -scheme V2S MARKETING_VERSION=1.0.2 CURRENT_PROJECT_VERSION=181 archive
Build iOS/iPadOS: xcodebuild -project iOS/RayLink.xcodeproj -scheme RayLink -destination generic/platform=iOS MARKETING_VERSION=1.0.2 CURRENT_PROJECT_VERSION=181 archive

Restore each platform's bundled LibXray.xcframework from the encrypted Development-Backups snapshot to its project root before building. Binary engines, archives, signing material, sandbox codes, and private server configuration are excluded from this public source mirror.

Changes: native subscription offer redemption and guidance; foreground entitlement refresh; privacy-gated verification; race-safe iOS leases, Apple/server expiry limits, stable profile identity and revocation disconnection; version label; explicit local-data removal and first-launch reinstall guard; Persian Premium guidance.

Release archives and App Store exports passed; both uploads accepted. Pure lease/profile regressions passed. Real sandbox activation, restoration and persistence remain UNVERIFIED while Apple redemption testing continues. Neither app submitted for review. Do not claim this milestone passes release acceptance solely from build success.

Latest status, November 3, 2026: France deselected, China still excluded. Standard-encryption declaration saved with France distribution No. Mac 1.0.2 (181) submitted and verified Waiting for Review; iOS/iPadOS 1.0.2 (181) also verified Waiting for Review. Manual release retained. Production redemption/activation remains unverified. See RELEASE-STATUS-181.txt for the current record.
