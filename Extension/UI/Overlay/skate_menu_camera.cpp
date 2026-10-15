#include "skate_menu_internal.h"
#include "Extension/Camera/s3cam.h"
#include "Extension/Camera/s3cam_config.h"

#include <algorithm>
#include <cmath>

// The S3 CAMERA page: S3Cam's on/off switch and every tunable, live. The overlay is a static library
// linked into the runtime DLL, so the page calls the runtime's thread-safe s3cam_settings() /
// s3cam_set_settings() / s3cam_options() directly, as the Music page calls music_inject. The settings
// are read afresh each frame; a change builds a new copy and hands it to s3cam_set_settings(), which
// refuses an out-of-range one and so keeps the old value (the page then shows the old value again).
// Saving happens elsewhere (Extension/Camera/s3cam_config.h).
namespace dingosdk::overlay::menu {
namespace {
namespace glue = dingosdk::client_source::detail;

// One frame's draft of the settings and options, applied once at the end of the page.
struct Draft {
    Draft(SkateMenu& owner, const dingosdk::s3cam::CameraSettings& current, const glue::S3CamOptions& current_options)
        : menu(owner), next(current), chosen(current_options) {}
    SkateMenu& menu;
    dingosdk::s3cam::CameraSettings next;
    glue::S3CamOptions chosen;
    bool next_changed{}, chosen_changed{};
};

// Pairs of `dirty` below: Draft::next_changed for a camera setting, Draft::chosen_changed for an option.
void toggle(Draft& draft, bool& dirty, const char* label, const char* hint, bool& value, bool enabled = true) {
    if (toggle_row(draft.menu, label, hint, value, enabled)) dirty = true;
}

void slider(Draft& draft, bool& dirty, const char* label, const char* tooltip, float& value, float low, float high,
            const char* format) {
    field(draft.menu, label, tooltip);
    ImGui::PushID(label);
    // A wide positive range reads better on a log scale.
    const ImGuiSliderFlags flags = ImGuiSliderFlags_AlwaysClamp | (low > 0.0f && high / std::max(low, 1.0e-6f) >= 50.0f ? ImGuiSliderFlags_Logarithmic : 0);
    if (ImGui::SliderFloat("##value", &value, low, std::max(high, low), format, flags)) dirty = true;
    ImGui::PopID();
}

// A strip of options; `selected` is the index shown, the return says it changed.
bool pick(Draft& draft, bool& dirty, const char* label, const char* id, int& selected,
          std::initializer_list<const char*> labels, bool enabled = true,
          std::initializer_list<const char*> tooltips = {}) {
    field(draft.menu, label);
    const bool changed = choice(draft.menu, id, selected, labels, enabled, 0.0f, tooltips);
    if (changed) dirty = true;
    return changed;
}

void s3cam_card(Draft& draft, const Model& model, const CallbacksV3& callbacks) {
    const auto& debug = model.debug;
    begin_card(draft.menu, "s3cam-main", "S3CAM", "The Skate 3 camera while you ride");
    bool on = debug.s3cam;
    if (toggle_row(draft.menu, "S3Cam",
            "Ride with the Skate 3 style camera. On foot, in menus and in the replay editor the game's own camera is used.",
            on, debug.available && (debug.camera_available || debug.s3cam) && callbacks.queue_debug))
        debug_request(draft.menu, callbacks, {DebugAction::set_s3cam, on});
    if (debug.s3cam_view) info(draft.menu, "Status", "Driving the view");
    else if (debug.s3cam) info(draft.menu, "Status", "Handed back (on foot, in a menu or loading)");
    else if (!debug.camera_available) warn(debug.camera_unavailable.c_str());
    else info(draft.menu, "Status", "Off");

    int chosen_style = draft.next.preset == dingosdk::s3cam::CameraPreset::NativePlus ? 1 : 0;
    if (pick(draft, draft.next_changed, "Style", "s3cam-style", chosen_style, {"Full Skate 3", "Native+"}, true,
            {"The whole Skate 3 camera pipeline owns the camera.",
             "The game's own camera plus Skate 3's air hold, landing dip, shake and roll."}))
        draft.next.preset = chosen_style == 1 ? dingosdk::s3cam::CameraPreset::NativePlus : dingosdk::s3cam::CameraPreset::FullS3;

    int height = draft.next.angle == dingosdk::s3cam::CameraAngle::High ? 1 : 0;
    if (pick(draft, draft.next_changed, "Camera height", "s3cam-height", height, {"Low", "High"}, true,
            {"Skate 3's low camera.", "Skate 3's high camera."}))
        draft.next.angle = height == 1 ? dingosdk::s3cam::CameraAngle::High : dingosdk::s3cam::CameraAngle::Low;

    toggle(draft, draft.chosen_changed, "R3 picks Low/High",
        "The game's camera height button (R3) switches between S3 Low and High.",
        draft.chosen.follow_game_height);
    toggle(draft, draft.chosen_changed, "Logging", "Log S3Cam's state and shot changes and every landing to ReSkate.log.",
        draft.chosen.verbose);
    end_card();
}

void look_card(Draft& draft) {
    auto& look = draft.next.look;
    begin_card(draft.menu, "s3cam-look", "LOOK", "Pitch prediction (Full Skate 3 style)");
    toggle(draft, draft.next_changed, "Landing look",
        "In the air, look down toward a landing below the takeoff (stairs, gaps to a lower level).", look.landing_look);
    ImGui::BeginDisabled(!look.landing_look);
    slider(draft, draft.next_changed, "Landing look strength", "Share of the way the look target moves toward the predicted landing.",
        look.landing_look_strength, 0.0f, 1.0f, "%.2f");
    slider(draft, draft.next_changed, "Full drop", "How far below the takeoff the landing is for the full strength; less scales down.",
        look.landing_look_full_drop, 0.5f, 10.0f, "%.1f m"); // valid() allows 0.1-50: the slider keeps the useful part
    ImGui::EndDisabled();
    toggle(draft, draft.next_changed, "Slope look", "On the ground, pitch with the slope: down riding downhill, up uphill.",
        look.slope_look);
    ImGui::BeginDisabled(!look.slope_look);
    slider(draft, draft.next_changed, "Slope look strength", "Share of the incline angle added to the pitch.",
        look.slope_look_strength, 0.0f, 1.0f, "%.2f");
    ImGui::EndDisabled();
    slider(draft, draft.next_changed, "Vertical follow",
        "How much the pitch follows the skater's height. 0 keeps the pitch level with the anchor.",
        look.vertical_follow, 0.0f, 1.0f, "%.2f");
    slider(draft, draft.next_changed, "Response time", "How fast the look offsets ease in and out.", look.response_time, 0.0f, 5.0f,
        "%.2f s");
    end_card();
}

void shoulder_card(Draft& draft) {
    namespace sh = dingosdk::s3cam;
    auto& shoulder = draft.next.shoulder;
    begin_card(draft.menu, "s3cam-shoulder", "SHOULDER", "Over-the-shoulder offset");
    int mode = shoulder.mode == sh::ShoulderSide::Manual ? 1 : shoulder.mode == sh::ShoulderSide::Auto ? 2 : 0;
    if (pick(draft, draft.next_changed, "Mode", "s3cam-shoulder-mode", mode, {"Off", "Manual", "Auto"}, true,
            {"The skater stays in the middle of the screen.", "You pick the side below.",
             "The side follows your stance: the camera sits on the toe side."}))
        shoulder.mode = mode == 1 ? sh::ShoulderSide::Manual : mode == 2 ? sh::ShoulderSide::Auto : sh::ShoulderSide::Off;
    int camera_side = shoulder.side == 1 ? 1 : 0;
    if (pick(draft, draft.next_changed, "Camera side (manual)", "s3cam-shoulder-side", camera_side, {"Left", "Right"},
            shoulder.mode == sh::ShoulderSide::Manual,
            {"The camera sits to the skater's left, so the skater is right of the screen centre.",
             "The camera sits to the skater's right, so the skater is left of the screen centre."}))
        shoulder.side = camera_side == 1 ? 1 : -1;
    int stance = shoulder.goofy ? 1 : 0;
    if (pick(draft, draft.next_changed, "Stance (auto)", "s3cam-shoulder-stance", stance, {"Regular", "Goofy"},
            shoulder.mode == sh::ShoulderSide::Auto,
            {"Regular rides with the toes to the right; riding switch flips it.", "Goofy rides with the toes to the left."}))
        shoulder.goofy = stance == 1;
    ImGui::BeginDisabled(shoulder.mode == sh::ShoulderSide::Off);
    slider(draft, draft.next_changed, "Offset", "How far the camera slides sideways.", shoulder.offset, 0.0f, 3.0f, "%.2f m");
    slider(draft, draft.next_changed, "Switch time", "How long the camera takes to slide across to the other side.",
        shoulder.switch_time, 0.0f, 5.0f, "%.2f s");
    ImGui::EndDisabled();
    note("L3 swaps the side when it is bound in Controls > Binds.");
    end_card();
}

void follow_card(Draft& draft) {
    auto& follow = draft.next.follow;
    begin_card(draft.menu, "s3cam-follow", "FOLLOW", "How tightly the camera follows (Full Skate 3 style)");
    slider(draft, draft.next_changed, "Strength", "1 is Skate 3. Higher follows tighter with less lag, lower follows looser.",
        follow.strength, 0.2f, 4.0f, "%.2fx");
    toggle(draft, draft.next_changed, "Dynamic follow", "Follow tighter as your speed rises.", follow.dynamic);
    ImGui::BeginDisabled(!follow.dynamic);
    slider(draft, draft.next_changed, "Dynamic speed", "The speed where the boost is full.", follow.dynamic_speed, 0.5f, 60.0f,
        "%.1f m/s");
    slider(draft, draft.next_changed, "Dynamic boost", "Added to the strength at that speed.", follow.dynamic_boost, 0.0f, 3.0f,
        "+%.2f");
    ImGui::EndDisabled();
    end_card();
}

void fov_card(Draft& draft) {
    auto& fov = draft.next.fov;
    begin_card(draft.menu, "s3cam-fov", "FIELD OF VIEW");
    toggle(draft, draft.chosen_changed, "S3Cam drives FOV",
        "S3Cam writes the field of view (the base plus the terms below). Off, the game camera keeps its own.",
        draft.chosen.shot_fov);
    ImGui::BeginDisabled(!draft.chosen.shot_fov);
    field(draft.menu, "FOV override", "Vertical degrees replacing the game's own field of view. 0 leaves it alone.");
    int degrees = static_cast<int>(std::lround(draft.next.fov_override_deg));
    if (ImGui::SliderInt("##s3cam-fov-override", &degrees, 0, 120, degrees > 0 ? "%d degrees" : "Game's own",
            ImGuiSliderFlags_AlwaysClamp)) {
        // The console accepts 0 or 30-120; the slider jumps over the gap.
        if (degrees > 0 && degrees < 30) degrees = degrees < 15 ? 0 : 30;
        draft.next.fov_override_deg = static_cast<float>(degrees);
        draft.next_changed = true;
    }
    toggle(draft, draft.next_changed, "Shot lens",
        "Use each shot's own lens relative to the chase shot's. The stock shots share one lens, so this changes nothing today.",
        fov.shot_fov);
    toggle(draft, draft.next_changed, "Speed FOV", "Widen the view with speed.", fov.speed_fov);
    ImGui::BeginDisabled(!fov.speed_fov);
    slider(draft, draft.next_changed, "Speed FOV degrees", "Extra degrees at the full-speed end.", fov.speed_fov_degrees, 0.0f, 40.0f,
        "+%.1f degrees");
    slider(draft, draft.next_changed, "Speed FOV from", "Where widening starts.", fov.speed_fov_min, 0.0f,
        std::min(60.0f, fov.speed_fov_max - 0.1f), "%.1f m/s");
    slider(draft, draft.next_changed, "Speed FOV full at", "Where widening is full.", fov.speed_fov_max,
        std::max(0.1f, fov.speed_fov_min + 0.1f), 80.0f, "%.1f m/s");
    ImGui::EndDisabled();
    toggle(draft, draft.next_changed, "Big-air FOV", "Widen the view in big airs, as Skate 3 does.", fov.air_fov);
    ImGui::BeginDisabled(!fov.air_fov);
    slider(draft, draft.next_changed, "Big-air FOV degrees", "Extra degrees at the full height.", fov.air_fov_degrees, 0.0f, 40.0f,
        "+%.1f degrees");
    slider(draft, draft.next_changed, "Big-air full height", "Predicted height above the takeoff for the full widening.",
        fov.air_fov_full_height, 0.1f, 50.0f, "%.1f m");
    ImGui::EndDisabled();
    slider(draft, draft.next_changed, "Smoothing time", "How slowly the field of view eases, so it never snaps.",
        fov.smoothing_time, 0.0f, 5.0f, "%.2f s");
    ImGui::EndDisabled();
    end_card();
}

void shake_card(Draft& draft) {
    auto& camera = draft.next;
    begin_card(draft.menu, "s3cam-shake", "SHAKE");
    toggle(draft, draft.next_changed, "Landing and speed shake", "The master switch for the shake in both styles.", camera.shake_enabled);
    ImGui::BeginDisabled(!camera.shake_enabled);
    slider(draft, draft.next_changed, "Landing shake strength", "The kick of a landing at full landing speed.",
        camera.shake.one_shot_magnitude, 0.0f, 10.0f, "%.2f");
    toggle(draft, draft.next_changed, "Speed shake", "A rumble that grows with speed.", camera.speed_shake.enabled);
    ImGui::BeginDisabled(!camera.speed_shake.enabled);
    slider(draft, draft.next_changed, "Speed shake strength", "Multiplies the rumble.", camera.speed_shake.strength, 0.0f, 10.0f,
        "%.2fx");
    slider(draft, draft.next_changed, "Speed shake top speed", "The speed for the full rumble.", camera.speed_shake.top_speed, 0.5f, 80.0f,
        "%.1f m/s");
    toggle(draft, draft.next_changed, "Downhill boost", "More rumble riding downhill.", camera.speed_shake.downhill_boost);
    ImGui::BeginDisabled(!camera.speed_shake.downhill_boost);
    slider(draft, draft.next_changed, "Downhill scale", "The rumble multiplier on a full downhill.",
        camera.speed_shake.downhill_scale, 1.0f, 10.0f, "%.2fx");
    slider(draft, draft.next_changed, "Downhill full at", "The slope for the full downhill scale.",
        camera.speed_shake.downhill_full_degrees, 1.0f, 80.0f, "%.0f degrees");
    ImGui::EndDisabled();
    ImGui::EndDisabled();
    ImGui::EndDisabled();
    end_card();
}

void collision_card(Draft& draft) {
    auto& collision = draft.next.collision;
    begin_card(draft.menu, "s3cam-collision", "COLLISION", "Walls, poles and the ground between you and the camera");
    toggle(draft, draft.next_changed, "Collision", "Pull the camera in front of obstacles.", collision.enabled);
    ImGui::BeginDisabled(!collision.enabled);
    slider(draft, draft.next_changed, "Radius", "Space kept between the camera and a surface it hits.", collision.radius, 0.0f, 2.0f,
        "%.2f m");
    slider(draft, draft.next_changed, "Minimum distance", "The camera never comes closer to you than this.",
        collision.min_distance, 0.0f, 5.0f, "%.2f m");
    slider(draft, draft.next_changed, "Pull-in time", "How fast the camera moves in front of an obstacle (near instant).",
        collision.pull_in_time, 0.0f, 2.0f, "%.2f s");
    slider(draft, draft.next_changed, "Release time", "How fast it eases back out once the way is clear.",
        collision.release_time, 0.0f, 5.0f, "%.2f s");
    slider(draft, draft.next_changed, "Ground clearance", "Height kept above the ground under the camera.",
        collision.ground_clearance, 0.0f, 3.0f, "%.2f m");
    ImGui::EndDisabled();
    end_card();
}

void native_plus_card(Draft& draft) {
    auto& plus = draft.next.native_plus;
    begin_card(draft.menu, "s3cam-native-plus", "NATIVE+ LAYERS", "Used by the Native+ style");
    toggle(draft, draft.next_changed, "Air hold", "Hold the camera height in the air.", plus.air_hold);
    toggle(draft, draft.next_changed, "Landing dip", "The camera dips and settles when you land.", plus.landing_dip);
    toggle(draft, draft.next_changed, "Native+ shake", "Landing and speed shake on the game's camera.", plus.shake);
    toggle(draft, draft.next_changed, "Roll", "The shot's framing roll (and shake roll).", plus.roll);
    ImGui::BeginDisabled(!plus.landing_dip);
    slider(draft, draft.next_changed, "Dip depth", "The deepest point of a full-strength landing.", plus.dip_depth, 0.0f, 2.0f,
        "%.2f m");
    slider(draft, draft.next_changed, "Dip peak time", "Time to the deepest point.", plus.dip_peak_time, 0.02f, 2.0f, "%.2f s");
    ImGui::EndDisabled();
    end_card();
}

void transitions_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-transitions", "TRANSITIONS", "Crossfades with the game's camera");
    slider(draft, draft.chosen_changed, "Take blend time", "Crossfade from the game camera when S3Cam takes the view.",
        draft.chosen.take_blend_time, 0.0f, 5.0f, "%.2f s");
    slider(draft, draft.chosen_changed, "Release blend time", "Crossfade back to the game camera before it is handed back.",
        draft.chosen.release_blend_time, 0.0f, 5.0f, "%.2f s");
    end_card();
}
}

void s3cam_page(SkateMenu& menu, const Model& model, const CallbacksV3& callbacks) {
    Draft draft(menu, glue::s3cam_settings(), glue::s3cam_options());
    ImGui::BeginChild("s3cam-page", ImVec2(0, page_body_height(menu)));
    s3cam_card(draft, model, callbacks);
    look_card(draft);
    shoulder_card(draft);
    follow_card(draft);
    fov_card(draft);
    shake_card(draft);
    collision_card(draft);
    native_plus_card(draft);
    transitions_card(draft);

    begin_card(menu, "s3cam-reset", "DEFAULTS", "Changes apply at once and are saved between launches");
    if (ImGui::Button("Reset to defaults", ImVec2(-FLT_MIN, 0))) {
        glue::s3cam_config_reset();
        feedback(menu, "S3Cam settings are back to their defaults.");
        draft.next_changed = draft.chosen_changed = false; // this frame's edits would undo the reset
    }
    end_card();
    ImGui::EndChild();

    if (draft.next_changed && !glue::s3cam_set_settings(draft.next))
        feedback(menu, "That value is out of range; the old one is kept.");
    if (draft.chosen_changed) glue::s3cam_set_options(draft.chosen);
}
}
