# Development handoff

Read README.md for the public product overview and DEVELOPMENT.md for architecture, build/signing, history ownership, real verification and limitations.

- Primary goal: low-overhead background identification of short mystery sounds on this Mac, with truthful process attribution.
- Keep public CoreAudio taps unmuted and private; never reroute or mute normal playback.
- Keep audio IO callbacks free of allocation, locks, Foundation/Swift calls, logging and disk operations. Preserve stereo detection and SPSC ownership.
- Stop IO before final drain/destroy. Own HAL listeners on the engine's serial queue; remove them before destruction. All SwiftUI state belongs to the main thread.
- Do not label an open audio session as a confirmed sound. Unknown is preferable to invented attribution. Document global-overlap and system-notification limitations.
- Do not overwrite user history on malformed JSON. Do not delete a real history to make tests pass.
- Sign with the configured Developer ID certificate issued through G2. Never copy or expose private signing keys.
- After source edits, update DEVELOPMENT.md with material changes, verification and remaining limitations so another agent can continue from the latest state. Keep English/Russian download pages and release notes truthful about notarization, architecture and the Russian UI.
