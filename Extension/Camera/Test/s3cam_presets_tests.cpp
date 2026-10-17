#include "Extension/Camera/s3cam_preset_format.h"

#include <array>
#include <cstdio>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

// The pure half of the S3Cam presets (Extension/Camera/s3cam_preset_format.h): the preset JSON round
// trip, per-field refusal, the file name sanitiser, name de-duplication and the built-in presets. No
// Windows, no files: the glue's S3CamOptions is mirrored by TestOptions.
namespace {
namespace sf = dingosdk::s3cam_format;
namespace cs = dingosdk::s3cam;
using dingosdk::Json;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}

// The same members as the glue's S3CamOptions (Extension/Camera/s3cam.h).
struct TestOptions {
    bool shot_fov = true;
    bool verbose = false;
    bool follow_game_height = true;
    float take_blend_time = 0.5f;
    float release_blend_time = 0.4f;
};
using Parsed = sf::ParsedPreset<TestOptions>;

// Every saved key and value, as a comparable list.
sf::Values saved_of(const cs::CameraSettings& camera, const TestOptions& options) { return sf::collect_values(camera, options); }

cs::CameraSettings tuned_camera() {
    cs::CameraSettings camera;
    camera.preset = cs::CameraPreset::NativePlus;
    camera.angle = cs::CameraAngle::High;
    camera.fov_override_deg = 72.5f;
    camera.shake_enabled = false;
    camera.framing = {0.85f, -3.5f, 4.25f, false, 0.6f, 7.0f};
    camera.trick_yaw.enabled = false;
    camera.trick_yaw.angle_degrees = 33.0f;
    camera.trick_yaw.side = -1;
    camera.trick_yaw.in_air = false;
    camera.trick_yaw.on_grinds = true;
    camera.trick_yaw.on_manuals = true;
    camera.trick_yaw.min_air_time = 0.35f;
    camera.trick_yaw.in_time = 0.8f;
    camera.trick_yaw.hold_time = 1.25f;
    camera.trick_yaw.return_time = 2.5f;
    camera.look.landing_look_strength = 0.3f;
    camera.look.response_time = 0.7f;
    camera.shoulder.mode = cs::ShoulderSide::Manual;
    camera.shoulder.side = -1;
    camera.shoulder.goofy = true;
    camera.shoulder.offset = 0.9f;
    camera.follow.strength = 1.7f;
    camera.fov.speed_fov_degrees = 9.5f;
    camera.fov.speed_fov_min = 20.0f; // above the default maximum: the pair has to load whole
    camera.fov.speed_fov_max = 30.0f;
    camera.speed_shake.strength = 2.5f;
    camera.collision.radius = 0.4f;
    camera.native_plus.dip_depth = 0.2f;
    camera.shake.one_shot_magnitude = 1.5f;
    camera.framing_high = {1.3f, 6.0f, -2.5f, false, 0.9f, -4.0f};
    camera.air_camera = {0.8f, 22.0f, 3.5f, 0.6f, false};
    camera.look.manual_focus = 0.1f;
    camera.look.grind_focus = 0.9f;
    camera.framing.grind_camera = false;
    camera.framing.grind_distance_scale = 1.4f;
    camera.framing.grind_height_degrees = 5.0f;
    camera.framing_high.grind_camera = true;
    camera.framing_high.grind_distance_scale = 0.7f;
    camera.framing_high.grind_height_degrees = -6.0f;
    camera.follow.horizontal = 6.5f;
    camera.landing_shake = {3.0f, 6.0f, 0.4f}; // min above the default full: the pair has to load whole
    camera.distance = {7.0f, 12.0f}; // min above the default maximum: the pair has to load whole
    camera.look.board_anchor = false;
    return camera;
}
TestOptions tuned_options() {
    TestOptions options;
    options.shot_fov = false;
    options.verbose = true;
    options.follow_game_height = false;
    options.take_blend_time = 1.25f;
    options.release_blend_time = 0.0f;
    return options;
}

Json parse_text(const std::string& text) { return Json::parse(text); }

