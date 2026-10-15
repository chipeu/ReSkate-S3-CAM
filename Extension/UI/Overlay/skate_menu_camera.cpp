#include "skate_menu_internal.h"
#include "Extension/Camera/s3cam.h"
#include "Extension/Camera/s3cam_config.h"
#include "Extension/Camera/s3cam_presets.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <string>

// The S3 CAMERA page: S3Cam's on/off switch and every tunable, live. The overlay is a static library
// linked into the runtime DLL, so the page calls the runtime's thread-safe s3cam_settings() /
// s3cam_set_settings() / s3cam_options() directly, as the Music page calls music_inject. The settings
// are read afresh each frame; a change builds a new copy and hands it to s3cam_set_settings(), which
// refuses an out-of-range one and so keeps the old value (the page then shows the old value again).
// The page is a switch card on top and a row of tabs (CAMERA, AIR, TRICKS, FEEL, COLLISION, PRESETS,
// ADVANCED, drawn with category_tabs like the other pages); each tab is a few short cards. Labels are
// plain words and the saved keys never depend on them (Extension/Camera/s3cam_preset_format.h).
// Saving happens elsewhere (Extension/Camera/s3cam_config.h). The PRESETS card keeps named setups as
// files (Extension/Camera/s3cam_presets.h); it touches the disk only on a button press and when the
// page opens, never once per frame.
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

// What the page remembers between frames (there is one overlay and one such page).
struct PageState {
    int tab = 0;
    int position_for = -1; // CAMERA POSITION edits 0 = the Low camera, 1 = the High one; -1 until first drawn
};
PageState& page_state() {
    static PageState state;
    return state;
}

// A setting of the camera (Draft::next) and a toggle of the same kind.
void set_toggle(Draft& draft, const char* label, const char* hint, bool& value) {
    toggle(draft, draft.next_changed, label, hint, value);
}
void set_slider(Draft& draft, const char* label, const char* tooltip, float& value, float low, float high, const char* format) {
    slider(draft, draft.next_changed, label, tooltip, value, low, high, format);
}

// The switch on top of every tab.
void s3cam_card(Draft& draft, const Model& model, const CallbacksV3& callbacks) {
    const auto& debug = model.debug;
    begin_card(draft.menu, "s3cam-main", "S3CAM");
    bool on = debug.s3cam;
    if (toggle_row(draft.menu, "S3Cam",
            "Use this camera while you ride. On foot, in menus and in the replay editor the game's camera is used.",
            on, debug.available && (debug.camera_available || debug.s3cam) && callbacks.queue_debug))
        debug_request(draft.menu, callbacks, {DebugAction::set_s3cam, on});
    if (debug.s3cam_view) info(draft.menu, "Status", "Enabled");
    else if (debug.s3cam) info(draft.menu, "Status", "Disabled off board");
    else if (!debug.camera_available) warn(debug.camera_unavailable.c_str());
    else info(draft.menu, "Status", "Off");
    end_card();
}

// ---- CAMERA ----

void camera_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-camera", "CAMERA");
    int chosen_style = draft.next.preset == dingosdk::s3cam::CameraPreset::NativePlus ? 1 : 0;
    if (pick(draft, draft.next_changed, "Style", "s3cam-style", chosen_style, {"Full", "Native+"}, true,
            {"This camera does everything.",
             "Keeps the game's camera and adds the air, landing and shake effects."}))
        draft.next.preset = chosen_style == 1 ? dingosdk::s3cam::CameraPreset::NativePlus : dingosdk::s3cam::CameraPreset::FullS3;

    int height = draft.next.angle == dingosdk::s3cam::CameraAngle::High ? 1 : 0;
    if (pick(draft, draft.next_changed, "Low or High", "s3cam-height", height, {"Low", "High"}, true,
            {"The camera sits low, close to the ground.", "The camera sits higher and looks down more."}))
        draft.next.angle = height == 1 ? dingosdk::s3cam::CameraAngle::High : dingosdk::s3cam::CameraAngle::Low;

    toggle(draft, draft.chosen_changed, "R3 changes Low/High",
        "Pressing the game's camera button (R3) switches between Low and High.", draft.chosen.follow_game_height);
    end_card();
}

