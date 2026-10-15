#pragma once
#include "Extension/Skater/client_source_spawn_internal.h"
#include <array>
#include <cstdint>
#include <string>

// S3Cam Phase 0 spikes (docs/s3cam/SPIKES.md). Throwaway instrumentation, removed when the real
// S3Cam ownership (T9) lands. Everything here runs on the engine thread inside the debug tick.
//
//   s3cam_probe 1  S1: takes the view through Freecam's verified mode-1 path (as first person
//                  does) and holds a fixed chase pose behind the skater, while logging whether the
//                  native gameplay camera keeps updating underneath (B1 vs B2), S2 candidate
//                  signals, and S4 gravity fitted from every airborne arc.
//   s3cam_probe 2  S1b: the same pose, written into the game's own camera after its update instead
//                  of taking the FreeCamera. Skipped off board and whenever another camera shows,
//                  so the replay editor, menus and the right stick stay the game's.
//   s3cam_ray      S3: casts the park editor's physics ray under and around the skater and times
//                  batches of 10 casts.
namespace dingosdk::client_source::detail {
// `native` is the mode-0 snapshot taken before the probe switches to mode 1; `view` its matrix.
void s3cam_probe_arm(const SourceTrial& trial, const SourceCameraSnapshot& native, const std::array<float, 16>& view,
    bool overlay = false);
// Mode 2: one engine-thread tick, after the game's camera update. `ready` is the debug tick's
// can-control and verified-camera-phase. Throws SourceGuard when the camera cannot be read.
void s3cam_overlay_tick(const SourceTrial& trial, std::uintptr_t client, bool ready);
// Mode 2's write, from the native camera update's listener (camera_observer.h).
void s3cam_camera_updated(std::uintptr_t camera) noexcept;
// The probe's pose for this tick, built on `previous` (row fourth lanes are kept). Throws
// SourceGuard when the skater cannot be read; the caller then holds the last pose.
std::array<float, 16> s3cam_probe_pose(const SourceTrial& trial, std::uintptr_t client, const std::array<float, 16>& previous);
// Logs the session summary once; safe to call when not armed.
void s3cam_probe_disarm(const char* reason) noexcept;
bool s3cam_probe_armed() noexcept;
std::string s3cam_ray_report(const SourceTrial& trial, std::uintptr_t client);
}