void json_round_trip() {
    const auto camera = tuned_camera();
    const auto options = tuned_options();
    expect(camera.valid(), "the tuned test camera is valid");
    const auto text = sf::preset_text("Park cam", camera, options);

    Parsed parsed;
    expect(sf::parse_preset(text, parsed) == sf::PresetError::none, "a written preset reads back");
    expect(parsed.name == "Park cam", "the name survives");
    expect(parsed.report.refused == 0, "a written preset has nothing refused");
    expect(saved_of(parsed.camera, parsed.options) == saved_of(camera, options), "every saved field round-trips");
    expect(parsed.camera.valid(), "the loaded settings are valid");
    expect(parsed.camera.trick_yaw.side == -1 && parsed.camera.framing.manual_camera == false, "new fields round-trip");
    expect(parsed.camera.framing_high.distance_scale == 1.3f && parsed.camera.framing_high.height_degrees == 6.0f &&
           parsed.camera.framing_high.manual_camera == false && parsed.camera.framing.distance_scale == 0.85f,
           "the High camera position round-trips apart from the Low one");
    expect(parsed.camera.air_camera.follow_height == 0.8f && parsed.camera.air_camera.rise_degrees == 22.0f &&
           parsed.camera.air_camera.rise_full_height == 3.5f && parsed.camera.air_camera.ease_time == 0.6f &&
           !parsed.camera.air_camera.keep_in_frame, "the big-air camera round-trips");
    expect(parsed.camera.look.manual_focus == 0.1f && parsed.camera.look.grind_focus == 0.9f, "manual and grind focus round-trip");
    expect(!parsed.camera.framing.grind_camera && parsed.camera.framing.grind_distance_scale == 1.4f &&
           parsed.camera.framing.grind_height_degrees == 5.0f && parsed.camera.framing_high.grind_camera &&
           parsed.camera.framing_high.grind_distance_scale == 0.7f && parsed.camera.framing_high.grind_height_degrees == -6.0f,
           "the grind close-up round-trips per camera");
    expect(parsed.camera.follow.horizontal == 6.5f && parsed.camera.landing_shake.min_fall == 3.0f &&
           parsed.camera.landing_shake.full_fall == 6.0f && parsed.camera.landing_shake.speed_weight == 0.4f,
           "horizontal follow and the landing shake round-trip");
    expect(parsed.camera.fov.speed_fov_min == 20.0f && parsed.camera.fov.speed_fov_max == 30.0f, "a speed FOV pair above the default maximum loads whole");

    expect(parsed.camera.distance.min == 7.0f && parsed.camera.distance.max == 12.0f && !parsed.camera.look.board_anchor,
           "the distance limits (a pair above the default maximum) and board anchoring round-trip");

    const auto root = parse_text(text);
    expect(root.at("version").get<int>() == 1, "the file says version 1");
    expect(root.at("values").contains("S3Cam.Framing.DistanceScale") && root.at("values").contains("S3Cam.TrickYaw.Side"),
           "the new keys are in the file");
    expect(root.at("values").at("S3Cam.TrickYaw.Side").string() == "left", "the trick yaw side is written as text");
    expect(text.find("0.85") != std::string::npos && text.find("0.8500") == std::string::npos, "floats are written as the player typed them");
    expect(root.at("values").at("S3Cam.Framing.DistanceScale").get<double>() == 0.85, "0.85f is written as 0.85");

    // All three trick yaw sides, and every shoulder mode.
    for (const int side : {-1, 0, 1}) {
        auto changed = camera;
        changed.trick_yaw.side = side;
        Parsed again;
        expect(sf::parse_preset(sf::preset_text("x", changed, options), again) == sf::PresetError::none && again.camera.trick_yaw.side == side,
               "trick yaw side round-trips");
    }
    for (const auto mode : {cs::ShoulderSide::Off, cs::ShoulderSide::Manual, cs::ShoulderSide::Auto}) {
        auto changed = camera;
        changed.shoulder.mode = mode;
        Parsed again;
        expect(sf::parse_preset(sf::preset_text("x", changed, options), again) == sf::PresetError::none && again.camera.shoulder.mode == mode,
               "shoulder mode round-trips");
    }
}

void defaults_and_unknowns() {
    Parsed parsed;
    // Missing keys keep the defaults; unknown keys and extra top-level fields are ignored.
    const std::string text = R"({"name":"Tiny","version":1,"extra":[1,2],"values":{"S3Cam.Framing.DistanceScale":1.5,"S3Cam.Nonsense":3,"Other.Thing":"x"}})";
    expect(sf::parse_preset(text, parsed) == sf::PresetError::none, "a small preset reads");
    expect(parsed.camera.framing.distance_scale == 1.5f, "the key it has is applied");
    expect(parsed.camera.framing.height_degrees == 0.0f && parsed.camera.fov.speed_fov_degrees == 6.0f, "missing keys keep their defaults");
    expect(parsed.report.refused == 0, "unknown keys are not refused, just ignored");
    expect(parsed.options.take_blend_time == 0.5f, "missing options keep their defaults");
}