// Where the camera sits, kept separately for Low and High.
void camera_position_card(Draft& draft, PageState& state) {
    if (state.position_for < 0) state.position_for = draft.next.angle == dingosdk::s3cam::CameraAngle::High ? 1 : 0;
    begin_card(draft.menu, "s3cam-position", "CAMERA POSITION");
    pick(draft, draft.next_changed, "Set position for", "s3cam-position-for", state.position_for, {"Low", "High"}, true,
        {"Edit where the Low camera sits.", "Edit where the High camera sits."});
    auto& framing = state.position_for == 1 ? draft.next.framing_high : draft.next.framing;
    set_slider(draft, "Distance", "How far the camera sits behind you. 1 is normal; less comes closer, more pulls back.",
        framing.distance_scale, 0.4f, 3.0f, "%.2fx");
    set_slider(draft, "Height", "Raises or lowers the camera around you. Higher looks down on you more.",
        framing.height_degrees, -30.0f, 45.0f, "%.1f degrees");
    set_slider(draft, "Tilt", "Aims the camera up or down without moving it. Positive looks up, negative looks down.",
        framing.pitch_degrees, -30.0f, 30.0f, "%.1f degrees");
    end_card();
}

void fov_override_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-fov", "FIELD OF VIEW");
    toggle(draft, draft.chosen_changed, "FOV override",
        "On: this camera sets the field of view, including the widening with speed and in big airs. Off: the game's own field of view.",
        draft.chosen.shot_fov);
    ImGui::BeginDisabled(!draft.chosen.shot_fov);
    field(draft.menu, "FOV", "Field of view in degrees. Pick 0 to keep the game's own.");
    int degrees = static_cast<int>(std::lround(draft.next.fov_override_deg));
    if (ImGui::SliderInt("##s3cam-fov-override", &degrees, 0, 120, degrees > 0 ? "%d degrees" : "Game's own",
            ImGuiSliderFlags_AlwaysClamp)) {
        // The console accepts 0 or 30-120; the slider jumps over the gap.
        if (degrees > 0 && degrees < 30) degrees = degrees < 15 ? 0 : 30;
        draft.next.fov_override_deg = static_cast<float>(degrees);
        draft.next_changed = true;
    }
    ImGui::EndDisabled();
    end_card();
}

// ---- AIR ----

void big_air_card(Draft& draft) {
    auto& air = draft.next.air_camera;
    begin_card(draft.menu, "s3cam-big-air", "BIG AIR");
    set_toggle(draft, "Keep skater on screen", "Aims the camera so you never leave the screen in the air.", air.keep_in_frame);
    set_slider(draft, "Big air: follow height",
        "How much the camera rises with you in a big air. 0 stays at the takeoff height, 1 rises all the way.",
        air.follow_height, 0.0f, 1.0f, "%.2f");
    set_slider(draft, "Big air: camera rise",
        "How far the camera swings up over you in a big air, so it looks down at the landing.", air.rise_degrees, 0.0f, 60.0f,
        "%.0f degrees");
    set_slider(draft, "Big air: full at height", "How high (or how far down) the jump goes for the full rise.",
        air.rise_full_height, 0.1f, 20.0f, "%.1f m");
    set_slider(draft, "Big air: ease time", "How long the rise takes to build up and settle.", air.ease_time, 0.0f, 3.0f, "%.2f s");
    end_card();
}

void big_air_fov_card(Draft& draft) {
    auto& fov = draft.next.fov;
    begin_card(draft.menu, "s3cam-air-fov", "BIG-AIR FOV");
    if (!draft.chosen.shot_fov) note("Turn on FOV override in the CAMERA tab to use this.");
    ImGui::BeginDisabled(!draft.chosen.shot_fov);
    set_toggle(draft, "Widen in big airs", "The view opens up a little in a big air.", fov.air_fov);
    ImGui::BeginDisabled(!fov.air_fov);
    set_slider(draft, "Extra angle", "How many degrees the view opens up at full height.", fov.air_fov_degrees, 0.0f, 40.0f,
        "+%.1f degrees");
    set_slider(draft, "Full at height", "How high the jump goes for the full widening.", fov.air_fov_full_height, 0.1f, 50.0f,
        "%.1f m");
    ImGui::EndDisabled();
    ImGui::EndDisabled();
    end_card();
}

