#include "s3cam_config.h"
#include "s3cam.h"
#include "Engine/Core/Json/json.h"
#include "Engine/Core/Log/logging.h"
#include "Extension/Profile/local_profile_runtime.h"
#include <cmath>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace dingosdk::client_source::detail {
namespace {
using logging::Channel;
using logging::Level;
namespace cfgcam = dingosdk::s3cam;

// A negative time or a runaway blend would stall the crossfade; the same bound the console and the
// page use.
bool values_ok(const S3CamOptions& options) noexcept {
    const auto time_ok = [](float seconds) { return std::isfinite(seconds) && seconds >= 0.0f && seconds <= 5.0f; };
    return time_ok(options.take_blend_time) && time_ok(options.release_blend_time);
}
template <class Group> bool values_ok(const Group& group) noexcept { return group.valid(); }

// Every saved numeric / boolean field once, so loading and saving cannot drift apart. `visit` is
// called as visit(key, group, &Group::member).
template <class Visit>
void visit_fields(cfgcam::CameraSettings& camera, S3CamOptions& options, Visit&& visit) {
    visit("S3Cam.ShakeEnabled", camera, &cfgcam::CameraSettings::shake_enabled);

    visit("S3Cam.Look.LandingLook", camera.look, &cfgcam::LookSettings::landing_look);
    visit("S3Cam.Look.LandingLookStrength", camera.look, &cfgcam::LookSettings::landing_look_strength);
    visit("S3Cam.Look.LandingLookFullDrop", camera.look, &cfgcam::LookSettings::landing_look_full_drop);
    visit("S3Cam.Look.SlopeLook", camera.look, &cfgcam::LookSettings::slope_look);
    visit("S3Cam.Look.SlopeLookStrength", camera.look, &cfgcam::LookSettings::slope_look_strength);
    visit("S3Cam.Look.VerticalFollow", camera.look, &cfgcam::LookSettings::vertical_follow);
    visit("S3Cam.Look.ResponseTime", camera.look, &cfgcam::LookSettings::response_time);

    visit("S3Cam.Shoulder.Offset", camera.shoulder, &cfgcam::ShoulderSettings::offset);
    visit("S3Cam.Shoulder.SwitchTime", camera.shoulder, &cfgcam::ShoulderSettings::switch_time);

    visit("S3Cam.Follow.Strength", camera.follow, &cfgcam::FollowSettings::strength);
    visit("S3Cam.Follow.Dynamic", camera.follow, &cfgcam::FollowSettings::dynamic);
    visit("S3Cam.Follow.DynamicSpeed", camera.follow, &cfgcam::FollowSettings::dynamic_speed);
    visit("S3Cam.Follow.DynamicBoost", camera.follow, &cfgcam::FollowSettings::dynamic_boost);

    visit("S3Cam.Fov.ShotLens", camera.fov, &cfgcam::FovSettings::shot_fov);
    visit("S3Cam.Fov.SpeedFov", camera.fov, &cfgcam::FovSettings::speed_fov);
    visit("S3Cam.Fov.SpeedFovDegrees", camera.fov, &cfgcam::FovSettings::speed_fov_degrees);
    visit("S3Cam.Fov.SpeedFovMin", camera.fov, &cfgcam::FovSettings::speed_fov_min);
    visit("S3Cam.Fov.SpeedFovMax", camera.fov, &cfgcam::FovSettings::speed_fov_max);
    visit("S3Cam.Fov.AirFov", camera.fov, &cfgcam::FovSettings::air_fov);
    visit("S3Cam.Fov.AirFovDegrees", camera.fov, &cfgcam::FovSettings::air_fov_degrees);
    visit("S3Cam.Fov.AirFovFullHeight", camera.fov, &cfgcam::FovSettings::air_fov_full_height);
    visit("S3Cam.Fov.SmoothingTime", camera.fov, &cfgcam::FovSettings::smoothing_time);

    visit("S3Cam.Shake.LandingStrength", camera.shake, &cfgcam::ShakeSettings::one_shot_magnitude);
    visit("S3Cam.SpeedShake.Enabled", camera.speed_shake, &cfgcam::SpeedShakeSettings::enabled);
    visit("S3Cam.SpeedShake.Strength", camera.speed_shake, &cfgcam::SpeedShakeSettings::strength);
    visit("S3Cam.SpeedShake.TopSpeed", camera.speed_shake, &cfgcam::SpeedShakeSettings::top_speed);
    visit("S3Cam.SpeedShake.DownhillBoost", camera.speed_shake, &cfgcam::SpeedShakeSettings::downhill_boost);
    visit("S3Cam.SpeedShake.DownhillScale", camera.speed_shake, &cfgcam::SpeedShakeSettings::downhill_scale);
    visit("S3Cam.SpeedShake.DownhillFullDegrees", camera.speed_shake, &cfgcam::SpeedShakeSettings::downhill_full_degrees);

    visit("S3Cam.Collision.Enabled", camera.collision, &cfgcam::CollisionSettings::enabled);
    visit("S3Cam.Collision.Radius", camera.collision, &cfgcam::CollisionSettings::radius);
    visit("S3Cam.Collision.MinDistance", camera.collision, &cfgcam::CollisionSettings::min_distance);
    visit("S3Cam.Collision.PullInTime", camera.collision, &cfgcam::CollisionSettings::pull_in_time);
    visit("S3Cam.Collision.ReleaseTime", camera.collision, &cfgcam::CollisionSettings::release_time);
    visit("S3Cam.Collision.GroundClearance", camera.collision, &cfgcam::CollisionSettings::ground_clearance);

    visit("S3Cam.NativePlus.AirHold", camera.native_plus, &cfgcam::NativePlusSettings::air_hold);
    visit("S3Cam.NativePlus.LandingDip", camera.native_plus, &cfgcam::NativePlusSettings::landing_dip);
    visit("S3Cam.NativePlus.Shake", camera.native_plus, &cfgcam::NativePlusSettings::shake);
    visit("S3Cam.NativePlus.Roll", camera.native_plus, &cfgcam::NativePlusSettings::roll);
    visit("S3Cam.NativePlus.DipDepth", camera.native_plus, &cfgcam::NativePlusSettings::dip_depth);
    visit("S3Cam.NativePlus.DipPeakTime", camera.native_plus, &cfgcam::NativePlusSettings::dip_peak_time);

    visit("S3Cam.Options.ShotFov", options, &S3CamOptions::shot_fov);
    visit("S3Cam.Options.Logging", options, &S3CamOptions::verbose);
    visit("S3Cam.Options.FollowGameHeight", options, &S3CamOptions::follow_game_height);
    visit("S3Cam.Options.TakeBlendTime", options, &S3CamOptions::take_blend_time);
    visit("S3Cam.Options.ReleaseBlendTime", options, &S3CamOptions::release_blend_time);
}

// ---- Text choices (their names are part of the saved file; keep them stable) ----
constexpr const char* preset_names[] = {"full", "native"};
constexpr const char* angle_names[] = {"low", "high"};
constexpr const char* shoulder_names[] = {"off", "manual", "auto"};
constexpr const char* side_names[] = {"left", "right"}; // the side the camera sits on, as ShoulderSettings::side
constexpr const char* stance_names[] = {"regular", "goofy"};

std::optional<std::string> text_of(const char* key) noexcept {
    try {
        const auto value = profile_runtime::local_value(key);
        if (value && value->is_string()) return value->string();
    } catch (...) {}
    return std::nullopt;
}

// Index of `text` in `names`, or -1.
template <std::size_t N> int index_of(const std::optional<std::string>& text, const char* const (&names)[N]) noexcept {
    if (!text) return -1;
    for (std::size_t i = 0; i < N; ++i)
        if (*text == names[i]) return static_cast<int>(i);
    return -1;
}

// Applies one saved value over a field when it has the right type and the group stays valid.
struct Loader {
    int refused{};
    std::string first_refused;

