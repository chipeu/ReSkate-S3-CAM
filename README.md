# ReSkate S3 CAM

S3 CAM is a dynamic camera mod for ReSkate that recreates aspects of Skate 3's camera behaviour, with additional settings for customization.

---

## Features

S3 CAM is an optional dynamic camera designed to bring some of Skate 3's camera feel to ReSkate.

- **Dynamic Follow Camera** — The camera lags slightly when pushing, then catches up to follow the rider.
- **Pitch Prediction** — The camera adjusts its angle during big airs to help keep the landing area in view.
- **Landing Inertia** — Hard landings cause the camera to dip before gradually recentering.
- **Fully Adjustable Settings** — Toggle individual camera features and fine-tune their values in-game.
- **Preset Support** — Choose from available presets or create your own. Import and export presets to share your setups.

S3 CAM is disabled by default and can be enabled whenever you want. All camera settings can be adjusted through the in-game menu or console.

This is not an exact recreation of Skate 3's camera system. S3 CAM does not include Skate 3's original settings or any EA game files.

---

## Getting Started

1. Open the in-game menu with `Insert` and navigate to the **S3 CAMERA** page, or enable S3 CAM through the console using `s3cam on`.
2. Select a preset or configure your own camera settings.
3. Adjust settings using the in-game sliders, or use the console command `s3cam set <name> <value>`.
4. Save your custom presets. Presets are stored in `%LOCALAPPDATA%\ReSkate\camera\presets\`.
5. Ride and find the camera setup that works for you.

---

## Known Issues

- Jittery camera movement during big airs.
- Occasional camera snapping.
- Replay camera can freeze when opened while riding with S3 CAM enabled.

---

## Sources

- [ReSkate](https://github.com/Dingo-Shenanigans/ReSkate)
- [skate-3-rust-engine by SK8-ENGINE](https://github.com/SK8-ENGINE/skate-3-rust-engine)

---

## AI Disclosure

Parts of S3 CAM's development, including code, reverse-engineering notes, and documentation, were created with assistance from AI coding tools. The maintainers review and test the work, but AI-generated code can contain mistakes like any other code. If you encounter an issue, please open a report.