void landing_view_card(Draft& draft) {
    auto& look = draft.next.look;
    begin_card(draft.menu, "s3cam-landing-view", "LANDING VIEW");
    set_toggle(draft, "Look down at landing",
        "In the air, the camera tips down toward where you will land when it is lower than your takeoff (stairs, gaps).",
        look.landing_look);
    ImGui::BeginDisabled(!look.landing_look);
    set_slider(draft, "Look down amount", "How far the camera tips toward the landing.", look.landing_look_strength, 0.0f, 1.0f,
        "%.2f");
    set_slider(draft, "Full at drop", "How far below the takeoff the landing is for the full amount.",
        look.landing_look_full_drop, 0.5f, 10.0f, "%.1f m"); // valid() allows 0.1-50: the slider keeps the useful part
    ImGui::EndDisabled();
    set_slider(draft, "Aim follows height", "How much the camera's aim follows your height. 0 keeps it level.",
        look.vertical_follow, 0.0f, 1.0f, "%.2f");
    end_card();
}

void landing_shake_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-landing-shake", "LANDING SHAKE");
    ImGui::BeginDisabled(!draft.next.shake_enabled);
    set_slider(draft, "Landing shake", "How hard the camera kicks when you land. 0 is none.", draft.next.shake.one_shot_magnitude,
        0.0f, 10.0f, "%.2f");
    ImGui::EndDisabled();
    if (!draft.next.shake_enabled) note("Camera shake is off in the FEEL tab.");
    end_card();
}

void landing_bounce_card(Draft& draft) {
    auto& plus = draft.next.native_plus;
    begin_card(draft.menu, "s3cam-landing-bounce", "LANDING BOUNCE");
    note("Used by the Native+ style.");
    set_toggle(draft, "Landing bounce", "The camera dips down a little when you land and springs back.", plus.landing_dip);
    ImGui::BeginDisabled(!plus.landing_dip);
    set_slider(draft, "Bounce depth", "How far the camera dips after a hard landing.", plus.dip_depth, 0.0f, 2.0f, "%.2f m");
    set_slider(draft, "Bounce time", "How long the camera takes to reach the lowest point.", plus.dip_peak_time, 0.02f, 2.0f,
        "%.2f s");
    ImGui::EndDisabled();
    end_card();
}

// ---- TRICKS ----

void trick_turn_card(Draft& draft) {
    auto& yaw = draft.next.trick_yaw;
    begin_card(draft.menu, "s3cam-trick-yaw", "TRICK TURN");
    note("The camera swings round to show the trick, holds that angle while you keep tricking, and comes back behind you after landing.");
    set_toggle(draft, "Turn on tricks", "Swing the camera round to the side during tricks.", yaw.enabled);
    ImGui::BeginDisabled(!yaw.enabled);
    set_slider(draft, "Turn angle", "How far round the camera swings.", yaw.angle_degrees, 0.0f, 90.0f, "%.0f degrees");
    int side = yaw.side < 0 ? 1 : yaw.side > 0 ? 2 : 0;
    if (pick(draft, draft.next_changed, "Turn side", "s3cam-trick-yaw-side", side, {"Auto", "Left", "Right"}, true,
            {"Follows the shoulder side, or your stance if the shoulder is off.", "The camera swings round to your left.",
             "The camera swings round to your right."}))
        yaw.side = side == 1 ? -1 : side == 2 ? 1 : 0;
    set_toggle(draft, "In the air", "Turn during airs and flip tricks.", yaw.in_air);
    set_toggle(draft, "On grinds", "Turn while grinding.", yaw.on_grinds);
    set_toggle(draft, "On manuals", "Turn while manualling.", yaw.on_manuals);
    set_slider(draft, "Air time needed", "Time in the air before the turn starts, so a plain ollie stays centred.",
        yaw.min_air_time, 0.0f, 3.0f, "%.2f s");
    set_slider(draft, "Turn time", "How long the camera takes to swing out.", yaw.in_time, 0.0f, 5.0f, "%.2f s");
    set_slider(draft, "Hold time", "How long the angle stays after the trick. A new trick in this time keeps it.",
        yaw.hold_time, 0.0f, 5.0f, "%.2f s");
    set_slider(draft, "Return time", "How long the camera takes to come back behind you.", yaw.return_time, 0.0f, 10.0f, "%.2f s");
    ImGui::EndDisabled();
    end_card();
}

