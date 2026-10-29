# Sandbox Ports by ad-hoc re-signing them with the App Sandbox entitlement

Frontport replaces each Port's upstream signature with an ad-hoc signature that carries `com.apple.security.app-sandbox`. Every Port then runs in the macOS App Sandbox with its own container. That needs no Apple developer identity per Port and no system extension, and the sandbox applies however the Port is launched. We verified this on macOS 27.0.1 on Apple silicon.

## Considered Options

- **Seatbelt (`sandbox-exec`) wrapper at launch.** A Port launched from the Dock or Finder escapes it. We use it for source builds instead.
- **Linux VMs or containers.** Ports are macOS apps.
- **Endpoint Security system extension.** It needs a restricted Apple entitlement and a system extension, which is far heavier for the same goal.
- **Per-machine self-signed certificate instead of ad-hoc signing.** Privacy grants would survive updates, but it adds keychain management, and losing the certificate resets everything. We'll revisit it if a Port needs a privacy grant.

## Consequences

- **Upstream signing is discarded.** Upstream signatures and notarization are replaced, so trust comes from the signed Catalog and GitHub's digests. Frontport must never leave quarantine on a Port.
- **Privacy grants reset on every update.** An ad-hoc designated requirement is the cdhash, so microphone, camera and Bluetooth grants are requested again after each update.
- **The bundle ID is permanent.** It is what ties a Port to its Data, so it can never change.
