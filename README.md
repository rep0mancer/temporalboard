# TemporalBoard

An intuitive whiteboard app inspired by Apple Freeform — with a twist. Write anything on the canvas, and if it contains a time or duration, TemporalBoard automatically recognizes it and starts a live countdown. When the timer reaches zero, you get a visual pulse, haptic feedback, and an alert sound.

## Requirements

- iOS 16.0+
- Xcode 15+
- Apple Pencil supported (works with finger input too)

## Getting Started

1. **Clone the repository**
   ```bash
   git clone https://github.com/rep0mancer/temporalboard.git
   ```
2. **Open in Xcode** — open the project and select your target device or simulator.
3. **Build and run** — the app requires no external dependencies.
4. **Allow notifications** — on first launch, tap "Allow" when prompted. This enables timer alerts when the app is in the background.

## How to Use

### Writing Timers

Open the app and start writing on the canvas with Apple Pencil or your finger. TemporalBoard watches for anything that looks like a time and automatically creates a countdown.

**Durations** — write a number followed by a unit:

| You write | Timer starts for |
|---|---|
| `15 min` | 15 minutes from now |
| `2h` | 2 hours from now |
| `90s` | 90 seconds from now |
| `1h 30m` | 1 hour 30 minutes from now |
| `45 minutes` | 45 minutes from now |

**Clock times** — write an absolute time of day:

| You write | Timer targets |
|---|---|
| `3pm` | 3:00 PM today (or tomorrow if already past) |
| `14:30` | 2:30 PM in 24-hour format |
| `2:30 PM` | 2:30 PM |
| `at 5` | 5:00 today |
| `um 15` | 3:00 PM (German "at" keyword) |

**Dates** — write a day/month with an optional time:

| You write | Timer targets |
|---|---|
| `03.02` | February 3rd at 9:00 AM |
| `03/02 14:30` | February 3rd at 2:30 PM |

You can embed times in natural sentences too — "Meeting in 15 min", "Call mom at 3pm", "Lunch 12:30" all work.

### Multilingual Support

Time units are recognized in English, German, Spanish, French, and Italian:

- **English:** min, hour, sec, ...
- **German:** Stunde, Minuten, Sekunden, um ...
- **Spanish:** hora, minuto, ...
- **French:** heure, minute, ...
- **Italian:** ora, minuti, ...

### Reading the Countdown

After you finish writing, a small countdown badge appears below your handwriting within about 1.5 seconds. The badge changes color as the deadline approaches:

- **Accent color** — more than 5 minutes remaining
- **Yellow/Orange** — under 5 minutes
- **Orange** — under 1 minute
- **Red** — under 30 seconds
- **Blinking red** — timer expired, showing overtime as `-MM:SS`

The badge picks up the ink color you used, so timers match the color of your handwriting.

### When a Timer Expires

Three things happen simultaneously:

1. **Visual pulse** — a glowing highlight animation appears over your handwritten text
2. **Haptic feedback** — a warning vibration followed by a heavy impact
3. **Alert sound** — the system tri-tone plays

If the app is in the background, you receive a system notification instead.

### Managing Timers

**Tap any countdown badge** to open an action sheet with these options:

- **Dismiss Alert** — silence an expired timer's visual and haptic alerts
- **Restart Timer** — re-parse the original text and start the duration again (duration timers only)
- **+1 / +5 / +10 / +15 min** — extend an expired timer
- **+5 / +10 / +15 / +30 min** — add time to a running timer
- **Edit Time...** — type a new time or duration manually
- **Delete Timer** — remove the timer entirely

**Top bar controls:**

- The **active timer count** badge shows how many timers are still running
- The **red bell badge** shows how many timers have expired and need attention
- **Silence** button — dismiss all expired timer alerts at once
- **Overflow menu (...)** — clear finished timers or clear all timers

### Canvas Features

- **Infinite canvas** — scroll and pan in any direction
- **Pinch to zoom** — 0.25x to 4x zoom range
- **Full PencilKit toolbar** — pen, pencil, marker, eraser, ruler, lasso, and color picker
- **Dot grid background** — subtle Freeform-style grid that adapts to light and dark mode
- **Auto-save** — drawings and timers persist automatically to disk

## Project Structure

| File | Purpose |
|---|---|
| `TemporalBoardApp.swift` | App entry point, AppDelegate for notification permissions, `BoardViewModel` for state management and persistence, `ContentView` SwiftUI layout |
| `CanvasView.swift` | `UIViewRepresentable` wrapping PencilKit, text recognition coordinator, timer/highlight overlay views, dot grid background |
| `TimeParser.swift` | Regex-based time and duration parser with multi-language support |
| `models.swift` | `BoardTimer` data model with Codable support, UIColor hex conversion helpers |

## License

All rights reserved.