void manual_card(Draft& draft) {
    namespace sh = dingosdk::s3cam;
    // One manual close-up for both cameras: it is shown from the active one and written to both.
    const bool high = draft.next.angle == sh::CameraAngle::High;
    auto& framing = high ? draft.next.framing_high : draft.next.framing;
    auto& other = high ? draft.next.framing : draft.next.framing_high;
    bool edited = false;
    begin_card(draft.menu, "s3cam-manual", "MANUAL");
    toggle(draft, edited, "Closer in manuals", "The camera moves in for manuals and nose manuals.", framing.manual_camera);
    ImGui::BeginDisabled(!framing.manual_camera);
    slider(draft, edited, "Distance", "How close the camera sits in a manual, compared with normal.",
        framing.manual_distance_scale, 0.3f, 1.5f, "%.2fx");
    slider(draft, edited, "Height", "Raises or lowers the camera around you in a manual.", framing.manual_height_degrees, -30.0f, 45.0f,
        "%.1f degrees");
    ImGui::EndDisabled();
    if (edited) {
        other.manual_camera = framing.manual_camera;
        other.manual_distance_scale = framing.manual_distance_scale;
        other.manual_height_degrees = framing.manual_height_degrees;
        draft.next_changed = true;
    }
    set_slider(draft, "Manual focus", "What the camera looks at in a manual. 0 is the board, 1 is your upper body.",
        draft.next.look.manual_focus, 0.0f, 1.0f, "%.2f");
    end_card();
}

void grind_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-grind", "GRIND");
    set_slider(draft, "Grind focus", "What the camera looks at in a grind. 0 is the board, 1 is your upper body.",
        draft.next.look.grind_focus, 0.0f, 1.0f, "%.2f");
    end_card();
}

// ---- FEEL ----

void follow_card(Draft& draft) {
    auto& follow = draft.next.follow;
    begin_card(draft.menu, "s3cam-follow", "FOLLOW");
    set_slider(draft, "Follow tightness", "1 is normal. Higher keeps the camera right behind you, lower lets it trail.",
        follow.strength, 0.2f, 4.0f, "%.2fx");
    set_toggle(draft, "Tighter at speed", "The camera follows tighter the faster you go.", follow.dynamic);
    ImGui::BeginDisabled(!follow.dynamic);
    set_slider(draft, "Full at speed", "The speed where it is as tight as it gets.", follow.dynamic_speed, 0.5f, 60.0f, "%.1f m/s");
    set_slider(draft, "Extra tightness", "How much tighter it gets at that speed.", follow.dynamic_boost, 0.0f, 3.0f, "+%.2f");
    ImGui::EndDisabled();
    end_card();
}

