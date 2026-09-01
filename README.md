# Present

Mirror a USB-connected iPhone on your Mac with low latency — like QuickTime's
movie recording preview — wrapped in a device bezel over a pretty background,
so the window looks good when shared in a call (Google Meet, Zoom, …).

## Build & run

```sh
./build.sh
open build/Present.app
```

First launch asks for **camera access** (that's how macOS gates iPhone screen
capture) — allow it. Then:

1. Connect your iPhone via USB-C.
2. Unlock it, and tap **Trust** if prompted.
3. The stream appears automatically.

## Usage

Hover over the window to reveal the control bar:

- **Status light** — shows the connected device / detected model.
- **iPhone button** — toggle the bezel on/off.
- **Sliders menu** — override the frame style (Dynamic Island / notch / home
  button; auto-detected from the stream resolution by default) and change the
  phone size.
- **Color dots** — background gradient presets.
- **Photo button** — pick your own background image.

Drag anywhere on the background to move the window. In Meet, share this
window.

## How it works

The app flips the CoreMediaIO `kCMIOHardwarePropertyAllowScreenCaptureDevices`
flag, which makes iOS devices show up as `AVCaptureDevice`s (the same
mechanism QuickTime uses). The stream renders through an
`AVCaptureVideoPreviewLayer`, the lowest-latency display path available. The
connected model is inferred from the stream's native pixel resolution.