void refusal() {
    Parsed parsed;
    // One field out of range, one of the wrong type, one a non-finite stand-in: each refused alone.
    const std::string text = R"({"name":"Bad","version":1,"values":{
        "S3Cam.Framing.DistanceScale":10.0,
        "S3Cam.Framing.HeightDegrees":"high",
        "S3Cam.Framing.PitchDegrees":12.5,
        "S3Cam.TrickYaw.Side":"sideways",
        "S3Cam.TrickYaw.AngleDegrees":45,
        "S3Cam.Angle":"high",
        "S3Cam.FovOverride":10,
        "S3Cam.Options.TakeBlendTime":99.0,
        "S3Cam.Options.Logging":"yes"}})";
    expect(sf::parse_preset(text, parsed) == sf::PresetError::none, "a preset with bad values still reads");
    expect(parsed.camera.framing.distance_scale == 1.0f, "an out-of-range value keeps the default");
    expect(parsed.camera.framing.height_degrees == 0.0f, "a wrong-typed value keeps the default");
    expect(parsed.camera.framing.pitch_degrees == 12.5f, "a good neighbour still loads");
    expect(parsed.camera.trick_yaw.side == 0, "an unknown choice keeps the default");
    expect(parsed.camera.trick_yaw.angle_degrees == 45.0f, "an integer is a fine number");
    expect(parsed.camera.angle == cs::CameraAngle::High, "a good choice loads");
    expect(parsed.camera.fov_override_deg == 0.0f, "an FOV override outside 0 / 30-120 is refused");
    expect(parsed.options.take_blend_time == 0.5f, "an out-of-range blend time is refused");
    expect(!parsed.options.verbose, "a wrong-typed option is refused");
    expect(parsed.report.refused == 6, "six values were refused");
    expect(parsed.report.first_refused == "S3Cam.Framing.DistanceScale", "the first refused key is named");
    expect(parsed.camera.valid(), "the result is valid whatever was refused");

    // Interdependent range: a maximum below the minimum is refused, the minimum stays.
    Parsed pair;
    expect(sf::parse_preset(R"({"version":1,"values":{"S3Cam.Fov.SpeedFovMin":8,"S3Cam.Fov.SpeedFovMax":4}})", pair) == sf::PresetError::none,
           "a crossed pair reads");
    expect(pair.camera.fov.speed_fov_min == 8.0f && pair.camera.fov.speed_fov_max == 15.0f && pair.report.refused == 1,
           "a crossed pair refuses the second value only");
}

void not_presets() {
    Parsed parsed;
    parsed.name = "untouched";
    expect(sf::parse_preset("", parsed) == sf::PresetError::not_json, "empty text is not JSON");
    expect(sf::parse_preset("hello there", parsed) == sf::PresetError::not_json, "prose is not JSON");
    expect(sf::parse_preset("{\"name\": ", parsed) == sf::PresetError::not_json, "cut-off JSON is not JSON");
    expect(sf::parse_preset("[1,2,3]", parsed) == sf::PresetError::not_preset, "an array is not a preset");
    expect(sf::parse_preset(R"({"hello":"world"})", parsed) == sf::PresetError::not_preset, "other JSON is not a preset");
    expect(sf::parse_preset(R"({"version":1,"values":[]})", parsed) == sf::PresetError::not_preset, "values must be an object");
    expect(sf::parse_preset(R"({"values":{}})", parsed) == sf::PresetError::not_preset, "a version is required");
    expect(sf::parse_preset(R"({"version":"1","values":{}})", parsed) == sf::PresetError::not_preset, "the version is a number");
    expect(sf::parse_preset(R"({"version":0,"values":{}})", parsed) == sf::PresetError::not_preset, "version 0 does not exist");
    expect(sf::parse_preset(R"({"version":2,"values":{}})", parsed) == sf::PresetError::none && parsed.from_newer_version,
           "a newer version is loaded and flagged, not refused");
    expect(sf::parse_preset(R"({"version":1,"values":{}})", parsed) == sf::PresetError::none && !parsed.from_newer_version,
           "version 1 is not flagged");
    parsed.name = "untouched";
    expect(sf::parse_preset("[1,2,3]", parsed) == sf::PresetError::not_preset && parsed.name == "untouched",
           "a failed parse leaves the output alone");
    expect(sf::parse_preset(std::string(sf::max_preset_bytes + 1, ' '), parsed) == sf::PresetError::too_large, "a huge text is refused");
    expect(sf::parse_preset(R"({"version":1,"values":{}})", parsed) == sf::PresetError::none && parsed.name == "Imported preset",
           "a preset without a name is called Imported preset");
    expect(sf::parse_preset(R"({"name":"a/b:c*","version":1,"values":{}})", parsed) == sf::PresetError::none && parsed.name == "abc",
           "the name from the JSON is sanitised");
    expect(sf::parse_preset(R"({"name":"???","version":1,"values":{}})", parsed) == sf::PresetError::none && parsed.name == "Imported preset",
           "a name that sanitises to nothing falls back");
}

