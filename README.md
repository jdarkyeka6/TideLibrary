# TideLibrary

TideLibrary is a native iPhone photo and video viewer built around Apple Photos and iCloud Photos.

## Current focus

TideLibrary is intentionally simple for now:

- **Photos** — a fast month-by-month Apple Photos timeline
- **People** — on-device recurring-face grouping
- **Search** — dates, media types, favourites, screenshots, Vision image labels and text found inside photos
- Full-screen swipe viewing, pinch zoom and video playback

## Privacy and storage

- Photos are referenced through PhotoKit instead of bulk-imported
- TideLibrary does not create a second copy of the user's entire photo library
- Search and face grouping run on-device
- Face groups are similarity-based and do not assign real-world identities or names
- Vision analysis uses resized working images instead of copying full-resolution originals into TideLibrary

Bundle ID: `com.jdarkyeka6.TideLibrary`
Deployment target: iOS 17
