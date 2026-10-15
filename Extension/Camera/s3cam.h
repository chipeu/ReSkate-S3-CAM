#pragma once
#include "Engine/Game/Camera/s3_settings.h"
#include "Extension/Skater/client_source_spawn_internal.h"
#include <array>
#include <cstdint>
#include <string>

// S3Cam game glue (cards T7 and T9, alpha): reads the local skater into a SubjectSnapshot, runs the
// pure camera core (Engine/Game/Camera/s3_camera.h) and publishes its pose through the FreeCamera
// that client_debug.cpp takes (mode 1, as first person does). Ownership itself (taking the camera,
// handing it back off board, in menus and in the replay editor) lives in client_debug.cpp; this
// file only answers "does S3Cam want the view" and "what is the pose".
//
// Everything here runs on the engine thread inside the debug tick, except the settings functions,
// which the console may call from its own thread: they only touch the settings under a lock.
namespace dingosdk::client_source::detail {
struct S3CamObservation {
    bool valid{};          // the skater was readable this tick
    bool wants_view{};     // on the board, or bailing (the Wipeout shot)
    double wants_for{};    // s the current wants_view value has held
    std::uint32_t state{}; // physics state (context +0x1414)
};
// Reads the skater once for this tick; s3cam_pose() reuses the reading. Never throws.
S3CamObservation s3cam_observe(const SourceTrial& trial, std::uintptr_t client) noexcept;
// Starts a camera run: `native_camera` is the game's own camera (mode 0's active camera, read by
// Native+ every tick), `view` its matrix at the moment S3Cam takes the FreeCamera.
void s3cam_begin(const SourceTrial& trial, std::uintptr_t native_camera, const std::array<float, 16>& view);
// This tick's pose on `previous` (row fourth lanes kept), from this tick's s3cam_observe() reading.
// Throws SourceGuard when there is no usable reading; the caller then holds the last pose.
// `fov` receives the field of view to write (vertical degrees), or 0 to leave the camera's own.
std::array<float, 16> s3cam_pose(const SourceTrial& trial, const std::array<float, 16>& previous, float& fov);
// Ends the run and logs its summary; safe when not running.
void s3cam_end(const char* reason) noexcept;
bool s3cam_running() noexcept;
// Logs what the hand-back logic sees whenever it changes: the client flow state (+0xc4), whether the
// tick may control and whether the camera phase is verified, and the camera mode. Answers the T9
// question of what the pause menu and the replay editor look like from the tick.
void s3cam_note_flow(std::uintptr_t client, bool can_control, bool phase, const SourceCameraSnapshot* camera,
    bool owned) noexcept;
void s3cam_note(const char* what) noexcept;

// Settings (console thread or engine thread). Applied to the camera on its next pose.
s3cam::CameraSettings s3cam_settings() noexcept;
bool s3cam_set_settings(const s3cam::CameraSettings& settings) noexcept;
// Glue options (not camera-core tunables). Applied on the camera's next frame.
struct S3CamOptions {
    bool shot_fov = true;            // S3Cam drives the FOV (base + the FovSettings terms); off: the camera keeps its own
    bool verbose = true;             // log state and shot changes and a line per landing
    bool follow_game_height = true;  // the game's camera height button (R3) picks S3 Low / High
    float take_blend_time = 0.5f;    // s: crossfade from the game camera when S3Cam takes the view
    float release_blend_time = 0.4f; // s: crossfade back to the game camera before handing it back (on foot)
};
// Bumped by every settings / options change: a saver can watch it.
std::uint64_t s3cam_settings_revision() noexcept;
S3CamOptions s3cam_options() noexcept;
void s3cam_set_options(const S3CamOptions& options) noexcept;
// One human-readable block: settings that matter in play and the last frame's debug values.
std::string s3cam_dump();
}
