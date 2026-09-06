# PNClip platform contract v1

This contract is the boundary between the shared C++20 application core and a
platform UI/adapter. Platform implementations are selected by the build; common
sources never select an operating system with preprocessor branches.

## Coordinates and native identifiers

- `WindowId` and `displayId` are opaque identifiers. The core stores and returns
  them but never interprets them as native pointers.
- `CaptureTarget::captureArea` uses logical units, with its origin at the
  selected display's top-left. It is never a virtual-desktop or native-screen
  coordinate.
- `sourceWindowSize` carries width and height in logical units. Its origin is
  ignored.
- `cropPixels` is a top-left-origin rectangle in the backend's captured output.
- `pixelScale` converts logical units to native pixels when `nativeScale` is
  true. A standard-scale capture uses 1.0.
- A target is valid only when it has a nonzero session identifier and pixel
  scale, plus a nonempty display area or a native window with a nonempty size.

These rules let AppKit convert its bottom-left global coordinates at the UI
boundary and let a Windows UI pass display-local DIPs without changing Core.

## Capture session lifecycle

- `sessionId` is allocated by the platform UI and remains stable for the life of
  one capture overlay.
- `isRecording` and `isRolling` return true during asynchronous startup as well
  as active capture.
- `stopRecording` and `stopRolling` cancel an operation that is still starting.
- A normal recording callback fires exactly once with either a final path or an
  error. Cancellation may complete successfully with an empty path.
- A rolling callback fires for a startup error and once for every accepted save.
  Stopping rolling capture does not produce a saved path.
- Backend callbacks may arrive on any thread. A platform UI must marshal UI work
  to its own UI thread.

## Ownership

`AppController` does not own backends. A platform composition root owns every
backend for longer than the controller. Native resources and framework types
must not appear in `PNClip/Core` public headers.

## Windows implementation boundary

Windows work replaces the bodies of `*Win.cpp` files and adds the independent
Windows UI entry point. It must not require changes to `PNClip/Core`. The Windows
UI performs native window/display discovery and coordinate conversion, creates
`CaptureTarget`, and invokes `AppController`, matching the existing Mac UI role.
