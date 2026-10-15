#pragma once

// S3Cam saved settings (card T10): the player's choices persist between launches in the profile's
// ReSkate store (Extension/Profile/local_profile_runtime.h, profile_runtime::local_value), under keys
// "S3Cam.<Group>.<Field>". Only player-facing fields are saved; the Skate 3 tracker internals
// (rig, graph, orientation, air, trajectory, pipeline, points) stay at their code defaults.
//
// The field table, the load pass and the text choices are shared with the presets
// (Extension/Camera/s3cam_preset_format.h, pure and tested on Linux; the presets themselves are
// Extension/Camera/s3cam_presets.h).
//
// Compiled into the runtime target (Extension/Camera/s3cam_config.cpp). The overlay's S3 CAMERA page
// (Extension/UI/Overlay/skate_menu_camera.cpp) calls s3cam_config_reset() directly: the overlay is a
// static library linked into the runtime DLL, as for the Music page's calls into music_inject.
namespace dingosdk::client_source::detail {
// Applies the saved choices over the current settings and options. A key that is missing, of the
// wrong type or out of range keeps the current value (the default at startup); one warning line is
// logged when saved values were refused. Call once at startup, before S3Cam runs.
void s3cam_config_load() noexcept;
// Writes every saved field (one transaction). Best effort: a failure is silent, the settings
// already apply. Call debounced when s3cam_settings_revision() changes.
void s3cam_config_save() noexcept;
// Settings and options back to the code defaults (applies at once; the saver then writes them).
void s3cam_config_reset() noexcept;
}
