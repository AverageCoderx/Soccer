# Soccer Tracker: notes for Claude

## Privacy rule (highest priority)

This repository is **public**. Never add the owner's personal or identifying
information to it, in any form:

- no real names, usernames other than what's already in the repo URL, emails,
  phone numbers, addresses, locations, schools, clubs or teams;
- not in code, comments, docs, commit messages, test data, file names or
  file metadata (EXIF/GPS in images or video);
- no real recordings of people. Test data is synthetic. A real clip may only be
  committed if the owner explicitly approves it, after checking it and
  stripping its metadata.

Files the owner shares in chat (clips, debug reports, screenshots) stay out of
the repo. Review every diff for this before committing.

## Project

Native iOS app (Swift / SwiftUI) that measures soccer shot speed from the
iPhone camera. The owner has no Mac: iOS builds run on GitHub Actions macOS
runners, and the unsigned `.ipa` is sideloaded from Windows with Sideloadly
using a free Apple ID.

- `Packages/SoccerTrackerCore`: pure Swift (Foundation only), no Apple-only
  frameworks, so it builds and tests on Linux. Geometry, physics, tracking,
  fitting, validation statistics, synthetic test data.
- `App/`: the iOS app (camera, recording, SwiftUI screens), built in CI from
  `project.yml` with XcodeGen.

Run the core tests with:

```bash
cd Packages/SoccerTrackerCore && swift test
```

## Engineering rules

- Never fabricate measurements. If a value can't be measured reliably, report
  it as unavailable with a reason.
- Label values as measured vs. estimated.
- Use real frame timestamps, never an assumed frame interval.
- Comment the physics.