    void refuse(const char* key) {
        if (!refused++) first_refused = key;
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
        std::optional<Json> json;
        try { json = profile_runtime::local_value(key); } catch (...) {}
        if (!json) return; // never saved: the current value stays
        const auto parsed = parse(*json, static_cast<const Value*>(nullptr));
        if (!parsed) { refuse(key); return; }
        const Value previous = group.*member;
        group.*member = *parsed;
        if (!values_ok(group)) { group.*member = previous; refuse(key); }
    }
};

struct Saver {
    std::vector<std::pair<std::string, Json>>& values;
    template <class Group, class Value> void operator()(const char* key, Group& group, Value Group::* member) {
        values.emplace_back(key, Json(group.*member));
    }
};

// Whole-struct safety net after the field-by-field pass: drops an offending group to its defaults.
// Field-wise acceptance keeps every group valid, so this only matters if the current settings were
// not valid to begin with.
void drop_invalid_groups(cfgcam::CameraSettings& camera) noexcept {
    const auto fix = [](auto& group) { if (!group.valid()) group = {}; };
    fix(camera.look);
    fix(camera.shoulder);
    fix(camera.follow);
    fix(camera.fov);
    fix(camera.speed_shake);
    fix(camera.collision);
    fix(camera.native_plus);
    fix(camera.shake);
}
} // namespace

