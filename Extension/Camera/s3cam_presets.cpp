#include "s3cam_presets.h"
#include "s3cam.h"
#include "s3cam_preset_format.h"
#include "Engine/Core/Json/json.h"
#include "Engine/Core/Log/logging.h"
#include "Extension/Boot/user_data_redirect.h"

#include <Windows.h>
#include <shellapi.h>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

namespace dingosdk::client_source::detail {
namespace {
using logging::Channel;
using logging::Level;
namespace pf = dingosdk::s3cam_format;
namespace fs = std::filesystem;

constexpr std::size_t max_listed = 500; // a folder with more files than this is not a preset folder

std::vector<S3CamPresetEntry>& cache() {
    static std::vector<S3CamPresetEntry> list;
    return list;
}

S3CamPresetResult failure(std::string message) {
    S3CamPresetResult result;
    result.message = std::move(message);
    return result;
}
S3CamPresetResult success(std::string message, std::string name = {}) {
    S3CamPresetResult result;
    result.ok = true;
    result.message = std::move(message);
    result.name = std::move(name);
    return result;
}

// Runs one public operation; an exception (out of memory, a file system surprise) becomes a message.
template <class Fn> S3CamPresetResult guarded(const char* doing, Fn&& body) noexcept {
    try {
        return body();
    } catch (...) {
        try {
            logging::log(Level::warning, Channel::skater, "s3cam: presets: {} failed unexpectedly.", doing);
            return failure(std::string("Could not ") + doing + ".");
        } catch (...) { return {}; }
    }
}

std::wstring widen(std::string_view text) {
    if (text.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (size <= 0) return {};
    std::wstring result(static_cast<std::size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size);
    return result;
}
std::string narrow(std::wstring_view text) {
    if (text.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (size <= 0) return {};
    std::string result(static_cast<std::size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size, nullptr, nullptr);
    return result;
}

// Where the presets live: ReSkate's own folder in Local AppData (the one the music settings and the
// deck choice are kept in), not the game's redirected data.
fs::path folder() { return redirected_local_app_data().parent_path() / L"S3Cam Presets"; }

// The file of the preset `name`; empty when the name is not valid text.
fs::path file_of(std::string_view name) {
    const auto wide = widen(name);
    return wide.empty() ? fs::path{} : folder() / (wide + L".json");
}

bool file_exists(const fs::path& file) {
    std::error_code error;
    return !file.empty() && fs::exists(file, error);
}

bool is_built_in(std::string_view name) { return pf::find_builtin(name) < pf::builtin_count; }

// A name that no built-in and no file has.
std::string free_name(std::string_view wanted) {
    return pf::unique_name(wanted, [](std::string_view candidate) { return is_built_in(candidate) || file_exists(file_of(candidate)); });
}

std::optional<std::string> read_text(const fs::path& file) {
    std::error_code error;
    const auto size = fs::file_size(file, error);
    if (error || size > pf::max_preset_bytes) return std::nullopt;
    std::ifstream in(file, std::ios::binary);
    if (!in) return std::nullopt;
    std::string text{std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
    return text;
}

// Writes beside the target and renames over it, so a failed write never leaves half a preset.
bool write_text(const fs::path& file, const std::string& text) {
    std::error_code error;
    fs::create_directories(file.parent_path(), error);
    if (error) return false;
    auto temporary = file;
    temporary += L".tmp";
    {
        std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        out.write(text.data(), static_cast<std::streamsize>(text.size()));
        out.flush();
        if (!out) { out.close(); fs::remove(temporary, error); return false; }
    }
    fs::rename(temporary, file, error);
    if (error) { fs::remove(temporary, error); return false; }
    return true;
}

// What to tell the player besides "Loaded": values that were refused, and a preset from a newer ReSkate.
template <class Parsed> std::string refused_note(const Parsed& parsed) {
    std::string extra;
    if (parsed.report.refused)
        extra += " (" + std::to_string(parsed.report.refused) + " value(s) were out of range or the wrong type and kept their defaults)";
    if (parsed.from_newer_version) extra += " (made by a newer ReSkate: the settings this version knows were loaded)";
    return extra;
}

std::string error_message(pf::PresetError error, const std::string& what) {
    switch (error) {
    case pf::PresetError::too_large: return what + " is too large to be an S3Cam preset.";
    default: return what + " is not an S3Cam preset.";
    }
}

void note(const char* what, const std::string& name) {
    logging::log(Level::info, Channel::skater, "s3cam: preset {} '{}'.", what, name);
}

std::string lowered(const std::string& text) {
    std::string result = text;
    for (auto& c : result) c = pf::detail::lower_ascii(c);
    return result;
}
} // namespace

void s3cam_presets_refresh() noexcept {
    try {
        std::vector<S3CamPresetEntry> list;
        for (std::size_t i = 0; i < pf::builtin_count; ++i) list.push_back({pf::builtin_name(i), true});
        std::vector<std::string> names;
        std::error_code error;
        for (fs::directory_iterator at(folder(), error), end; !error && at != end && names.size() < max_listed; at.increment(error)) {
            std::error_code entry_error;
            if (!at->is_regular_file(entry_error)) continue;
            const auto& path = at->path();
            if (lowered(narrow(path.extension().wstring())) != ".json") continue;
            const auto stem = narrow(path.stem().wstring());
            if (stem.empty() || is_built_in(stem)) continue; // a built-in's name stays the built-in
            names.push_back(stem);
        }
        std::sort(names.begin(), names.end(), [](const std::string& a, const std::string& b) {
            const auto x = lowered(a), y = lowered(b);
            return x != y ? x < y : a < b;
        });
        for (auto& name : names) list.push_back({std::move(name), false});
        cache() = std::move(list);
    } catch (...) {
        // Keep the old list.
    }
}

const std::vector<S3CamPresetEntry>& s3cam_presets_list() noexcept {
    auto& list = cache();
    if (list.empty()) s3cam_presets_refresh();
    return list;
}

S3CamPresetResult s3cam_preset_load(const std::string& name) noexcept {
    return guarded("load the preset", [&] {
        if (const auto index = pf::find_builtin(name); index < pf::builtin_count) {
            if (!s3cam_set_settings(pf::builtin_settings(index))) return failure("That preset is not valid.");
            s3cam_set_options(S3CamOptions{}); // a built-in also puts the extra options back to their defaults
            note("loaded", pf::builtin_name(index));
            return success(std::string("Loaded '") + pf::builtin_name(index) + "'", pf::builtin_name(index));
        }
        const auto file = file_of(name);
        if (!file_exists(file)) return failure("'" + name + "' is not in the preset folder any more.");
        const auto text = read_text(file);
        if (!text) return failure("Could not read '" + name + "'.");
        pf::ParsedPreset<S3CamOptions> parsed;
        if (const auto error = pf::parse_preset(*text, parsed); error != pf::PresetError::none)
            return failure(error_message(error, "'" + name + "'"));
        if (!s3cam_set_settings(parsed.camera)) return failure("'" + name + "' does not hold valid settings.");
        s3cam_set_options(parsed.options);
        note("loaded", name);
        return success("Loaded '" + name + "'" + refused_note(parsed), name);
    });
}

S3CamPresetResult s3cam_preset_save(const std::string& name, bool overwrite) noexcept {
    return guarded("save the preset", [&] {
        const auto stem = pf::sanitize_name(name);
        if (stem.empty()) return failure("Type a name for the preset first.");
        if (is_built_in(stem)) return failure("'" + stem + "' is a built-in preset. Pick another name.");
        const auto file = file_of(stem);
        if (file.empty()) return failure("That name cannot be used for a file.");
        if (file_exists(file) && !overwrite) {
            auto result = failure("'" + stem + "' already exists.");
            result.confirm = true;
            result.name = stem;
            return result;
        }
        if (!write_text(file, pf::preset_text(stem, s3cam_settings(), s3cam_options())))
            return failure("Could not write the preset file for '" + stem + "'.");
        note("saved", stem);
        s3cam_presets_refresh();
        return success("Saved '" + stem + "'", stem);
    });
}

S3CamPresetResult s3cam_preset_rename(const std::string& from, const std::string& to) noexcept {
    return guarded("rename the preset", [&] {
        if (is_built_in(from)) return failure("Built-in presets cannot be renamed.");
        const auto stem = pf::sanitize_name(to);
        if (stem.empty()) return failure("Type the new name first.");
        if (is_built_in(stem)) return failure("'" + stem + "' is a built-in preset. Pick another name.");
        const auto old_file = file_of(from), new_file = file_of(stem);
        if (old_file.empty() || new_file.empty()) return failure("That name cannot be used for a file.");
        if (!file_exists(old_file)) return failure("'" + from + "' is not in the preset folder any more.");
        const bool same = pf::same_name(from, stem); // only the case changes: the same file
        if (!same && file_exists(new_file)) return failure("'" + stem + "' already exists.");

        // The name inside the file follows, so a shared copy carries the new name.
        bool written = false;
        if (const auto text = read_text(old_file)) {
            try {
                auto json = Json::parse(*text);
                if (json.is_object()) {
                    json["name"] = stem;
                    written = write_text(new_file, json.dump(2));
                }
            } catch (...) { written = false; }
        }
        std::error_code error;
        if (written) {
            if (!same) fs::remove(old_file, error);
        } else {
            fs::rename(old_file, new_file, error);
            if (error) return failure("Could not rename '" + from + "'.");
        }
        note("renamed", from + "' to '" + stem);
        s3cam_presets_refresh();
        return success("Renamed '" + from + "' to '" + stem + "'", stem);
    });
}

S3CamPresetResult s3cam_preset_delete(const std::string& name) noexcept {
    return guarded("delete the preset", [&] {
        if (is_built_in(name)) return failure("Built-in presets cannot be deleted.");
        const auto file = file_of(name);
        if (!file_exists(file)) {
            s3cam_presets_refresh();
            return failure("'" + name + "' is not in the preset folder any more.");
        }
        std::error_code error;
        fs::remove(file, error);
        if (error) return failure("Could not delete '" + name + "'.");
        note("deleted", name);
        s3cam_presets_refresh();
        return success("Deleted '" + name + "'", name);
    });
}

S3CamPresetResult s3cam_preset_export(const std::string& name) noexcept {
    return guarded("export the preset", [&] {
        S3CamPresetResult result;
        if (const auto index = pf::find_builtin(name); index < pf::builtin_count) {
            result = success(std::string("Copied '") + pf::builtin_name(index) + "' to the clipboard (a built-in has no file)",
                pf::builtin_name(index));
            result.text = pf::preset_text(pf::builtin_name(index), pf::builtin_settings(index), S3CamOptions{});
            return result;
        }
        const auto file = file_of(name);
        if (!file_exists(file)) return failure("'" + name + "' is not in the preset folder any more.");
        const auto text = read_text(file);
        if (!text) return failure("Could not read '" + name + "'.");
        pf::ParsedPreset<S3CamOptions> parsed;
        if (const auto error = pf::parse_preset(*text, parsed); error != pf::PresetError::none)
            return failure(error_message(error, "'" + name + "'"));
        result = success("Copied '" + name + "' to the clipboard; its file is in the preset folder", name);
        result.text = *text;
        note("exported", name);
        return result;
    });
}

S3CamPresetResult s3cam_preset_import(const std::string& text) noexcept {
    return guarded("import the preset", [&] {
        const auto first = text.find_first_not_of(" \t\r\n");
        if (first == std::string::npos) return failure("The clipboard is empty.");
        pf::ParsedPreset<S3CamOptions> parsed;
        if (const auto error = pf::parse_preset(std::string_view(text).substr(first), parsed); error != pf::PresetError::none)
            return failure(error == pf::PresetError::too_large ? error_message(error, "That clipboard text")
                                                               : "That clipboard text is not an S3Cam preset.");
        const auto stem = free_name(parsed.name);
        if (stem.empty()) return failure("Could not find a free name for the preset.");
        const auto file = file_of(stem);
        if (file.empty() || !write_text(file, pf::preset_text(stem, parsed.camera, parsed.options)))
            return failure("Could not write the preset file for '" + stem + "'.");
        note("imported", stem);
        s3cam_presets_refresh();
        return success("Imported '" + stem + "'" + refused_note(parsed), stem);
    });
}

S3CamPresetResult s3cam_presets_open_folder() noexcept {
    return guarded("open the preset folder", [&] {
        const auto where = folder();
        std::error_code error;
        fs::create_directories(where, error);
        if (error) return failure("Could not create the preset folder.");
        const bool opened = reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", where.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) > 32;
        return opened ? success("Opened the preset folder.") : failure("Could not open the preset folder.");
    });
}
}