void shoulder_card(Draft& draft) {
    namespace sh = dingosdk::s3cam;
    auto& shoulder = draft.next.shoulder;
    begin_card(draft.menu, "s3cam-shoulder", "SHOULDER");
    int mode = shoulder.mode == sh::ShoulderSide::Manual ? 1 : shoulder.mode == sh::ShoulderSide::Auto ? 2 : 0;
    if (pick(draft, draft.next_changed, "Shoulder", "s3cam-shoulder-mode", mode, {"Off", "Manual", "Auto"}, true,
            {"You stay in the middle of the screen.", "You pick the side below.",
             "The camera sits on the toe side of your stance."}))
        shoulder.mode = mode == 1 ? sh::ShoulderSide::Manual : mode == 2 ? sh::ShoulderSide::Auto : sh::ShoulderSide::Off;
    int camera_side = shoulder.side == 1 ? 1 : 0;
    if (pick(draft, draft.next_changed, "Side", "s3cam-shoulder-side", camera_side, {"Left", "Right"},
            shoulder.mode == sh::ShoulderSide::Manual,
            {"The camera sits to your left, so you are right of the screen centre.",
             "The camera sits to your right, so you are left of the screen centre."}))
        shoulder.side = camera_side == 1 ? 1 : -1;
    int stance = shoulder.goofy ? 1 : 0;
    if (pick(draft, draft.next_changed, "Stance", "s3cam-shoulder-stance", stance, {"Regular", "Goofy"},
            shoulder.mode == sh::ShoulderSide::Auto,
            {"Regular rides with the toes to the right; riding switch flips it.", "Goofy rides with the toes to the left."}))
        shoulder.goofy = stance == 1;
    ImGui::BeginDisabled(shoulder.mode == sh::ShoulderSide::Off);
    set_slider(draft, "Sideways distance", "How far the camera slides to the side.", shoulder.offset, 0.0f, 3.0f, "%.2f m");
    set_slider(draft, "Side change time", "How long the camera takes to slide to the other side.", shoulder.switch_time, 0.0f,
        5.0f, "%.2f s");
    ImGui::EndDisabled();
    note("L3 swaps the side when it is bound in Controls > Binds.");
    end_card();
}

void slope_card(Draft& draft) {
    auto& look = draft.next.look;
    begin_card(draft.menu, "s3cam-slope", "SLOPE");
    set_toggle(draft, "Tilt with slope", "On the ground, the camera tips down going downhill and up going uphill.",
        look.slope_look);
    ImGui::BeginDisabled(!look.slope_look);
    set_slider(draft, "Slope tilt amount", "How much of the slope's angle the camera tips.", look.slope_look_strength, 0.0f, 1.0f,
        "%.2f");
    ImGui::EndDisabled();
    set_slider(draft, "Aim ease time", "How long the camera takes to settle when its aim moves up or down.", look.response_time,
        0.0f, 5.0f, "%.2f s");
    end_card();
}

void shake_card(Draft& draft) {
    auto& camera = draft.next;
    begin_card(draft.menu, "s3cam-shake", "SHAKE");
    set_toggle(draft, "Camera shake", "Turns all camera shake on or off, landing and speed.", camera.shake_enabled);
    ImGui::BeginDisabled(!camera.shake_enabled);
    set_toggle(draft, "Speed shake", "The camera rumbles more the faster you go.", camera.speed_shake.enabled);
    ImGui::BeginDisabled(!camera.speed_shake.enabled);
    set_slider(draft, "Speed shake strength", "How strong the rumble is.", camera.speed_shake.strength, 0.0f, 10.0f, "%.2fx");
    set_slider(draft, "Full at speed", "The speed where the rumble is strongest.", camera.speed_shake.top_speed, 0.5f, 80.0f,
        "%.1f m/s");
    set_toggle(draft, "Shakier downhill", "More rumble riding downhill.", camera.speed_shake.downhill_boost);
    ImGui::BeginDisabled(!camera.speed_shake.downhill_boost);
    set_slider(draft, "Downhill amount", "How much stronger the rumble is on a steep downhill.",
        camera.speed_shake.downhill_scale, 1.0f, 10.0f, "%.2fx");
    set_slider(draft, "Full at slope", "How steep the hill is for the full downhill amount.",
        camera.speed_shake.downhill_full_degrees, 1.0f, 80.0f, "%.0f degrees");
    ImGui::EndDisabled();
    ImGui::EndDisabled();
    ImGui::EndDisabled();
    end_card();
}

void speed_fov_card(Draft& draft) {
    auto& fov = draft.next.fov;
    begin_card(draft.menu, "s3cam-speed-fov", "SPEED FOV");
    if (!draft.chosen.shot_fov) note("Turn on FOV override in the CAMERA tab to use this.");
    ImGui::BeginDisabled(!draft.chosen.shot_fov);
    set_toggle(draft, "Widen with speed", "The view opens up the faster you go.", fov.speed_fov);
    ImGui::BeginDisabled(!fov.speed_fov);
    set_slider(draft, "Extra angle", "How many degrees the view opens up at full speed.", fov.speed_fov_degrees, 0.0f, 40.0f,
        "+%.1f degrees");
    set_slider(draft, "Starts at speed", "The speed where the view starts to open up.", fov.speed_fov_min, 0.0f,
        std::min(60.0f, fov.speed_fov_max - 0.1f), "%.1f m/s");
    set_slider(draft, "Full at speed", "The speed where it is fully open.", fov.speed_fov_max,
        std::max(0.1f, fov.speed_fov_min + 0.1f), 80.0f, "%.1f m/s");
    ImGui::EndDisabled();
    ImGui::EndDisabled();
    end_card();
}

