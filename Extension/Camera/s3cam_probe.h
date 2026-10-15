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
//   s3cam_ray      S3: casts the park editor's physics ray under and around the skater and times
//                  batches of 10 casts.
namespace dingosdk::client_source::detail {
// `native` is the mode-0 snapshot taken before the probe switches to mode 1; `view` its matrix.
void s3cam_probe_arm(const SourceTrial& trial, const SourceCameraSnapshot& native, const std::array<float, 16>& view);
// The probe's pose for this tick, built on `previous` (row fourth lanes are kept). Throws
// SourceGuard when the skater cannot be read; the caller then holds the last pose.
std::array<float, 16> s3cam_probe_pose(const SourceTrial& trial, std::uintptr_t client, const std::array<float, 16>& previous);
// Logs the session summary once; safe to call when not armed.
void s3cam_probe_disarm(const char* reason) noexcept;
bool s3cam_probe_armed() noexcept;
std::string s3cam_ray_report(const SourceTrial& trial, std::uintptr_t client);
}