void names() {
    expect(sf::sanitize_name("Park cam") == "Park cam", "a plain name is kept");
    expect(sf::sanitize_name("  Park cam  ") == "Park cam", "spaces are trimmed");
    expect(sf::sanitize_name("a\\b/c:d*e?f\"g<h>i|j") == "abcdefghij", "the forbidden characters are stripped");
    expect(sf::sanitize_name("tab\there\nnew\x01line\x7f") == "tabherenewline", "control characters are stripped");
    expect(sf::sanitize_name("name. . .") == "name", "trailing dots and spaces are trimmed");
    expect(sf::sanitize_name("...") == "", "dots alone leave nothing");
    expect(sf::sanitize_name("") == "" && sf::sanitize_name(" \t ") == "" && sf::sanitize_name("***") == "", "empty stays empty");
    expect(sf::sanitize_name(std::string(100, 'a')) == std::string(48, 'a'), "at most 48 characters");
    expect(sf::sanitize_name(std::string(47, 'a') + "***bcd") == std::string(47, 'a') + "b", "stripped characters do not count toward the 48");
    // Multi-byte text counts by character and is never cut in half.
    std::string accents;
    for (int i = 0; i < 60; ++i) accents += "\xC3\xA9"; // e acute
    const auto cut = sf::sanitize_name(accents);
    expect(cut.size() == 96 && sf::char_count(cut) == 48, "48 two-byte characters are kept whole");
    expect(sf::sanitize_name("caf\xC3\xA9") == "caf\xC3\xA9", "UTF-8 survives");
    expect(sf::sanitize_name("bad\xFF" "byte\xC3") == "badbyte", "malformed UTF-8 is dropped");
    expect(sf::sanitize_name("evil\xE2\x80\xAEname") == "evilname", "bidi override characters are stripped");
    expect(sf::sanitize_name("CON") == "CON_" && sf::sanitize_name("nul") == "nul_" && sf::sanitize_name("Com1") == "Com1_" &&
           sf::sanitize_name("LPT9.txt") == "LPT9.txt_", "device names get an underscore");
    expect(sf::sanitize_name("Console") == "Console" && sf::sanitize_name("COM10") == "COM10" && sf::sanitize_name("COM0") == "COM0",
           "names that only start like a device name are fine");
    expect(sf::same_name("Park Cam", "park cam") && !sf::same_name("Park", "Park "), "names compare without ASCII case");

    const auto taken_set = [](const std::vector<std::string>& names_taken) {
        return [names_taken](std::string_view candidate) {
            for (const auto& entry : names_taken)
                if (sf::same_name(entry, candidate)) return true;
            return false;
        };
    };
    expect(sf::unique_name("Park cam", taken_set({})) == "Park cam", "a free name is kept");
    expect(sf::unique_name("Park cam", taken_set({"park cam"})) == "Park cam (2)", "a taken name gets (2)");
    expect(sf::unique_name("Park cam", taken_set({"Park cam", "Park cam (2)", "Park cam (3)"})) == "Park cam (4)", "and the next free number");
    const auto long_name = std::string(48, 'z');
    const auto shortened = sf::unique_name(long_name, taken_set({long_name}));
    expect(shortened == std::string(44, 'z') + " (2)" && sf::char_count(shortened) <= 48, "a long name is shortened to fit the suffix");
    expect(sf::unique_name("???", taken_set({})).empty(), "an unusable name stays empty");
}