// ---- COLLISION ----

void collision_card(Draft& draft) {
    auto& collision = draft.next.collision;
    begin_card(draft.menu, "s3cam-collision", "COLLISION", "Walls, poles and the ground");
    set_toggle(draft, "Collision", "The camera moves in front of walls and poles instead of going through them.", collision.enabled);
    ImGui::BeginDisabled(!collision.enabled);
    set_slider(draft, "Wall gap", "Space kept between the camera and a wall.", collision.radius, 0.0f, 2.0f, "%.2f m");
    set_slider(draft, "Closest to you", "The camera never comes closer to you than this.", collision.min_distance, 0.0f, 5.0f,
        "%.2f m");
    set_slider(draft, "Move-in time", "How fast the camera moves in front of an obstacle.", collision.pull_in_time, 0.0f, 2.0f,
        "%.2f s");
    set_slider(draft, "Move-out time", "How fast the camera eases back once the way is clear.", collision.release_time, 0.0f,
        5.0f, "%.2f s");
    set_slider(draft, "Ground gap", "Height kept above the ground under the camera.", collision.ground_clearance, 0.0f, 3.0f,
        "%.2f m");
    ImGui::EndDisabled();
    end_card();
}

// ---- ADVANCED ----

void blend_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-blend", "BLEND");
    slider(draft, draft.chosen_changed, "Blend time getting on",
        "How long the camera takes to move from the game's camera to this one when you get on the board.",
        draft.chosen.take_blend_time, 0.0f, 5.0f, "%.2f s");
    slider(draft, draft.chosen_changed, "Blend time getting off",
        "How long the camera takes to move back to the game's camera when you get off the board.",
        draft.chosen.release_blend_time, 0.0f, 5.0f, "%.2f s");
    end_card();
}

void native_plus_card(Draft& draft) {
    auto& plus = draft.next.native_plus;
    begin_card(draft.menu, "s3cam-native-plus", "NATIVE+ EXTRAS", "Only for the Native+ style");
    set_toggle(draft, "Hold height in the air", "The camera stays at its height while you are in the air.", plus.air_hold);
    set_toggle(draft, "Shake", "Landing and speed shake on the game's camera.", plus.shake);
    set_toggle(draft, "Tilt", "The camera leans a little with the shot and the shake.", plus.roll);
    end_card();
}

void other_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-other", "OTHER");
    toggle(draft, draft.chosen_changed, "Logging", "Write what the camera is doing, and every landing, to ReSkate.log.",
        draft.chosen.verbose);
    set_slider(draft, "FOV ease time", "How slowly the field of view changes, so it never snaps.", draft.next.fov.smoothing_time,
        0.0f, 5.0f, "%.2f s");
    end_card();
}

// ---- Presets ----

// The PRESETS card's own state, kept between frames (there is one overlay and one such page).
struct PresetPage {
    std::string selected;                // the list's chosen preset
    std::array<char, 200> name{};        // the name field (UTF-8); a saved name holds at most 48 characters
    std::string result;                  // the last result line
    bool result_ok{true};
    std::string armed_overwrite;         // the name field's text when "Save" asked to overwrite; a second click does it
    std::string armed_delete;            // the preset "Delete" asked about; a second click does it
    int last_frame{-1000};               // the frame the page last drew, to notice that it has just opened
};

PresetPage& preset_page() {
    static PresetPage page;
    return page;
}

