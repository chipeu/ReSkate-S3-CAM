#pragma once

// S3Cam saved fields and presets, the pure half (no Windows, no game, no files): the field table that
// the profile saver / loader and the presets share, the preset JSON format, name sanitising and the
// built-in presets. Header-only so a Linux test can run it (Extension/Camera/Test/s3cam_presets_tests.cpp).
//
// The glue (s3cam_config.cpp: the profile; s3cam_presets.cpp: preset files and the clipboard text)
// supplies the one piece this file cannot name, the glue's S3CamOptions, as a template parameter, and
// the source of saved values as a callable `std::optional<Json>(const char* key)`.
//
// Preset file (UTF-8 JSON, version 1; keys are the profile's "S3Cam.<Group>.<Field>" keys):
//   { "name": "Park cam", "version": 1, "values": { "S3Cam.Framing.DistanceScale": 0.85, ... } }
// Unknown keys are ignored, a missing key keeps the default, and a value of the wrong type or out of
// range is refused on its own while the rest still load.
//
// Compatibility rules (older presets must keep working with newer builds, and the other way round):
//  * Version 1 stays readable forever. A key that did not exist when a preset was made is simply
//    missing, so the field keeps its default.
//  * A preset with a higher version than preset_version still loads every key this build knows (the
//    result says so in ParsedPreset::from_newer_version); only a version below 1 is refused.
//  * Renaming a saved key later: keep the old spelling in key_aliases (old key -> new key). The loader,
//    shared by the profile and the preset import, reads the new key first and falls back to its aliases.
//    Never reuse an old key for a different field. Bump preset_version only when the meaning of
//    existing keys changes in a way an alias cannot express.
#include "Engine/Core/Json/json.h"
#include "Engine/Game/Camera/s3_settings.h"

#include <array>
#include <charconv>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <span>
#include <string_view>
#include <system_error>
#include <type_traits>
#include <utility>
#include <vector>

