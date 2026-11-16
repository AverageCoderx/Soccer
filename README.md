# KickMetrics

An iPhone app that measures soccer shot speed with the camera.

**Status:** first test version. The measurement core is tested against
synthetic data; it has not yet been validated against real shots or a radar,
so no accuracy claim is made.

- Install on an iPhone from Windows: [docs/INSTALL.md](docs/INSTALL.md)
- First tests to run: [docs/TESTING.md](docs/TESTING.md)

## How it measures

The camera sits on a tripod, roughly side-on to the shot. A regulation ball
has a known diameter, so its apparent size in the image gives its distance
from the camera; no tape measure needed. The app tracks the ball at up to
240 fps using real frame timestamps, then fits a physics model (gravity and
air drag) to the whole flight to get the speed with an uncertainty range.
If a shot can't be measured reliably, the app says so instead of guessing.

## Layout

- `Packages/KickMetricsCore`: platform-independent measurement core
  (geometry, physics, ball detection, tracking, fitting, validation
  statistics). Builds and tests on Linux and macOS.
- `App/`: the iOS app (camera, recording, screens). Built by
  `.github/workflows/ios-build.yml` from `project.yml` with XcodeGen.

## Running the core tests

```bash
cd Packages/KickMetricsCore
swift test
```