// A row of equal-width buttons.
struct ButtonRow {
    int count;
    float width;
    int next{};
};
ButtonRow begin_row(int count) {
    const float gap = ImGui::GetStyle().ItemSpacing.x;
    return {count, std::max(1.0f, (ImGui::GetContentRegionAvail().x - gap * static_cast<float>(count - 1)) / static_cast<float>(count))};
}
bool cell(ButtonRow& row, const char* label, bool enabled = true, const char* tooltip = nullptr) {
    if (row.next++ > 0) ImGui::SameLine();
    ImGui::BeginDisabled(!enabled);
    const bool pressed = ImGui::Button(label, ImVec2(row.width, 0));
    ImGui::EndDisabled();
    if (tooltip && ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled)) ImGui::SetTooltip("%s", tooltip);
    return pressed && enabled;
}

void presets_card(Draft& draft, PresetPage& page) {
    const auto& list = glue::s3cam_presets_list();
    const glue::S3CamPresetEntry* chosen = nullptr;
    for (const auto& entry : list)
        if (entry.name == page.selected) { chosen = &entry; break; }
    if (!chosen) page.selected.clear();
    // A confirmation only holds for the thing it was asked about.
    const std::string typed(page.name.data());
    if (page.armed_overwrite != typed) page.armed_overwrite.clear();
    if (page.armed_delete != page.selected) page.armed_delete.clear();

    // `answer` shows a result; a preset that was saved, imported or loaded becomes the selection.
    const auto answer = [&](const glue::S3CamPresetResult& result, bool select) {
        page.result = result.message;
        page.result_ok = result.ok;
        if (select && result.ok && !result.name.empty()) {
            page.selected = result.name;
            std::snprintf(page.name.data(), page.name.size(), "%s", result.name.c_str());
        }
        page.armed_overwrite.clear();
        page.armed_delete.clear();
    };

    begin_card(draft.menu, "s3cam-presets", "PRESETS", "Save, load and share your camera");
    ImGui::BeginChild("s3cam-preset-list", ImVec2(0, px(150)), ImGuiChildFlags_Borders);
    bool double_clicked = false;
    for (const auto& entry : list) {
        ImGui::PushID(entry.name.c_str());
        const std::string label = entry.built_in ? entry.name + "   (built in)" : entry.name;
        if (ImGui::Selectable(label.c_str(), entry.name == page.selected, ImGuiSelectableFlags_AllowDoubleClick)) {
            if (page.selected != entry.name) {
                page.selected = entry.name;
                std::snprintf(page.name.data(), page.name.size(), "%s", entry.name.c_str());
            }
            double_clicked = ImGui::IsMouseDoubleClicked(0);
        }
        ImGui::PopID();
    }
    ImGui::EndChild();

    const bool have = !page.selected.empty();
    const bool saved = chosen && !chosen->built_in;
    if (double_clicked) {
        answer(glue::s3cam_preset_load(page.selected), false);
        draft.next_changed = draft.chosen_changed = false; // this frame's edits would undo the load
    }

    auto row = begin_row(2);
    if (cell(row, "Load", have, "Apply the selected preset to the camera. S3Cam stays on or off as it is. Double-click does the same.")) {
        answer(glue::s3cam_preset_load(page.selected), false);
        draft.next_changed = draft.chosen_changed = false;
    }
    const bool deleting = have && saved && page.armed_delete == page.selected;
    const std::string delete_label = std::string(deleting ? "Really delete?" : "Delete") + "##s3cam-preset-delete";
    if (cell(row, delete_label.c_str(), saved, "Remove the selected preset file. Built-in presets cannot be deleted.")) {
        if (deleting) {
            answer(glue::s3cam_preset_delete(page.selected), false);
            page.selected.clear();
        } else {
            page.result = "Click Really delete? to remove '" + page.selected + "'.";
            page.result_ok = true;
            page.armed_overwrite.clear();
            page.armed_delete = page.selected;
        }
    }

    field(draft.menu, "Name", "Used by Save and Rename. Characters a file name cannot hold are dropped; at most 48 characters.");
    ImGui::InputText("##s3cam-preset-name", page.name.data(), page.name.size());

    row = begin_row(2);
    const bool overwriting = !typed.empty() && page.armed_overwrite == typed;
    const std::string save_label = std::string(overwriting ? "Overwrite?" : "Save") + "##s3cam-preset-save";
    if (cell(row, save_label.c_str(), !typed.empty(), "Save the camera as it is now under this name. An existing name asks first.")) {
        const auto result = glue::s3cam_preset_save(typed, overwriting);
        answer(result, true);
        if (result.confirm) {
            page.result = "'" + result.name + "' already exists. Click Overwrite? to replace it.";
            page.armed_overwrite = typed;
        }
    }
    if (cell(row, "Rename", saved && !typed.empty(), "Give the selected preset the name in the field.")) {
        answer(glue::s3cam_preset_rename(page.selected, typed), true);
    }

    row = begin_row(2);
    if (cell(row, "Export", have, "Copy the selected preset's text to the clipboard to share it. A saved preset is also the file in the preset folder.")) {
        const auto result = glue::s3cam_preset_export(page.selected);
        if (result.ok) ImGui::SetClipboardText(result.text.c_str());
        answer(result, false);
    }
    if (cell(row, "Import from clipboard", true, "Add a preset someone shared with you (paste its text first). You can also put a .json file in the preset folder.")) {
        const char* pasted = ImGui::GetClipboardText();
        answer(glue::s3cam_preset_import(pasted ? pasted : ""), true);
    }

    row = begin_row(2);
    if (cell(row, "Open folder", true, "Show the preset folder in Explorer. Any .json file placed there shows up in the list."))
        answer(glue::s3cam_presets_open_folder(), false);
    if (cell(row, "Refresh list", true, "Scan the folder again.")) {
        glue::s3cam_presets_refresh();
        page.result = "Preset list refreshed.";
        page.result_ok = true;
    }

    if (!page.result.empty()) {
        ImGui::Spacing();
        if (page.result_ok) note(page.result.c_str());
        else warn(page.result.c_str());
    }
    end_card();
}