void builtins() {
    expect(sf::builtin_count == 2, "two built-in presets");
    const std::vector<std::string> expected{"Skate 3", "Close & low"};
    for (std::size_t i = 0; i < sf::builtin_count; ++i) {
        expect(sf::builtin_name(i) == expected[i], "built-in name");
        const auto settings = sf::builtin_settings(i);
        expect(settings.valid(), "every built-in is valid");
        expect(sf::sanitize_name(sf::builtin_name(i)) == expected[i], "every built-in name is a valid file name");
        expect(sf::find_builtin(sf::builtin_name(i)) == i, "a built-in is found by name");
        Parsed again;
        expect(sf::parse_preset(sf::preset_text(sf::builtin_name(i), settings, TestOptions{}), again) == sf::PresetError::none &&
               saved_of(again.camera, again.options) == saved_of(settings, TestOptions{}), "a built-in exports and imports unchanged");
    }
    expect(sf::find_builtin("SKATE 3") == 0 && sf::find_builtin("Nothing") == sf::builtin_count &&
           sf::find_builtin("Native+ light") == sf::builtin_count && sf::find_builtin("Skate 3 (default)") == sf::builtin_count,
           "built-in lookup ignores case and the old names are gone");
    expect(saved_of(sf::builtin_settings(0), TestOptions{}) == saved_of(cs::CameraSettings{}, TestOptions{}), "Skate 3 is the code defaults");
    const auto close = sf::builtin_settings(1);
    expect(close.framing.distance_scale == 0.85f && close.framing.height_degrees == -3.0f && close.angle == cs::CameraAngle::Low &&
           close.preset == cs::CameraPreset::FullS3, "Close & low");
}

// An old version 1 preset, written before the High camera, the big-air camera and the focus keys.
void old_preset_keeps_new_defaults() {
    Parsed parsed;
    const std::string text = R"({"name":"Old","version":1,"values":{
        "S3Cam.Framing.DistanceScale":0.9,"S3Cam.Framing.HeightDegrees":2.0,"S3Cam.Angle":"high",
        "S3Cam.Look.LandingLook":false,"S3Cam.Options.Logging":true}})";
    expect(sf::parse_preset(text, parsed) == sf::PresetError::none && !parsed.from_newer_version, "an old v1 preset reads");
    expect(parsed.report.refused == 0, "nothing refused");
    expect(parsed.camera.framing.distance_scale == 0.9f && parsed.camera.angle == cs::CameraAngle::High && !parsed.camera.look.landing_look &&
           parsed.options.verbose, "its keys load");
    const cs::CameraSettings defaults;
    expect(parsed.camera.framing_high.distance_scale == defaults.framing_high.distance_scale &&
           parsed.camera.framing_high.height_degrees == defaults.framing_high.height_degrees,
           "the High camera position stays at its defaults, not copied from the old Low one");
    expect(parsed.camera.air_camera.follow_height == defaults.air_camera.follow_height &&
           parsed.camera.air_camera.rise_degrees == defaults.air_camera.rise_degrees &&
           parsed.camera.air_camera.keep_in_frame == defaults.air_camera.keep_in_frame, "the big-air camera stays at its defaults");
    expect(parsed.camera.look.manual_focus == defaults.look.manual_focus && parsed.camera.look.grind_focus == defaults.look.grind_focus,
           "manual and grind focus stay at their defaults");
}