namespace dingosdk::s3cam_format {
namespace cfg = ::dingosdk::s3cam;

inline constexpr int preset_version = 1;
inline constexpr std::size_t max_name_chars = 48;
inline constexpr std::size_t max_preset_bytes = 256 * 1024; // a preset is a few KB; this bounds a pasted text or a stray file

// ---- Validity ----

// A group is valid when it says so; the glue's options struct has no valid(): its two blend times
// must be sane (the same bound the console and the page use).
template <class Group> bool group_ok(const Group& group) noexcept {
    if constexpr (requires { group.valid(); }) {
        return group.valid();
    } else {
        const auto time_ok = [](float seconds) { return std::isfinite(seconds) && seconds >= 0.0f && seconds <= 5.0f; };
        return time_ok(group.take_blend_time) && time_ok(group.release_blend_time);
    }
}

// ---- The field table ----

// Every saved numeric / boolean field once, so loading and saving cannot drift apart. `visit` is
// called as visit(key, group, &Group::member).
template <class Options, class Visit> void visit_fields(cfg::CameraSettings& camera, Options& options, Visit&& visit) {
    visit("S3Cam.ShakeEnabled", camera, &cfg::CameraSettings::shake_enabled);

    visit("S3Cam.Framing.DistanceScale", camera.framing, &cfg::FramingSettings::distance_scale);
    visit("S3Cam.Framing.HeightDegrees", camera.framing, &cfg::FramingSettings::height_degrees);
    visit("S3Cam.Framing.PitchDegrees", camera.framing, &cfg::FramingSettings::pitch_degrees);
    visit("S3Cam.Framing.ManualCamera", camera.framing, &cfg::FramingSettings::manual_camera);
    visit("S3Cam.Framing.ManualDistanceScale", camera.framing, &cfg::FramingSettings::manual_distance_scale);
    visit("S3Cam.Framing.ManualHeightDegrees", camera.framing, &cfg::FramingSettings::manual_height_degrees);
    visit("S3Cam.Framing.GrindCamera", camera.framing, &cfg::FramingSettings::grind_camera);
    visit("S3Cam.Framing.GrindDistanceScale", camera.framing, &cfg::FramingSettings::grind_distance_scale);
    visit("S3Cam.Framing.GrindHeightDegrees", camera.framing, &cfg::FramingSettings::grind_height_degrees);

    // The High camera's position (the Low one keeps the S3Cam.Framing.* keys, so old presets still mean Low).
    visit("S3Cam.FramingHigh.DistanceScale", camera.framing_high, &cfg::FramingSettings::distance_scale);
    visit("S3Cam.FramingHigh.HeightDegrees", camera.framing_high, &cfg::FramingSettings::height_degrees);
    visit("S3Cam.FramingHigh.PitchDegrees", camera.framing_high, &cfg::FramingSettings::pitch_degrees);
    visit("S3Cam.FramingHigh.ManualCamera", camera.framing_high, &cfg::FramingSettings::manual_camera);
    visit("S3Cam.FramingHigh.ManualDistanceScale", camera.framing_high, &cfg::FramingSettings::manual_distance_scale);
    visit("S3Cam.FramingHigh.ManualHeightDegrees", camera.framing_high, &cfg::FramingSettings::manual_height_degrees);
    visit("S3Cam.FramingHigh.GrindCamera", camera.framing_high, &cfg::FramingSettings::grind_camera);
    visit("S3Cam.FramingHigh.GrindDistanceScale", camera.framing_high, &cfg::FramingSettings::grind_distance_scale);
    visit("S3Cam.FramingHigh.GrindHeightDegrees", camera.framing_high, &cfg::FramingSettings::grind_height_degrees);

    visit("S3Cam.AirCamera.FollowHeight", camera.air_camera, &cfg::AirCameraSettings::follow_height);
    visit("S3Cam.AirCamera.RiseDegrees", camera.air_camera, &cfg::AirCameraSettings::rise_degrees);
    visit("S3Cam.AirCamera.RiseFullHeight", camera.air_camera, &cfg::AirCameraSettings::rise_full_height);
    visit("S3Cam.AirCamera.EaseTime", camera.air_camera, &cfg::AirCameraSettings::ease_time);
    visit("S3Cam.AirCamera.KeepInFrame", camera.air_camera, &cfg::AirCameraSettings::keep_in_frame);

    visit("S3Cam.TrickYaw.Enabled", camera.trick_yaw, &cfg::TrickYawSettings::enabled);
    visit("S3Cam.TrickYaw.AngleDegrees", camera.trick_yaw, &cfg::TrickYawSettings::angle_degrees);
    visit("S3Cam.TrickYaw.InAir", camera.trick_yaw, &cfg::TrickYawSettings::in_air);
    visit("S3Cam.TrickYaw.OnGrinds", camera.trick_yaw, &cfg::TrickYawSettings::on_grinds);
    visit("S3Cam.TrickYaw.OnManuals", camera.trick_yaw, &cfg::TrickYawSettings::on_manuals);
    visit("S3Cam.TrickYaw.MinAirTime", camera.trick_yaw, &cfg::TrickYawSettings::min_air_time);
    visit("S3Cam.TrickYaw.InTime", camera.trick_yaw, &cfg::TrickYawSettings::in_time);
    visit("S3Cam.TrickYaw.HoldTime", camera.trick_yaw, &cfg::TrickYawSettings::hold_time);
    visit("S3Cam.TrickYaw.ReturnTime", camera.trick_yaw, &cfg::TrickYawSettings::return_time);

    visit("S3Cam.Look.LandingLook", camera.look, &cfg::LookSettings::landing_look);
    visit("S3Cam.Look.LandingLookStrength", camera.look, &cfg::LookSettings::landing_look_strength);
    visit("S3Cam.Look.LandingLookFullDrop", camera.look, &cfg::LookSettings::landing_look_full_drop);
    visit("S3Cam.Look.SlopeLook", camera.look, &cfg::LookSettings::slope_look);
    visit("S3Cam.Look.SlopeLookStrength", camera.look, &cfg::LookSettings::slope_look_strength);
    visit("S3Cam.Look.VerticalFollow", camera.look, &cfg::LookSettings::vertical_follow);
    visit("S3Cam.Look.ResponseTime", camera.look, &cfg::LookSettings::response_time);
    visit("S3Cam.Look.ManualFocus", camera.look, &cfg::LookSettings::manual_focus);
    visit("S3Cam.Look.GrindFocus", camera.look, &cfg::LookSettings::grind_focus);

    visit("S3Cam.Shoulder.Offset", camera.shoulder, &cfg::ShoulderSettings::offset);
    visit("S3Cam.Shoulder.SwitchTime", camera.shoulder, &cfg::ShoulderSettings::switch_time);

    visit("S3Cam.Follow.Strength", camera.follow, &cfg::FollowSettings::strength);
    visit("S3Cam.Follow.Dynamic", camera.follow, &cfg::FollowSettings::dynamic);
    visit("S3Cam.Follow.DynamicSpeed", camera.follow, &cfg::FollowSettings::dynamic_speed);
    visit("S3Cam.Follow.DynamicBoost", camera.follow, &cfg::FollowSettings::dynamic_boost);
    visit("S3Cam.Follow.Horizontal", camera.follow, &cfg::FollowSettings::horizontal);

    visit("S3Cam.Fov.ShotLens", camera.fov, &cfg::FovSettings::shot_fov);
    visit("S3Cam.Fov.SpeedFov", camera.fov, &cfg::FovSettings::speed_fov);
    visit("S3Cam.Fov.SpeedFovDegrees", camera.fov, &cfg::FovSettings::speed_fov_degrees);
    visit("S3Cam.Fov.SpeedFovMin", camera.fov, &cfg::FovSettings::speed_fov_min);
    visit("S3Cam.Fov.SpeedFovMax", camera.fov, &cfg::FovSettings::speed_fov_max);
    visit("S3Cam.Fov.AirFov", camera.fov, &cfg::FovSettings::air_fov);
    visit("S3Cam.Fov.AirFovDegrees", camera.fov, &cfg::FovSettings::air_fov_degrees);
    visit("S3Cam.Fov.AirFovFullHeight", camera.fov, &cfg::FovSettings::air_fov_full_height);
    visit("S3Cam.Fov.SmoothingTime", camera.fov, &cfg::FovSettings::smoothing_time);

    visit("S3Cam.Shake.LandingStrength", camera.shake, &cfg::ShakeSettings::one_shot_magnitude);
    visit("S3Cam.LandingShake.MinFall", camera.landing_shake, &cfg::LandingShakeSettings::min_fall);
    visit("S3Cam.LandingShake.FullFall", camera.landing_shake, &cfg::LandingShakeSettings::full_fall);
    visit("S3Cam.LandingShake.SpeedWeight", camera.landing_shake, &cfg::LandingShakeSettings::speed_weight);
    visit("S3Cam.SpeedShake.Enabled", camera.speed_shake, &cfg::SpeedShakeSettings::enabled);
    visit("S3Cam.SpeedShake.Strength", camera.speed_shake, &cfg::SpeedShakeSettings::strength);
    visit("S3Cam.SpeedShake.TopSpeed", camera.speed_shake, &cfg::SpeedShakeSettings::top_speed);
    visit("S3Cam.SpeedShake.DownhillBoost", camera.speed_shake, &cfg::SpeedShakeSettings::downhill_boost);
    visit("S3Cam.SpeedShake.DownhillScale", camera.speed_shake, &cfg::SpeedShakeSettings::downhill_scale);
    visit("S3Cam.SpeedShake.DownhillFullDegrees", camera.speed_shake, &cfg::SpeedShakeSettings::downhill_full_degrees);

    visit("S3Cam.Collision.Enabled", camera.collision, &cfg::CollisionSettings::enabled);
    visit("S3Cam.Collision.Radius", camera.collision, &cfg::CollisionSettings::radius);
    visit("S3Cam.Collision.MinDistance", camera.collision, &cfg::CollisionSettings::min_distance);
    visit("S3Cam.Collision.PullInTime", camera.collision, &cfg::CollisionSettings::pull_in_time);
    visit("S3Cam.Collision.ReleaseTime", camera.collision, &cfg::CollisionSettings::release_time);
    visit("S3Cam.Collision.GroundClearance", camera.collision, &cfg::CollisionSettings::ground_clearance);

    visit("S3Cam.NativePlus.AirHold", camera.native_plus, &cfg::NativePlusSettings::air_hold);
    visit("S3Cam.NativePlus.LandingDip", camera.native_plus, &cfg::NativePlusSettings::landing_dip);
    visit("S3Cam.NativePlus.Shake", camera.native_plus, &cfg::NativePlusSettings::shake);
    visit("S3Cam.NativePlus.Roll", camera.native_plus, &cfg::NativePlusSettings::roll);
    visit("S3Cam.NativePlus.DipDepth", camera.native_plus, &cfg::NativePlusSettings::dip_depth);
    visit("S3Cam.NativePlus.DipPeakTime", camera.native_plus, &cfg::NativePlusSettings::dip_peak_time);

    visit("S3Cam.Options.ShotFov", options, &Options::shot_fov);
    visit("S3Cam.Options.Logging", options, &Options::verbose);
    visit("S3Cam.Options.FollowGameHeight", options, &Options::follow_game_height);
    visit("S3Cam.Options.TakeBlendTime", options, &Options::take_blend_time);
    visit("S3Cam.Options.ReleaseBlendTime", options, &Options::release_blend_time);
}

// ---- Text choices (their names are part of the saved file; keep them stable) ----
inline constexpr std::array<const char*, 2> preset_names{"full", "native"};
inline constexpr std::array<const char*, 2> angle_names{"low", "high"};
inline constexpr std::array<const char*, 3> shoulder_names{"off", "manual", "auto"};
inline constexpr std::array<const char*, 2> side_names{"left", "right"}; // the side the camera sits on, as ShoulderSettings::side
inline constexpr std::array<const char*, 2> stance_names{"regular", "goofy"};
inline constexpr std::array<const char*, 3> trick_side_names{"auto", "left", "right"}; // TrickYawSettings::side 0, -1, +1

inline int trick_side_index(int side) noexcept { return side < 0 ? 1 : side > 0 ? 2 : 0; }
inline int trick_side_value(int index) noexcept { return index == 1 ? -1 : index == 2 ? 1 : 0; }

// ---- Key aliases ----

// A saved key that was renamed: `legacy` is what old files and old profiles still say, `current` is
// the key in visit_fields / the choices. Add a row when a key is renamed; never remove one.
struct KeyAlias {
    const char* legacy;
    const char* current;
};
inline constexpr std::array<KeyAlias, 0> key_aliases{}; // no key has been renamed yet

// ---- Loading ----

struct LoadReport {
    int refused{};             // values that were of the wrong type or out of range (they keep their value)
    std::string first_refused; // the first such key
};

// Index of `text` in `names`, or -1.
template <std::size_t N> int index_of(const std::optional<std::string>& text, const std::array<const char*, N>& names) noexcept {
    if (!text) return -1;
    for (std::size_t i = 0; i < N; ++i)
        if (*text == names[i]) return static_cast<int>(i);
    return -1;
}

// Applies one saved value over a field when it has the right type and the group stays valid. `Source`
// is called as source(key) and returns the saved Json or nullopt.
template <class Source> struct Loader {
    explicit Loader(Source& from, std::span<const KeyAlias> renamed = key_aliases) : source(from), aliases(renamed) {}
    Source& source;
    std::span<const KeyAlias> aliases;
    int refused{};
    std::string first_refused;

    void refuse(const char* key) {
        if (!refused++) first_refused = key;
    }
    // The saved value of `key`, or else of a legacy key that was renamed to it; a throwing source
    // reads as "never saved".
    std::optional<Json> fetch(const char* key) const noexcept {
        try {
            auto value = source(key);
            if (value) return value;
            for (const auto& alias : aliases)
                if (std::string_view(alias.current) == key)
                    if (auto old = source(alias.legacy)) return old;
        } catch (...) {}
        return std::nullopt;
    }
    std::optional<std::string> text(const char* key) const noexcept {
        const auto value = fetch(key);
        if (value && value->is_string()) return value->string();
        return std::nullopt;
    }
    static std::optional<bool> parse(const Json& json, const bool*) {
        if (json.is_boolean()) return json.get<bool>();
        return std::nullopt;
    }
    static std::optional<float> parse(const Json& json, const float*) {
        if (!json.is_number()) return std::nullopt;
        const double number = json.get<double>();
        if (!std::isfinite(number) || std::fabs(number) > 1.0e9) return std::nullopt;
        return static_cast<float>(number);
    }
    template <class Group, class Value> void operator()(const char* key, Group& group, Value Group::* member) {
        const auto json = fetch(key);
        if (!json) return; // never saved: the current value stays
        const auto parsed = parse(*json, static_cast<const Value*>(nullptr));
        if (!parsed) { refuse(key); return; }
        const Value previous = group.*member;
        group.*member = *parsed;
        if (!group_ok(group)) { group.*member = previous; refuse(key); }
    }
};

// The choices (style, angle, shoulder, stance, trick-yaw side) and the FOV override.
template <class Source> void load_choices(Loader<Source>& loader, cfg::CameraSettings& camera) {
    if (const auto text = loader.text("S3Cam.Preset")) {
        const int found = index_of(text, preset_names);
        if (found >= 0) camera.preset = found == 1 ? cfg::CameraPreset::NativePlus : cfg::CameraPreset::FullS3;
        else loader.refuse("S3Cam.Preset");
    }
    if (const auto text = loader.text("S3Cam.Angle")) {
        const int found = index_of(text, angle_names);
        if (found >= 0) camera.angle = found == 1 ? cfg::CameraAngle::High : cfg::CameraAngle::Low;
        else loader.refuse("S3Cam.Angle");
    }
    if (const auto text = loader.text("S3Cam.Shoulder.Mode")) {
        const int found = index_of(text, shoulder_names);
        if (found >= 0)
            camera.shoulder.mode = found == 1 ? cfg::ShoulderSide::Manual : found == 2 ? cfg::ShoulderSide::Auto : cfg::ShoulderSide::Off;
        else loader.refuse("S3Cam.Shoulder.Mode");
    }
    if (const auto text = loader.text("S3Cam.Shoulder.Side")) {
        const int found = index_of(text, side_names);
        if (found >= 0) camera.shoulder.side = found == 1 ? 1 : -1;
        else loader.refuse("S3Cam.Shoulder.Side");
    }
    if (const auto text = loader.text("S3Cam.Shoulder.Stance")) {
        const int found = index_of(text, stance_names);
        if (found >= 0) camera.shoulder.goofy = found == 1;
        else loader.refuse("S3Cam.Shoulder.Stance");
    }
    if (const auto text = loader.text("S3Cam.TrickYaw.Side")) {
        const int found = index_of(text, trick_side_names);
        if (found >= 0) camera.trick_yaw.side = trick_side_value(found);
        else loader.refuse("S3Cam.TrickYaw.Side");
    }
    // 0 keeps the camera's own FOV; otherwise the range the console accepts.
    if (const auto json = loader.fetch("S3Cam.FovOverride")) {
        const auto degrees = Loader<Source>::parse(*json, static_cast<const float*>(nullptr));
        if (degrees && (*degrees == 0.0f || (*degrees >= 30.0f && *degrees <= 120.0f))) camera.fov_override_deg = *degrees;
        else loader.refuse("S3Cam.FovOverride");
    }
}

// Whole-struct safety net after the field-by-field pass: drops an offending group to its defaults.
// Field-wise acceptance keeps every group valid, so this only matters if the settings were not valid
// to begin with.
inline void drop_invalid_groups(cfg::CameraSettings& camera) noexcept {
    const auto fix = [](auto& group) { if (!group.valid()) group = {}; };
    fix(camera.look);
    fix(camera.shoulder);
    fix(camera.follow);
    fix(camera.fov);
    fix(camera.speed_shake);
    fix(camera.collision);
    fix(camera.native_plus);
    fix(camera.shake);
    fix(camera.framing);
    fix(camera.framing_high);
    fix(camera.trick_yaw);
    fix(camera.air_camera);
    fix(camera.landing_shake);
}

// Applies every value `source` has over `camera` and `options`. A field is accepted on its own; a
// field refused only because it needs a partner that comes later in the table (the speed FOV's
// minimum above the default maximum) gets a second pass, so a saved pair loads whole whichever
// order they come in.
template <class Source, class Options>
LoadReport load_values(Source& source, cfg::CameraSettings& camera, Options& options, std::span<const KeyAlias> aliases = key_aliases) {
    Loader<Source> first{source, aliases};
    visit_fields(camera, options, first);
    load_choices(first, camera);
    if (!first.refused) return {};
    Loader<Source> second{source, aliases};
    visit_fields(camera, options, second);
    load_choices(second, camera);
    return {second.refused, second.first_refused};
}

// ---- Saving ----

// The shortest text that reads back as the same float, as a double ("0.85" and not 0.8500000238...),
// so a file shows the number the player typed.
inline double tidy(float value) noexcept {
    std::array<char, 32> text{};
    const auto written = std::to_chars(text.data(), text.data() + text.size(), value);
    double result = static_cast<double>(value);
    if (written.ec == std::errc{}) {
        double parsed = 0.0;
        if (std::from_chars(text.data(), written.ptr, parsed).ec == std::errc{}) result = parsed;
    }
    return result;
}

using Values = std::vector<std::pair<std::string, Json>>;

// Every saved key and value, in the table's order.
template <class Options> Values collect_values(cfg::CameraSettings camera, Options options) {
    Values values;
    values.reserve(96);
    visit_fields(camera, options, [&values](const char* key, auto& group, auto member) {
        using Value = std::remove_cvref_t<decltype(group.*member)>;
        if constexpr (std::is_same_v<Value, float>) values.emplace_back(key, Json(tidy(group.*member)));
        else values.emplace_back(key, Json(group.*member));
    });
    values.emplace_back("S3Cam.Preset", Json(preset_names[camera.preset == cfg::CameraPreset::NativePlus ? std::size_t{1} : std::size_t{0}]));
    values.emplace_back("S3Cam.Angle", Json(angle_names[camera.angle == cfg::CameraAngle::High ? std::size_t{1} : std::size_t{0}]));
    values.emplace_back("S3Cam.FovOverride", Json(tidy(camera.fov_override_deg)));
    const int mode = camera.shoulder.mode == cfg::ShoulderSide::Manual ? 1 : camera.shoulder.mode == cfg::ShoulderSide::Auto ? 2 : 0;
    values.emplace_back("S3Cam.Shoulder.Mode", Json(shoulder_names[static_cast<std::size_t>(mode)]));
    values.emplace_back("S3Cam.Shoulder.Side", Json(side_names[camera.shoulder.side == 1 ? std::size_t{1} : std::size_t{0}]));
    values.emplace_back("S3Cam.Shoulder.Stance", Json(stance_names[camera.shoulder.goofy ? std::size_t{1} : std::size_t{0}]));
    values.emplace_back("S3Cam.TrickYaw.Side", Json(trick_side_names[static_cast<std::size_t>(trick_side_index(camera.trick_yaw.side))]));
    return values;
}

// ---- Names ----

namespace detail {
// One well-formed UTF-8 sequence at text[at]: its code point and length, or length 0 when malformed.
struct Sequence { char32_t code{}; std::size_t length{}; };
inline Sequence sequence_at(std::string_view text, std::size_t at) noexcept {
    const auto lead = static_cast<unsigned char>(text[at]);
    if (lead < 0x80) return {lead, 1};
    std::size_t length = 0;
    char32_t code = 0, least = 0;
    if (lead >= 0xC2 && lead <= 0xDF) { length = 2; code = lead & 0x1Fu; least = 0x80; }
    else if (lead >= 0xE0 && lead <= 0xEF) { length = 3; code = lead & 0x0Fu; least = 0x800; }
    else if (lead >= 0xF0 && lead <= 0xF4) { length = 4; code = lead & 0x07u; least = 0x10000; }
    else return {};
    if (at + length > text.size()) return {};
    for (std::size_t i = 1; i < length; ++i) {
        const auto next = static_cast<unsigned char>(text[at + i]);
        if ((next & 0xC0) != 0x80) return {};
        code = (code << 6) | (next & 0x3Fu);
    }
    if (code < least || code > 0x10FFFF || (code >= 0xD800 && code <= 0xDFFF)) return {};
    return {code, length};
}
// Characters a file name cannot carry on Windows, control characters, and the invisible marks that
// reorder or hide text (a name that reads as one thing and is another).
inline bool unfit(char32_t code) noexcept {
    if (code < 0x20 || code == 0x7F || (code >= 0x80 && code <= 0x9F)) return true;
    if (code < 0x80) {
        for (const char forbidden : std::string_view("\\/:*?\"<>|"))
            if (code == static_cast<char32_t>(static_cast<unsigned char>(forbidden))) return true;
        return false;
    }
    return (code >= 0x200B && code <= 0x200F) || (code >= 0x202A && code <= 0x202E) || (code >= 0x2066 && code <= 0x2069) ||
           code == 0xFEFF;
}
inline char lower_ascii(char c) noexcept { return c >= 'A' && c <= 'Z' ? static_cast<char>(c - 'A' + 'a') : c; }
// CON, PRN, AUX, NUL, COM1-9 and LPT1-9 name devices on Windows, with or without an extension.
inline bool device_name(std::string_view stem) noexcept {
    std::string lowered;
    for (const char c : stem) lowered += lower_ascii(c);
    while (!lowered.empty() && lowered.back() == ' ') lowered.pop_back();
    if (lowered == "con" || lowered == "prn" || lowered == "aux" || lowered == "nul") return true;
    return lowered.size() == 4 && (lowered.compare(0, 3, "com") == 0 || lowered.compare(0, 3, "lpt") == 0) && lowered[3] >= '1' &&
           lowered[3] <= '9';
}
} // namespace detail

// Number of characters (code points) in `text`.
inline std::size_t char_count(std::string_view text) noexcept {
    std::size_t count = 0;
    for (const char c : text)
        if ((static_cast<unsigned char>(c) & 0xC0) != 0x80) ++count;
    return count;
}

// A name that is safe as a file name stem: the characters \/:*?"<>| and control characters removed,
// malformed UTF-8 dropped, trimmed (leading spaces, trailing spaces and dots), at most 48 characters,
// and a device name such as "CON" given an underscore. Empty when nothing is left: the caller refuses.
inline std::string sanitize_name(std::string_view text) {
    std::string kept;
    std::size_t chars = 0;
    for (std::size_t at = 0; at < text.size() && chars < max_name_chars;) {
        const auto piece = detail::sequence_at(text, at);
        if (!piece.length) { ++at; continue; }
        if (!detail::unfit(piece.code) && !(kept.empty() && piece.code == U' ')) {
            kept.append(text.substr(at, piece.length));
            ++chars;
        }
        at += piece.length;
    }
    while (!kept.empty() && (kept.back() == ' ' || kept.back() == '.')) kept.pop_back();
    if (kept.empty()) return kept;
    if (detail::device_name(std::string_view(kept).substr(0, kept.find('.')))) kept += '_';
    return kept;
}

// `name` shortened to at most `limit` characters (never inside a multi-byte sequence).
inline std::string truncate_chars(std::string_view name, std::size_t limit) {
    std::size_t chars = 0, at = 0;
    for (; at < name.size(); ++at) {
        if ((static_cast<unsigned char>(name[at]) & 0xC0) != 0x80 && chars++ == limit) break;
    }
    return std::string(name.substr(0, at));
}

// Names compare without regard to ASCII case (Windows file names do; the glue also asks the file
// system, which knows the rest).
inline bool same_name(std::string_view a, std::string_view b) noexcept {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i)
        if (detail::lower_ascii(a[i]) != detail::lower_ascii(b[i])) return false;
    return true;
}

