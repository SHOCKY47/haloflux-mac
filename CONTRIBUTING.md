# Contributing

Thank you for helping maintain this macOS adaptation of [HALOFLUX by Ryder191](https://github.com/Ryder191/haloflux).

## Scope

This repository contains the desktop wallpaper and local Orca integration. Keep the original particles, beams, and detailed ring design. New data adapters should reuse the scene contract rather than substitute a simplified animation.

Lock-screen videos, private wallpaper extensions, screen-saver experiments, local account data, generated diagnostic frames, and exported session logs are outside this repository.

## Build and package

On macOS with Xcode Command Line Tools:

```sh
bash build.sh
```

This produces an ad-hoc signed `build/HaloFlux.app` for arm64 with a macOS 13 deployment target. It does not install or replace a running application. `bash install.sh` installs it for the current user and enables launch at login. `bash scripts/package-release.sh` builds a ZIP with the app, installers, quick-start instructions, original license, and attribution, plus `dist/SHA256SUMS.txt`.

The project uses system AppKit, WebKit, Foundation, and SQLite libraries. No Node or Python dependency is required. No automated test suite is currently included; describe any validation you performed rather than claiming broad platform coverage.

## Code changes

- Keep visible UI strings in English; preserve actual workspace/folder names.
- Preserve read-only Agent access. Never send input or mutate Orca databases from the wallpaper.
- Keep asynchronous request identity tied to its verified workspace/pane/session.
- Unknown state remains unknown; never invent success, a model name, or a human request.
- Use structured data delivery into WebKit, not interpolated task text.
- Avoid adding private runtime dumps, machine paths, account IDs, or credentials to commits.
- Keep [the scene schema](docs/orca-state.schema.json) and [integration documentation](docs/ORCA-INTEGRATION.md) consistent with changes.

## License and attribution

Read [LICENSE](LICENSE) before contributing. Contributions to this adaptation are offered under the same PolyForm Noncommercial 1.0.0 terms and accompanying notices. Preserve the upstream copyright and [NOTICE](NOTICE), and clearly credit the original artist in redistributed builds and screenshots/videos as required by the license. This project has no commercial license, donation links, or paid distribution.