// An old preset has no distance or board-anchor keys, and may carry the retired
// S3Cam.Collision.MinDistance. That key loads without a refusal, changes nothing (no alias), and is not saved again.
void distance_and_anchor_keys() {
    const cs::CameraSettings defaults;
    {
        Parsed parsed;
        const std::string text = R"({"name":"Old","version":1,"values":{"S3Cam.Collision.Radius":0.4,
            "S3Cam.Collision.MinDistance":0.1,"S3Cam.Framing.DistanceScale":0.9}})";
        expect(sf::parse_preset(text, parsed) == sf::PresetError::none && parsed.report.refused == 0, "an old preset with MinDistance loads without errors");
        expect(parsed.camera.collision.radius == 0.4f && parsed.camera.framing.distance_scale == 0.9f, "its other keys apply");
        expect(parsed.camera.distance.min == defaults.distance.min && parsed.camera.distance.max == defaults.distance.max &&
               parsed.camera.look.board_anchor == defaults.look.board_anchor, "the new settings keep their defaults (no alias)");
        expect(parsed.camera.collision.min_distance == defaults.collision.min_distance, "the unused collision field stays at its default");
        expect(parsed.camera.valid(), "the result is valid");
    }
    {
        Parsed parsed;
        const std::string text = R"({"name":"New","version":1,"values":{"S3Cam.Distance.Min":2.0,"S3Cam.Distance.Max":9.5,
            "S3Cam.Look.BoardAnchor":false}})";
        expect(sf::parse_preset(text, parsed) == sf::PresetError::none && parsed.report.refused == 0, "the new keys load");
        expect(parsed.camera.distance.min == 2.0f && parsed.camera.distance.max == 9.5f && !parsed.camera.look.board_anchor, "with their values");
    }
    {
        // A pair that breaks max >= min + 0.2 is refused on its own; the other half and the rest still load.
        Parsed parsed;
        const std::string text = R"({"name":"Bad","version":1,"values":{"S3Cam.Distance.Min":8.0,"S3Cam.Distance.Max":1.0,
            "S3Cam.Look.BoardAnchor":false}})";
        expect(sf::parse_preset(text, parsed) == sf::PresetError::none && parsed.report.refused >= 1, "a bad distance pair is refused");
        expect(parsed.camera.valid() && parsed.camera.distance.valid() && !parsed.camera.look.board_anchor, "the result stays valid and the rest loads");
    }
    {
        const auto text = sf::preset_text("Saved", defaults, TestOptions{});
        expect(text.find("S3Cam.Collision.MinDistance") == std::string::npos, "MinDistance is no longer saved");
        expect(text.find("S3Cam.Distance.Min") != std::string::npos && text.find("S3Cam.Distance.Max") != std::string::npos &&
               text.find("S3Cam.Look.BoardAnchor") != std::string::npos, "the new keys are saved");
    }
}

// A preset from a later version: unknown keys, an unknown top-level field and a changed unknown value type.
// A preset from before the grind and landing-shake options has no grind, horizontal follow or landing shake keys: they keep their defaults.
void older_preset_loads() {
    const std::string text = R"({"name":"Old","version":1,"values":{"S3Cam.Framing.ManualDistanceScale":0.5,
        "S3Cam.FramingHigh.ManualHeightDegrees":4.0,"S3Cam.Follow.Strength":1.5}})";
    Parsed parsed;
    expect(sf::parse_preset(text, parsed) == sf::PresetError::none && parsed.report.refused == 0, "an old preset loads");
    const cs::CameraSettings defaults;
    expect(parsed.camera.framing.manual_distance_scale == 0.5f && parsed.camera.framing_high.manual_height_degrees == 4.0f &&
           parsed.camera.follow.strength == 1.5f, "its keys apply");
    expect(parsed.camera.framing.grind_camera == defaults.framing.grind_camera &&
           parsed.camera.framing.grind_distance_scale == defaults.framing.grind_distance_scale &&
           parsed.camera.framing_high.grind_height_degrees == defaults.framing_high.grind_height_degrees &&
           parsed.camera.follow.horizontal == defaults.follow.horizontal &&
           parsed.camera.landing_shake.min_fall == defaults.landing_shake.min_fall &&
           parsed.camera.landing_shake.full_fall == defaults.landing_shake.full_fall &&
           parsed.camera.landing_shake.speed_weight == defaults.landing_shake.speed_weight,
           "the new fields keep their defaults");
    expect(parsed.camera.valid(), "the result is valid");
}

void newer_preset_loads_known_keys() {
    Parsed parsed;
    const std::string text = R"({"name":"Future","version":2,"future_field":{"a":1},"values":{
        "S3Cam.Framing.DistanceScale":1.25,"S3Cam.Next.Thing":[1,2,3],"S3Cam.AirCamera.RiseDegrees":30,
        "S3Cam.Framing.PitchDegrees":99.0,"S3Cam.Look.GrindFocus":0.2}})";
    expect(sf::parse_preset(text, parsed) == sf::PresetError::none, "a version 2 preset reads");
    expect(parsed.from_newer_version, "and is flagged as newer");
    expect(parsed.name == "Future", "its name survives");
    expect(parsed.camera.framing.distance_scale == 1.25f && parsed.camera.air_camera.rise_degrees == 30.0f &&
           parsed.camera.look.grind_focus == 0.2f, "the known keys load");
    expect(parsed.camera.framing.pitch_degrees == 0.0f && parsed.report.refused == 1, "a known key out of range is still refused alone");
    expect(parsed.camera.valid(), "the result is valid");
}

