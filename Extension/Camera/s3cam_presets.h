#pragma once

// S3Cam presets (Alpha 3): named sets of every saved S3Cam field, kept one JSON file each in
// "<Local AppData>\ReSkate\Dynamic Camera Presets\<name>.json" (formerly "S3Cam Presets", moved on first use) (beside ReSkate's other user files: the music
// settings, the deck choice and the like; Extension/Boot/user_data_redirect.h resolves the folder).
// Built-in presets live in code (s3cam_preset_format.h) and cannot be deleted. The JSON format, the
// name rules and the built-ins are in s3cam_preset_format.h (pure, tested on Linux); this file is the
// folder, the files and the live settings.
//
// Everything here is called from the overlay thread on a button press or when the page opens, never
// once per frame: the list is cached and only s3cam_presets_refresh() scans the folder. Not for
// concurrent use. Nothing throws; every failure comes back as a result with a message to show.
//
// Compiled into the runtime target (Extension/Camera/s3cam_presets.cpp); the overlay is a static
// library linked into it, as for s3cam_config.h.
#include <string>
#include <vector>

namespace dingosdk::client_source::detail {
struct S3CamPresetEntry {
    std::string name; // the file's name without ".json", or the built-in's name
    bool built_in{};
};

struct S3CamPresetResult {
    bool ok{};
    bool confirm{};      // save: the name is taken; call again with overwrite = true to replace it
    std::string message; // one line for the player ("Saved 'Park cam'")
    std::string name;    // the preset that was saved, loaded, renamed to or imported
    std::string text;    // export: the preset's JSON, for the clipboard
};

// Rescans the folder (built-ins first, then the files by name).
void s3cam_presets_refresh() noexcept;
// The cached list from the last refresh. The reference stays valid until the next refresh.
const std::vector<S3CamPresetEntry>& s3cam_presets_list() noexcept;
// Applies the preset's settings and options through s3cam_set_settings / s3cam_set_options (a built-in
// sets the options to their defaults); the saver then persists them. S3Cam stays on or off as it was.
S3CamPresetResult s3cam_preset_load(const std::string& name) noexcept;
// Saves the live settings and options under `name` (made safe for a file name).
S3CamPresetResult s3cam_preset_save(const std::string& name, bool overwrite) noexcept;
S3CamPresetResult s3cam_preset_rename(const std::string& from, const std::string& to) noexcept;
S3CamPresetResult s3cam_preset_delete(const std::string& name) noexcept;
// The preset's JSON in `text`. A saved preset already is a file in the folder; a built-in has none.
S3CamPresetResult s3cam_preset_export(const std::string& name) noexcept;
// Saves the preset in `text` (a pasted JSON) as a new preset, with a free name.
S3CamPresetResult s3cam_preset_import(const std::string& text) noexcept;
// Opens the folder in Explorer (created if missing).
S3CamPresetResult s3cam_presets_open_folder() noexcept;
}