// `name` itself when nothing has it, else "name (2)", "name (3)", ... (the base is shortened so the
// whole stays within the limit). `taken(candidate)` says whether a name is in use.
inline std::string unique_name(std::string_view name, const std::function<bool(std::string_view)>& taken) {
    std::string base = sanitize_name(name);
    if (base.empty()) return base;
    if (!taken(base)) return base;
    for (int number = 2; number < 1000; ++number) {
        const std::string suffix = " (" + std::to_string(number) + ")";
        std::string candidate = sanitize_name(truncate_chars(base, max_name_chars - suffix.size()));
        candidate += suffix;
        if (!taken(candidate)) return candidate;
    }
    return {};
}

// ---- Built-in presets (code, not files; they cannot be deleted) ----

inline constexpr std::size_t builtin_count = 2;
inline const char* builtin_name(std::size_t index) noexcept {
    switch (index) {
    case 0: return "Skate 3";
    case 1: return "Close & low";
    default: return "";
    }
}
// The settings a built-in sets (everything else at the code defaults). Loading a built-in also puts
// the glue options (FOV override switch, R3 option, blend times, logging) back to their defaults, so
// "Skate 3" always means the plain defaults whatever was changed before; the glue does that.
inline cfg::CameraSettings builtin_settings(std::size_t index) {
    cfg::CameraSettings settings; // the code defaults
    switch (index) {
    case 0: break; // Skate 3: the code defaults as they are
    case 1: // Close & low. TUNE
        settings.angle = cfg::CameraAngle::Low;
        settings.framing.distance_scale = 0.85f;
        settings.framing.height_degrees = -3.0f;
        break;
    default: break;
    }
    return settings;
}
// The index of the built-in called `name`, or builtin_count.
inline std::size_t find_builtin(std::string_view name) noexcept {
    for (std::size_t i = 0; i < builtin_count; ++i)
        if (same_name(name, builtin_name(i))) return i;
    return builtin_count;
}