void s3cam_config_load() noexcept {
    try {
        auto camera = s3cam_settings();
        auto options = s3cam_options();
        Loader loader;
        visit_fields(camera, options, loader);

        // The text choices.
        if (const auto text = text_of("S3Cam.Preset")) {
            const int found = index_of(text, preset_names);
            if (found >= 0) camera.preset = found == 1 ? cfgcam::CameraPreset::NativePlus : cfgcam::CameraPreset::FullS3;
            else loader.refuse("S3Cam.Preset");
        }
        if (const auto text = text_of("S3Cam.Angle")) {
            const int found = index_of(text, angle_names);
            if (found >= 0) camera.angle = found == 1 ? cfgcam::CameraAngle::High : cfgcam::CameraAngle::Low;
            else loader.refuse("S3Cam.Angle");
        }
        if (const auto text = text_of("S3Cam.Shoulder.Mode")) {
            const int found = index_of(text, shoulder_names);
            if (found >= 0)
                camera.shoulder.mode = found == 1 ? cfgcam::ShoulderSide::Manual
                                     : found == 2 ? cfgcam::ShoulderSide::Auto : cfgcam::ShoulderSide::Off;
            else loader.refuse("S3Cam.Shoulder.Mode");
        }
        if (const auto text = text_of("S3Cam.Shoulder.Side")) {
            const int found = index_of(text, side_names);
            if (found >= 0) camera.shoulder.side = found == 1 ? 1 : -1;
            else loader.refuse("S3Cam.Shoulder.Side");
        }
        if (const auto text = text_of("S3Cam.Shoulder.Stance")) {
            const int found = index_of(text, stance_names);
            if (found >= 0) camera.shoulder.goofy = found == 1;
            else loader.refuse("S3Cam.Shoulder.Stance");
        }
        // 0 keeps the camera's own FOV; otherwise the range the console accepts.
        try {
            if (const auto json = profile_runtime::local_value("S3Cam.FovOverride")) {
                const auto degrees = Loader::parse(*json, static_cast<const float*>(nullptr));
                if (degrees && (*degrees == 0.0f || (*degrees >= 30.0f && *degrees <= 120.0f))) camera.fov_override_deg = *degrees;
                else loader.refuse("S3Cam.FovOverride");
            }
        } catch (...) {}

        drop_invalid_groups(camera);
        if (!s3cam_set_settings(camera)) {
            logging::log(Level::warning, Channel::skater, "s3cam: the saved settings are not valid together; keeping the defaults.");
            return;
        }
        s3cam_set_options(options);
        if (loader.refused)
            logging::log(Level::warning, Channel::skater,
                "s3cam: {} saved value(s) were out of range or of the wrong type and keep their defaults (first: {}).",
                loader.refused, loader.first_refused);
    } catch (...) { /* Unreadable choices leave the current values in place. */ }
}

void s3cam_config_save() noexcept {
    try {
        auto camera = s3cam_settings();
        auto options = s3cam_options();
        std::vector<std::pair<std::string, Json>> values;
        values.reserve(64);
        Saver saver{values};
        visit_fields(camera, options, saver);
        values.emplace_back("S3Cam.Preset", Json(preset_names[camera.preset == cfgcam::CameraPreset::NativePlus ? 1 : 0]));
        values.emplace_back("S3Cam.Angle", Json(angle_names[camera.angle == cfgcam::CameraAngle::High ? 1 : 0]));
        values.emplace_back("S3Cam.FovOverride", Json(camera.fov_override_deg));
        const int mode = camera.shoulder.mode == cfgcam::ShoulderSide::Manual ? 1
                       : camera.shoulder.mode == cfgcam::ShoulderSide::Auto ? 2 : 0;
        values.emplace_back("S3Cam.Shoulder.Mode", Json(shoulder_names[mode]));
        values.emplace_back("S3Cam.Shoulder.Side", Json(side_names[camera.shoulder.side == 1 ? 1 : 0]));
        values.emplace_back("S3Cam.Shoulder.Stance", Json(stance_names[camera.shoulder.goofy ? 1 : 0]));
        profile_runtime::set_local_values(values);
    } catch (...) { /* Saving is best effort; the choices already apply. */ }
}

void s3cam_config_reset() noexcept {
    (void)s3cam_set_settings(cfgcam::CameraSettings{});
    s3cam_set_options(S3CamOptions{});
}
}
