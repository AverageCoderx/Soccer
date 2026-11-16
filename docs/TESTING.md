# First tests on the phone

The measurement core has been tested on synthetic data only. These steps
check it on real video, cheapest first. Each result screen has **Tracking
details** and **Share report**: if something looks wrong, the report (a
small JSON file of measurement data, no personal information) is what's
needed to fix it.

## 1. Setup check (2 minutes)

1. Phone on a tripod, **landscape**, level, about 5–6 m from where the ball
   will be, side-on to where you'll kick.
2. Open **Measure**. The top bar should read `1920×1080 · 240 fps · 1× camera`.
3. Put the ball down and **tap it** on screen. A blue ring should appear
   around it.
4. The checklist should go green: Ball, Distance (should be close to what
   you'd guess), Light, Steady, Level.

Note anything that doesn't go green.

## 2. Drop test (scale check, no radar needed)

1. On Measure, choose **Drop test**.
2. Hold the ball still at about head height, side-on to the camera, in the
   middle of the picture. Tap it on screen (or ask someone to).
3. Press **Start**, wait a second, then let go without pushing.
4. The result is the measured gravity. It should be close to 9.81 m/s².
5. Repeat 5 times. The **Validate** tab shows the average scale error.

An average within about ±2% means the distance scale (which every speed
depends on) is working.

## 3. Shots

1. Choose **Shot**, place the ball, tap it, press **Start**, kick across the
   picture.
2. Recording stops by itself about a second after the kick.
3. The result is either a speed with ± and a confidence, or **Not measured**
   with the reasons.

Try: a medium-pace shot straight across the frame; a hard shot; a shot angled
about 30° toward the camera; and one at the edge of the frame.

## 4. Radar (later)

With a radar gun behind the ball, aimed along the shot, enter its reading on
each result screen. The Validate tab then shows bias, mean error and 95%
limits of agreement. Aim for at least 10 shots before drawing conclusions.

## Known limitations of this first version

- The ball must be locked by tapping it; there's no automatic ball finding yet.
- Tracking assumes a still camera (tripod) and one ball in play.
- Rolling-shutter timing isn't calibrated (it adds a small uncertainty to
  lofted shots, shown in the ± value).
- Trajectory, launch angle, flight distance and spin aren't implemented yet.