// ---- The preset JSON ----

template <class Options> struct ParsedPreset {
    std::string name;
    cfg::CameraSettings camera;
    Options options;
    LoadReport report;
    bool from_newer_version{}; // the file's version is above preset_version: its known keys were loaded, the rest ignored
};
enum class PresetError { none, not_json, not_preset, too_large };

// The preset as a JSON object (name, version, values).
template <class Options> Json preset_json(std::string_view name, const cfg::CameraSettings& camera, const Options& options) {
    Json values = Json::object();
    for (auto& entry : collect_values(camera, options)) values[entry.first] = std::move(entry.second);
    Json root = Json::object();
    root["name"] = std::string(name);
    root["version"] = preset_version;
    root["values"] = std::move(values);
    return root;
}
template <class Options> std::string preset_text(std::string_view name, const cfg::CameraSettings& camera, const Options& options) {
    return preset_json(name, camera, options).dump(2);
}

// Reads a preset over the code defaults (any version from 1 up; see the compatibility rules above).
// `aliases` is key_aliases; the parameter exists for tests. `name` comes back sanitised ("Imported preset" when the text
// carries none). On an error `out` is untouched.
template <class Options>
PresetError parse_preset(std::string_view text, ParsedPreset<Options>& out, std::span<const KeyAlias> aliases = key_aliases) noexcept {
    try {
        if (text.size() > max_preset_bytes) return PresetError::too_large;
        Json root;
        try {
            root = Json::parse(text, JsonLimits{max_preset_bytes, 16, 16384});
        } catch (...) { return PresetError::not_json; }
        if (!root.is_object() || !root.contains("values") || !root.at("values").is_object() || !root.contains("version") ||
            !root.at("version").is_number_integer())
            return PresetError::not_preset;
        const auto version = root.at("version").get<std::int64_t>();
        if (version < 1) return PresetError::not_preset;

        ParsedPreset<Options> parsed;
        parsed.from_newer_version = version > preset_version; // not refused: every key we know still loads
        if (root.contains("name") && root.at("name").is_string()) parsed.name = sanitize_name(root.at("name").string());
        if (parsed.name.empty()) parsed.name = "Imported preset";
        const Json& values = root.at("values");
        auto reader = [&values](const char* key) -> std::optional<Json> {
            if (!values.contains(key)) return std::nullopt;
            return values.at(key);
        };
        parsed.report = load_values(reader, parsed.camera, parsed.options, aliases);
        drop_invalid_groups(parsed.camera);
        if (!parsed.camera.valid()) parsed.camera = {};
        if (!group_ok(parsed.options)) parsed.options = {};
        out = std::move(parsed);
        return PresetError::none;
    } catch (...) { return PresetError::not_preset; }
}

} // namespace dingosdk::s3cam_format