void reset_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-reset", "DEFAULTS", "Changes apply at once and are saved between launches");
    if (ImGui::Button("Reset to defaults", ImVec2(-FLT_MIN, 0))) {
        glue::s3cam_config_reset();
        feedback(draft.menu, "S3Cam settings are back to their defaults.");
        draft.next_changed = draft.chosen_changed = false; // this frame's edits would undo the reset
    }
    end_card();
}
}

void s3cam_page(SkateMenu& menu, const Model& model, const CallbacksV3& callbacks) {
    Draft draft(menu, glue::s3cam_settings(), glue::s3cam_options());
    auto& state = page_state();
    s3cam_card(draft, model, callbacks);
    category_tabs(menu, state.tab, {"CAMERA", "AIR", "TRICKS", "FEEL", "COLLISION", "PRESETS", "ADVANCED"}, "s3cam-tabs");
    ImGui::PushID(state.tab);
    ImGui::BeginChild("s3cam-tab", ImVec2(0, page_body_height(menu)));
    switch (state.tab) {
    case 0:
        camera_card(draft);
        camera_position_card(draft, state);
        fov_override_card(draft);
        break;
    case 1:
        big_air_card(draft);
        big_air_fov_card(draft);
        landing_view_card(draft);
        landing_shake_card(draft);
        landing_bounce_card(draft);
        break;
    case 2:
        trick_turn_card(draft);
        manual_card(draft);
        grind_card(draft);
        break;
    case 3:
        follow_card(draft);
        shoulder_card(draft);
        slope_card(draft);
        shake_card(draft);
        speed_fov_card(draft);
        break;
    case 4:
        collision_card(draft);
        break;
    case 5: {
        // File access only when the tab has just opened (it was not drawn on the previous frame).
        auto& presets = preset_page();
        const int frame = ImGui::GetFrameCount();
        if (frame - presets.last_frame > 1) {
            glue::s3cam_presets_refresh();
            presets.armed_overwrite.clear();
            presets.armed_delete.clear();
        }
        presets.last_frame = frame;
        presets_card(draft, presets);
        break;
    }
    default:
        blend_card(draft);
        native_plus_card(draft);
        other_card(draft);
        reset_card(draft);
        break;
    }
    ImGui::EndChild();
    ImGui::PopID();

    if (draft.next_changed && !glue::s3cam_set_settings(draft.next))
        feedback(menu, "That value is out of range; the old one is kept.");
    if (draft.chosen_changed) glue::s3cam_set_options(draft.chosen);
}
}
