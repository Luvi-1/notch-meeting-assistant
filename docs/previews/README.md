# Native interface previews

Rendered from the shipping SwiftUI views on macOS 15 with fictional, in-memory session data.

- Source commit: `043a635a5aecc49cdae0455e6e879329cb8111f9`
- [Successful workflow](https://github.com/Luvi-1/notch-meeting-assistant/actions/runs/37511546785): 62 tests passed and universal app packaging passed.
- [Complete 13-state preview artifact](https://github.com/Luvi-1/notch-meeting-assistant/actions/runs/37511546785/artifacts/11435493335), available until its workflow retention expires.
- No capture, Keychain access, saved user data, timers or provider requests run in the preview model.

These PNGs are unchanged view captures. They verify layout, not physical notch placement or animation on a particular display. Native title-bar controls and the desktop are outside the captured view.

To regenerate on a development Mac:

```sh
NOTCH_PREVIEW_DIRECTORY="$PWD/dist/Previews" swift test --filter DesignPreviewTests
```

See [design notes](../DESIGN.md) for the reference study and reviewed screens.