// The profile loader and the preset import share Loader, so one alias table serves both.
void aliases() {
    constexpr std::array<sf::KeyAlias, 2> table{{{"S3Cam.Framing.Distance", "S3Cam.Framing.DistanceScale"},
                                                  {"S3Cam.Old.Angle", "S3Cam.Angle"}}};
    Parsed parsed;
    const std::string text = R"({"version":1,"values":{"S3Cam.Framing.Distance":1.4,"S3Cam.Old.Angle":"high"}})";
    expect(sf::parse_preset(text, parsed, table) == sf::PresetError::none, "a preset with renamed keys reads");
    expect(parsed.camera.framing.distance_scale == 1.4f, "a number under its old key maps to the new field");
    expect(parsed.camera.angle == cs::CameraAngle::High, "a text choice under its old key maps too");
    expect(parsed.report.refused == 0, "an alias is not a refusal");

    Parsed both;
    const std::string winner = R"({"version":1,"values":{"S3Cam.Framing.Distance":1.4,"S3Cam.Framing.DistanceScale":0.7}})";
    expect(sf::parse_preset(winner, both, table) == sf::PresetError::none && both.camera.framing.distance_scale == 0.7f,
           "the current key wins over its old spelling");

    Parsed none;
    expect(sf::parse_preset(text, none) == sf::PresetError::none && none.camera.framing.distance_scale == 1.0f &&
           none.camera.angle == cs::CameraAngle::Low, "without the alias the old keys are just unknown");

    // A profile-style source (a callable on the key) goes through the same loader.
    cs::CameraSettings camera;
    TestOptions options;
    auto profile = [](const char* key) -> std::optional<Json> {
        if (std::string_view(key) == "S3Cam.Framing.Distance") return Json(1.1);
        return std::nullopt;
    };
    const auto report = sf::load_values(profile, camera, options, table);
    expect(report.refused == 0 && camera.framing.distance_scale == 1.1f, "the profile loader maps old keys too");
    expect(sf::key_aliases.size() == 0 || sf::key_aliases[0].legacy != nullptr, "the shipped table is well formed");
}

void field_table() {
    // Every key is unique, and the keys follow S3Cam.<Group>.<Field>.
    const auto values = saved_of(cs::CameraSettings{}, TestOptions{});
    for (std::size_t i = 0; i < values.size(); ++i) {
        expect(values[i].first.rfind("S3Cam.", 0) == 0, "every key starts with S3Cam.");
        for (std::size_t j = i + 1; j < values.size(); ++j)
            if (values[i].first == values[j].first) expect(false, "duplicate key " + values[i].first);
    }
    int framing = 0, yaw = 0;
    for (const auto& entry : values) {
        framing += entry.first.rfind("S3Cam.Framing.", 0) == 0;
        yaw += entry.first.rfind("S3Cam.TrickYaw.", 0) == 0;
    }
    expect(framing == 9, "nine framing keys");
    expect(yaw == 10, "ten trick yaw keys");
    int high = 0, air = 0;
    for (const auto& entry : values) {
        high += entry.first.rfind("S3Cam.FramingHigh.", 0) == 0;
        air += entry.first.rfind("S3Cam.AirCamera.", 0) == 0;
    }
    expect(high == 9 && air == 5, "nine High framing keys and five big-air keys");
    for (const auto& alias : sf::key_aliases) {
        bool found = false;
        for (const auto& entry : values) found = found || entry.first == alias.current;
        expect(found, "every alias points at a saved key");
    }
    int landing = 0, follow = 0;
    for (const auto& entry : values) {
        landing += entry.first.rfind("S3Cam.LandingShake.", 0) == 0;
        follow += entry.first == "S3Cam.Follow.Horizontal";
    }
    expect(landing == 3 && follow == 1, "three landing shake keys and the horizontal follow key");
    expect(values.size() == 94, "94 saved keys in all");
}
} // namespace

int main() {
    json_round_trip();
    defaults_and_unknowns();
    refusal();
    not_presets();
    names();
    builtins();
    old_preset_keeps_new_defaults();
    older_preset_loads();
    distance_and_anchor_keys();
    newer_preset_loads_known_keys();
    aliases();
    field_table();
    if (failures) {
        std::printf("%d failure(s)\n", failures);
        return 1;
    }
    std::puts("s3cam_presets_tests: all passed");
    return 0;
}
