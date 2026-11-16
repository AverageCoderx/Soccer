# KickMetrics

An iPhone app that measures soccer shot speed with the camera.

**Status:** early development. The measurement core is being built and
tested against synthetic data. There is no app to install yet, and no accuracy
claims have been validated against real shots.

## How it measures

The camera sits on a tripod, roughly side-on to the shot. A regulation ball
has a known diameter, so its apparent size in the image gives its distance
from the camera; no tape measure needed. The app tracks the ball at up to
240 fps using real frame timestamps, then fits a physics model (gravity and
air drag) to the whole flight to get the speed with an uncertainty range.
If a shot can't be measured reliably, the app says so instead of guessing.

## Layout

- `Packages/KickMetricsCore`: platform-independent measurement core
  (geometry, physics, tracking, fitting, validation statistics). Builds and
  tests on Linux and macOS.

## Running the core tests

```bash
cd Packages/KickMetricsCore
swift test
```
