#include "skate_menu_internal.h"
#include "Extension/Camera/s3cam.h"
#include "Extension/Camera/s3cam_config.h"
#include "Extension/Camera/s3cam_presets.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <string>

// The DYNAMIC CAMERA page (S3Cam in the code): its on/off switch and every tunable, live. The overlay is a static library
// linked into the runtime DLL, so the page calls the runtime's thread-safe s3cam_settings() /
// s3cam_set_settings() / s3cam_options() directly, as the Music page calls music_inject. The settings
// are read afresh each frame; a change builds a new copy and hands it to s3cam_set_settings(), which
// refuses an out-of-range one and so keeps the old value (the page then shows the old value again).
// The page is a switch card on top and a row of tabs (PRESETS, CAMERA, FOLLOW & MOVEMENT, TRICKS & CLOSE-UPS,
// AIR & LANDING, CAMERA EFFECTS, ADVANCED, drawn with category_tabs like the other pages); each tab is a few
// short cards. A setting two features share (Follow the board, the close-up return time, the tilt
// transition time) has one control. Labels are
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
    int position_for = -1; // CAMERA POSITION, MANUAL and GRIND edit 0 = the Low camera, 1 = the High one; -1 until first drawn
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
    begin_card(draft.menu, "s3cam-main", "DYNAMIC CAMERA");
    bool on = debug.s3cam;
    note("The camera reacts to your jumps, landings, tricks, manuals and grinds. Adjust the settings to get the camera feel you like.");
    if (toggle_row(draft.menu, "Dynamic Camera",
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
    begin_card(draft.menu, "s3cam-camera", "CAMERA", "Choose the camera mode and set its position");
    int chosen_style = draft.next.preset == dingosdk::s3cam::CameraPreset::NativePlus ? 1 : 0;
    if (pick(draft, draft.next_changed, "Style", "s3cam-style", chosen_style, {"Full", "Native+"}, true,
            {"Full uses the S3 camera for the full view.",
             "Native+ keeps the game's camera and adds S3 air, landing, and shake effects."}))
        draft.next.preset = chosen_style == 1 ? dingosdk::s3cam::CameraPreset::NativePlus : dingosdk::s3cam::CameraPreset::FullS3;

    int height = draft.next.angle == dingosdk::s3cam::CameraAngle::High ? 1 : 0;
    if (pick(draft, draft.next_changed, "Active camera", "s3cam-height", height, {"Low", "High"}, true,
            {"The camera sits low, close to the ground.", "The camera sits higher and looks down more."}))
        draft.next.angle = height == 1 ? dingosdk::s3cam::CameraAngle::High : dingosdk::s3cam::CameraAngle::Low;

    toggle(draft, draft.chosen_changed, "Switch Low/High with R3",
        "Pressing the game's camera button (R3) switches between Low and High, also during bails.", draft.chosen.follow_game_height);
    end_card();
}

// The Low / High switch shared by the position, manual and grind cards (the one the player last chose).
void camera_for_switch(Draft& draft, PageState& state, const char* label, const char* id, const char* low_tip, const char* high_tip) {
    if (state.position_for < 0) state.position_for = draft.next.angle == dingosdk::s3cam::CameraAngle::High ? 1 : 0;
    pick(draft, draft.next_changed, label, id, state.position_for, {"Low", "High"}, true, {low_tip, high_tip});
}

dingosdk::s3cam::FramingSettings& framing_for(Draft& draft, const PageState& state) {
    return state.position_for == 1 ? draft.next.framing_high : draft.next.framing;
}

// Where the camera sits, kept separately for Low and High.
void camera_position_card(Draft& draft, PageState& state) {
    begin_card(draft.menu, "s3cam-position", "CAMERA POSITION");
    camera_for_switch(draft, state, "Set position for", "s3cam-position-for", "Edit where the Low camera sits.",
        "Edit where the High camera sits.");
    auto& framing = framing_for(draft, state);
    set_slider(draft, "Distance", "How far behind the skater the camera sits. Higher: further back. Lower: closer. 1x is normal.",
        framing.distance_scale, 0.2f, 3.0f, "%.2fx");
    set_slider(draft, "Height", "Changes how high the camera sits. Higher: further above you, looking down. Lower: closer to the ground.",
        framing.height_degrees, -30.0f, 45.0f, "%.1f degrees");
    set_slider(draft, "Look up / down", "Changes where the camera points without moving its position. Higher: more sky. Lower: more ground.",
        framing.pitch_degrees, -30.0f, 30.0f, "%.1f degrees");
    end_card();
}

// One pair of limits for both cameras (not under the Low / High switch). valid() needs max >= min + 0.2,
// so each slider stops 0.2 m short of the other.
void distance_limits_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-distance-limits", "CAMERA DISTANCE LIMITS", "Main camera, both Low and High");
    auto& distance = draft.next.distance;
    set_slider(draft, "Minimum camera distance",
        "Higher: the camera always stays further away from you, even near walls. Lower: it can come in closer. Manual and grind close-ups use their own distances.",
        distance.min, 0.2f, std::min(5.0f, distance.max - 0.2f), "%.2f m");
    set_slider(draft, "Maximum camera distance",
        "Higher: the camera can pull further back. Lower: it never goes further back than this.",
        distance.max, std::max(0.5f, distance.min + 0.2f), 20.0f, "%.2f m");
    end_card();
}

// The collision switches; the hand-set values are in ADVANCED (manual_collision_card).
void collision_card(Draft& draft) {
    auto& collision = draft.next.collision;
    begin_card(draft.menu, "s3cam-collision", "CAMERA COLLISION", "Walls, poles and the ground");
    set_toggle(draft, "Camera collision", "The camera moves in front of walls instead of going through them.", collision.enabled);
    ImGui::BeginDisabled(!collision.enabled);
    set_toggle(draft, "Automatic collision",
        "On: the camera handles walls and the ground by itself, and lets thin things like poles and rails pass. Off: the hand-set values in ADVANCED are used (for testing).",
        collision.automatic);
    ImGui::EndDisabled();
    end_card();
}

// ---- FOLLOW & MOVEMENT ----

void follow_card(Draft& draft) {
    auto& follow = draft.next.follow;
    begin_card(draft.menu, "s3cam-follow", "FOLLOW", "Adjust how the camera follows your riding and the terrain");
    set_slider(draft, "Camera follow lag",
        "Controls how far the camera lags behind the skater. Higher: it stays right behind you with little lag. Lower: it lags and trails further back. 1x is normal.",
        follow.strength, 0.2f, 4.0f, "%.2fx");
    set_slider(draft, "Follow your turning",
        "Controls how strongly the camera turns with your direction. 0: off, the normal lazy swing. 10 locks it to your direction: flat tricks, reverts and spins do not turn it, carving turns it with you.",
        follow.horizontal, 0.0f, 10.0f, "%.1f");
    set_toggle(draft, "Reduce follow lag at high speed", "The faster you go, the less the camera lags behind you.", follow.dynamic);
    ImGui::BeginDisabled(!follow.dynamic);
    set_slider(draft, "Full follow effect at speed", "Higher: you must go faster to get the least lag. Lower: you get it at lower speeds.",
        follow.dynamic_speed, 0.5f, 60.0f, "%.1f m/s");
    set_slider(draft, "Extra follow effect", "Higher: the camera lags even less at speed. Lower: it changes less.", follow.dynamic_boost, 0.0f, 3.0f, "+%.2f");
    ImGui::EndDisabled();
    end_card();
}

void shoulder_card(Draft& draft) {
    namespace sh = dingosdk::s3cam;
    auto& shoulder = draft.next.shoulder;
    begin_card(draft.menu, "s3cam-shoulder", "SHOULDER CAMERA");
    int mode = shoulder.mode == sh::ShoulderSide::Manual ? 1 : shoulder.mode == sh::ShoulderSide::Auto ? 2 : 0;
    if (pick(draft, draft.next_changed, "Shoulder", "s3cam-shoulder-mode", mode, {"Off", "Manual", "Auto"}, true,
            {"You stay in the middle of the screen.", "You pick the side below.",
             "The camera sits on the toe side of your stance."}))
        shoulder.mode = mode == 1 ? sh::ShoulderSide::Manual : mode == 2 ? sh::ShoulderSide::Auto : sh::ShoulderSide::Off;
    int camera_side = shoulder.side == 1 ? 1 : 0;
    if (pick(draft, draft.next_changed, "Shoulder side", "s3cam-shoulder-side", camera_side, {"Left", "Right"},
            shoulder.mode == sh::ShoulderSide::Manual,
            {"The camera sits to your left, so you are right of the screen centre. Used when Shoulder is Manual.",
             "The camera sits to your right, so you are left of the screen centre. Used when Shoulder is Manual."}))
        shoulder.side = camera_side == 1 ? 1 : -1;
    int stance = shoulder.goofy ? 1 : 0;
    if (pick(draft, draft.next_changed, "Auto shoulder stance", "s3cam-shoulder-stance", stance, {"Regular", "Goofy"},
            shoulder.mode == sh::ShoulderSide::Auto,
            {"Regular rides with the toes to the right; riding switch flips it. Used when Shoulder is Auto.",
             "Goofy rides with the toes to the left. Used when Shoulder is Auto."}))
        shoulder.goofy = stance == 1;
    ImGui::BeginDisabled(shoulder.mode == sh::ShoulderSide::Off);
    set_slider(draft, "Side offset", "Higher: you sit further to the side of the screen. Lower: closer to the middle.", shoulder.offset, 0.0f, 3.0f, "%.2f m");
    set_slider(draft, "Shoulder side-change time", "Higher: the camera slides across slowly. Lower: it slides across quickly.", shoulder.switch_time, 0.0f,
        5.0f, "%.2f s");
    ImGui::EndDisabled();
    note("L3 swaps the side when it is bound in Controls > Binds.");
    end_card();
}

void slope_card(Draft& draft) {
    auto& look = draft.next.look;
    begin_card(draft.menu, "s3cam-slope", "SLOPE CAMERA");
    set_toggle(draft, "Follow the slope", "On the ground, the view tips down going downhill and up going uphill.",
        look.slope_look);
    ImGui::BeginDisabled(!look.slope_look);
    set_slider(draft, "Slope follow strength", "Higher: the view tips more on hills. Lower: it stays more level.", look.slope_look_strength, 0.0f, 1.0f,
        "%.2f");
    ImGui::EndDisabled();
    // LookSettings::response_time: one value, also used by the landing look, a change of Look up / down and the
    // manual / grind focus (s3_camera.h).
    set_slider(draft, "Camera tilt transition time",
        "How quickly the view's up and down tilt settles. Also controls how quickly the landing look tilts, and how quickly a change of Look up / down or of the manual / grind focus settles. Higher: slower. Lower: right away.",
        look.response_time, 0.0f, 5.0f, "%.2f s");
    end_card();
}

// ---- TRICKS & CLOSE-UPS ----

void trick_turn_card(Draft& draft) {
    auto& yaw = draft.next.trick_yaw;
    begin_card(draft.menu, "s3cam-trick-yaw", "TRICK CAMERA TURN", "Set camera turns during tricks and closer views for manuals and grinds");
    note("The camera swings round to show the trick, holds that angle while you keep tricking, and comes back behind you after landing.");
    set_toggle(draft, "Turn camera during tricks", "Swing the camera round to the side during tricks.", yaw.enabled);
    ImGui::BeginDisabled(!yaw.enabled);
    set_slider(draft, "Trick turn angle", "Higher: the camera swings round further to the side. Lower: it stays closer behind you.", yaw.angle_degrees, 0.0f, 90.0f, "%.0f degrees");
    int side = yaw.side < 0 ? 1 : yaw.side > 0 ? 2 : 0;
    if (pick(draft, draft.next_changed, "Trick turn direction", "s3cam-trick-yaw-side", side, {"Auto", "Left", "Right"}, true,
            {"Follows the shoulder side, or your stance if the shoulder is off.", "The camera swings round to your left.",
             "The camera swings round to your right."}))
        yaw.side = side == 1 ? -1 : side == 2 ? 1 : 0;
    set_toggle(draft, "Turn during air tricks", "Turn during airs and flip tricks.", yaw.in_air);
    set_toggle(draft, "Turn during grinds", "Turn while grinding.", yaw.on_grinds);
    set_toggle(draft, "Turn during manuals", "Turn while manualling.", yaw.on_manuals);
    set_slider(draft, "Minimum air time before turning",
        "Higher: you must be in the air longer before the camera turns, so a plain ollie stays centred. Lower: it turns sooner.",
        yaw.min_air_time, 0.0f, 3.0f, "%.2f s");
    set_slider(draft, "Time to turn", "Higher: the camera swings out slowly. Lower: it swings out quickly.", yaw.in_time, 0.0f, 5.0f, "%.2f s");
    set_slider(draft, "Hold trick camera angle for", "Higher: the camera stays turned longer after the trick. Lower: it comes back sooner. A new trick keeps the angle.",
        yaw.hold_time, 0.0f, 5.0f, "%.2f s");
    set_slider(draft, "Time to return to normal view", "Higher: the camera is slower to come back behind you. Lower: it comes back quicker.",
        yaw.return_time, 0.0f, 10.0f, "%.2f s");
    ImGui::EndDisabled();
    end_card();
}

// The manual and grind close-ups are kept separately for the Low and the High camera. They share the
// "Set position for" choice with the CAMERA tab, so the switch reads the same on both tabs.
void manual_card(Draft& draft, PageState& state) {
    begin_card(draft.menu, "s3cam-manual", "MANUAL CAMERA");
    camera_for_switch(draft, state, "Set manual for", "s3cam-manual-for", "Edit the manual close-up of the Low camera.",
        "Edit the manual close-up of the High camera.");
    auto& framing = framing_for(draft, state);
    set_toggle(draft, "Move closer during manuals", "On: the camera moves in close for manuals and nose manuals. Off: it keeps its normal distance.",
        framing.manual_camera);
    ImGui::BeginDisabled(!framing.manual_camera);
    set_slider(draft, "Distance", "How far back the camera sits in a manual. Its own value: the main camera's distance and limits do not change it.",
        framing.manual_distance, s3cam::closeup_min_distance, 8.0f, "%.2f m");
    set_slider(draft, "Height", "Higher: the camera sits further above you in a manual. Lower: closer to the ground. Its own value, not added to the main height.",
        framing.manual_height_degrees, -30.0f, 45.0f, "%.1f degrees");
    set_slider(draft, "Look up / down", "Where the view points in a manual. Higher: up. Lower: down. Its own value.",
        framing.manual_pitch_degrees, -30.0f, 30.0f, "%.1f degrees");
    ImGui::EndDisabled();
    set_slider(draft, "Manual camera focus", "0: the camera looks at the board. 1: it looks at your upper body.",
        draft.next.look.manual_focus, 0.0f, 1.0f, "%.2f");
    end_card();
}

void grind_card(Draft& draft, PageState& state) {
    begin_card(draft.menu, "s3cam-grind", "GRIND CAMERA");
    camera_for_switch(draft, state, "Set grind for", "s3cam-grind-for", "Edit the grind close-up of the Low camera.",
        "Edit the grind close-up of the High camera.");
    auto& framing = framing_for(draft, state);
    set_toggle(draft, "Move closer during grinds", "On: grinds use their own close-up view. Off: the camera keeps its normal view.",
        framing.grind_camera);
    ImGui::BeginDisabled(!framing.grind_camera);
    set_slider(draft, "Distance", "How far back the camera sits in a grind. Its own value: the main camera's distance and limits do not change it.",
        framing.grind_distance, s3cam::closeup_min_distance, 8.0f, "%.2f m");
    set_slider(draft, "Height", "Higher: the camera sits further above you in a grind. Lower: closer to the ground. Its own value, not added to the main height.",
        framing.grind_height_degrees, -30.0f, 45.0f, "%.1f degrees");
    set_slider(draft, "Look up / down", "Where the view points in a grind. Higher: up. Lower: down. Its own value.",
        framing.grind_pitch_degrees, -30.0f, 30.0f, "%.1f degrees");
    ImGui::EndDisabled();
    set_slider(draft, "Grind camera focus", "0: the camera looks at the board. 1: it looks at your upper body.",
        draft.next.look.grind_focus, 0.0f, 1.0f, "%.2f");
    end_card();
}

// One value each for manuals and grinds (LookSettings::board_anchor, closeup_exit_time), so shown once.
void closeup_shared_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-closeup-shared", "SHARED CLOSE-UP SETTINGS", "Manuals and grinds");
    set_toggle(draft, "Follow the board",
        "On: in manuals and grinds the camera circles and aims at your board. Off: it aims at your body as usual.",
        draft.next.look.board_anchor);
    set_slider(draft, "Close-up return time",
        "How long the camera takes to move back out after a manual or grind ends (a trick, or riding off). Higher: slower and smoother. Lower: quicker and snappier.",
        draft.next.look.closeup_exit_time, 0.2f, 3.0f, "%.2f s");
    end_card();
}

// ---- AIR & LANDING ----

void big_air_card(Draft& draft) {
    auto& air = draft.next.air_camera;
    begin_card(draft.menu, "s3cam-big-air", "BIG AIR", "Control camera movement and aim while jumping and landing");
    set_toggle(draft, "Keep skater in view during jumps", "Turns the camera so you do not leave the screen while you are in the air.", air.keep_in_frame);
    set_slider(draft, "Follow jump height",
        "Higher: the camera rises more with you in a big air. Lower: it stays near the height you took off from.",
        air.follow_height, 0.0f, 1.0f, "%.2f");
    set_slider(draft, "Camera rise during big airs",
        "Higher: in a big air the camera swings further up over you and looks down at the landing. Lower: it stays behind you.", air.rise_degrees, 0.0f, 60.0f,
        "%.0f degrees");
    set_slider(draft, "Full camera rise at jump height", "Higher: only very big jumps or drops get the full rise. Lower: even small ones do.",
        air.rise_full_height, 0.1f, 20.0f, "%.1f m");
    set_slider(draft, "Camera rise transition time", "Higher: the rise builds and settles back more slowly. Lower: it reacts faster.", air.ease_time, 0.0f, 3.0f, "%.2f s");
    end_card();
}

void landing_view_card(Draft& draft) {
    auto& look = draft.next.look;
    begin_card(draft.menu, "s3cam-landing-view", "LANDING VIEW");
    set_toggle(draft, "Look down toward landings",
        "When you jump down to something lower (stairs, gaps), the camera tips down to show where you will land.",
        look.landing_look);
    ImGui::BeginDisabled(!look.landing_look);
    set_slider(draft, "Landing look strength", "Higher: the camera tips down more toward the landing. Lower: it tips less.", look.landing_look_strength, 0.0f, 1.0f,
        "%.2f");
    set_slider(draft, "Full landing look at drop height", "Higher: the landing must be much lower than where you took off for the full tip. Lower: a small drop is enough.",
        look.landing_look_full_drop, 0.5f, 10.0f, "%.1f m"); // valid() allows 0.1-50: the slider keeps the useful part
    ImGui::EndDisabled();
    set_slider(draft, "Follow height while airborne", "Higher: the view follows you up and down as you jump (every jump, not just landings). 0: it stays level.",
        look.vertical_follow, 0.0f, 1.0f, "%.2f");
    note("How quickly the landing look tilts is Camera tilt transition time, in FOLLOW & MOVEMENT.");
    end_card();
}

// ---- CAMERA EFFECTS ----

// Every shake control in one card. Camera shake is the master switch for all of it, landing shake included.
void shake_card(Draft& draft) {
    auto& camera = draft.next;
    begin_card(draft.menu, "s3cam-shake", "CAMERA SHAKE", "Adjust camera shake, landing bounce, and field of view");
    set_toggle(draft, "Camera shake", "Turns camera shake effects on or off: speed, downhill and landing shake.", camera.shake_enabled);
    ImGui::BeginDisabled(!camera.shake_enabled);
    set_toggle(draft, "Speed shake", "The camera rumbles more the faster you go.", camera.speed_shake.enabled);
    ImGui::BeginDisabled(!camera.speed_shake.enabled);
    set_slider(draft, "Speed shake strength", "Higher: a stronger rumble at speed. Lower: a gentler one. 0: none.", camera.speed_shake.strength, 0.0f, 10.0f, "%.2fx");
    set_slider(draft, "Full speed shake at", "Higher: you must go faster for the strongest rumble. Lower: it peaks at lower speeds.", camera.speed_shake.top_speed, 0.5f, 80.0f,
        "%.1f m/s");
    set_toggle(draft, "Extra shake downhill", "More rumble riding downhill.", camera.speed_shake.downhill_boost);
    ImGui::BeginDisabled(!camera.speed_shake.downhill_boost);
    set_slider(draft, "Downhill shake strength", "Higher: the rumble gets much stronger on a steep downhill. Lower: only a little.",
        camera.speed_shake.downhill_scale, 1.0f, 10.0f, "%.2fx");
    set_slider(draft, "Full downhill shake at slope", "Higher: the hill must be steeper for the full extra rumble. Lower: a gentle hill is enough.",
        camera.speed_shake.downhill_full_degrees, 1.0f, 80.0f, "%.0f degrees");
    ImGui::EndDisabled();
    ImGui::EndDisabled();
    auto& landing = draft.next.landing_shake;
    set_slider(draft, "Landing shake strength", "Higher: the camera kicks harder when you land. Lower: gentler. 0: no kick.", draft.next.shake.one_shot_magnitude,
        0.0f, 10.0f, "%.2f");
    // valid() needs full_fall > min_fall, so each slider stops short of the other.
    set_slider(draft, "Light landing threshold",
        "Landings that fell less than this do not shake the camera. Higher: more landings count as light. Lower: even small drops shake it.", landing.min_fall,
        0.0f, std::min(10.0f, landing.full_fall - 0.1f), "%.1f m");
    set_slider(draft, "Full landing shake at drop height",
        "Higher: you must fall further for the strongest shake. Lower: smaller falls shake fully.", landing.full_fall,
        std::max(0.5f, landing.min_fall + 0.1f), 10.0f, "%.1f m"); // 0.5-10 m keeps the slider linear
    set_slider(draft, "Extra landing shake from speed",
        "Higher: riding fast makes landings shake harder. 0: only how far you fell counts.", landing.speed_weight, 0.0f, 1.0f,
        "%.2f");
    ImGui::EndDisabled();
    end_card();
}

void landing_bounce_card(Draft& draft) {
    auto& plus = draft.next.native_plus;
    begin_card(draft.menu, "s3cam-landing-bounce", "LANDING BOUNCE");
    note("Used by the Native+ style.");
    set_toggle(draft, "Landing bounce", "The camera dips down a little when you land and springs back.", plus.landing_dip);
    ImGui::BeginDisabled(!plus.landing_dip);
    set_slider(draft, "Bounce depth", "Higher: the camera dips further after a hard landing. Lower: a smaller dip.", plus.dip_depth, 0.0f, 2.0f, "%.2f m");
    set_slider(draft, "Bounce duration", "Higher: the dip is slower. Lower: it is quicker.", plus.dip_peak_time, 0.02f, 2.0f,
        "%.2f s");
    ImGui::EndDisabled();
    end_card();
}

void fov_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-fov", "FIELD OF VIEW");
    toggle(draft, draft.chosen_changed, "Override game field of view",
        "On: this camera sets how wide the view is. Required for speed-based and big-air FOV widening. Off: the game's own width.",
        draft.chosen.shot_fov);
    ImGui::BeginDisabled(!draft.chosen.shot_fov);
    field(draft.menu, "Base field of view", "Higher: a wider view that shows more around you. Lower: a narrower, more zoomed-in view. Game's own keeps the game's width.");
    int degrees = static_cast<int>(std::lround(draft.next.fov_override_deg));
    if (ImGui::SliderInt("##s3cam-fov-override", &degrees, 0, 120, degrees > 0 ? "%d degrees" : "Game's own",
            ImGuiSliderFlags_AlwaysClamp)) {
        // The console accepts 0 or 30-120; the slider jumps over the gap.
        if (degrees > 0 && degrees < 30) degrees = degrees < 15 ? 0 : 30;
        draft.next.fov_override_deg = static_cast<float>(degrees);
        draft.next_changed = true;
    }
    ImGui::EndDisabled();
    set_slider(draft, "FOV transition time", "Higher: the view width changes slowly. Lower: it changes quickly.", draft.next.fov.smoothing_time,
        0.0f, 5.0f, "%.2f s");
    end_card();
}

void speed_fov_card(Draft& draft) {
    auto& fov = draft.next.fov;
    begin_card(draft.menu, "s3cam-speed-fov", "SPEED FOV");
    if (!draft.chosen.shot_fov) note("Turn on Override game field of view above to use this.");
    ImGui::BeginDisabled(!draft.chosen.shot_fov);
    set_toggle(draft, "Widen view at high speed", "The faster you go, the wider the view opens up.", fov.speed_fov);
    ImGui::BeginDisabled(!fov.speed_fov);
    set_slider(draft, "Extra view angle at speed", "Higher: the view opens up wider at speed. Lower: it changes less.", fov.speed_fov_degrees, 0.0f, 40.0f,
        "+%.1f degrees");
    set_slider(draft, "Start widening at speed", "Higher: you must go faster before the view starts to widen. Lower: it starts at lower speeds.", fov.speed_fov_min, 0.0f,
        std::min(60.0f, fov.speed_fov_max - 0.1f), "%.1f m/s");
    set_slider(draft, "Full view widening at speed", "Higher: the view is widest at a higher speed. Lower: at a lower speed.", fov.speed_fov_max,
        std::max(0.1f, fov.speed_fov_min + 0.1f), 80.0f, "%.1f m/s");
    ImGui::EndDisabled();
    ImGui::EndDisabled();
    end_card();
}

void big_air_fov_card(Draft& draft) {
    auto& fov = draft.next.fov;
    begin_card(draft.menu, "s3cam-air-fov", "BIG-AIR FOV");
    if (!draft.chosen.shot_fov) note("Turn on Override game field of view above to use this.");
    ImGui::BeginDisabled(!draft.chosen.shot_fov);
    set_toggle(draft, "Widen view during big airs", "The view opens up wider in a big air.", fov.air_fov);
    ImGui::BeginDisabled(!fov.air_fov);
    set_slider(draft, "Extra view angle in big airs", "Higher: the view opens up wider in a big air. Lower: it changes less.", fov.air_fov_degrees, 0.0f, 40.0f,
        "+%.1f degrees");
    set_slider(draft, "Full view widening at jump height", "Higher: only very big jumps open the view fully. Lower: smaller jumps do too.", fov.air_fov_full_height, 0.1f, 50.0f,
        "%.1f m");
    ImGui::EndDisabled();
    ImGui::EndDisabled();
    end_card();
}

// ---- ADVANCED ----

void native_plus_card(Draft& draft) {
    auto& plus = draft.next.native_plus;
    begin_card(draft.menu, "s3cam-native-plus", "NATIVE+ EXTRAS", "Less commonly changed settings and manual controls");
    note("Only for the Native+ style.");
    set_toggle(draft, "Hold height in the air", "On: the camera stays at the same height while you are in the air.", plus.air_hold);
    set_toggle(draft, "Shake", "On: landing and speed shake on the game's camera. Its own switch, separate from Camera shake in CAMERA EFFECTS.", plus.shake);
    set_toggle(draft, "Lean", "On: the camera leans a little with the shot and the shake.", plus.roll);
    end_card();
}

// The hand-set collision values; greyed out while Automatic collision (CAMERA tab) is on, or collision is off.
void manual_collision_card(Draft& draft) {
    auto& collision = draft.next.collision;
    begin_card(draft.menu, "s3cam-collision-manual", "MANUAL COLLISION SETTINGS");
    if (collision.automatic) note("Used when Automatic collision is off (CAMERA tab).");
    ImGui::BeginDisabled(!collision.enabled || collision.automatic);
    set_slider(draft, "Wall gap", "Higher: the camera stays further from walls. Lower: it can get right up to them.", collision.radius, 0.0f, 2.0f, "%.2f m");
    set_slider(draft, "Move-in time", "Higher: the camera moves in front of a wall slowly. Lower: it moves in at once.", collision.pull_in_time, 0.0f, 2.0f,
        "%.2f s");
    set_slider(draft, "Move-out time", "Higher: the camera returns slowly once the wall is gone. Lower: it returns quickly.", collision.release_time, 0.0f,
        5.0f, "%.2f s");
    set_slider(draft, "Ground gap", "Higher: the camera stays further above the ground. Lower: it can sit closer to the ground.", collision.ground_clearance, 0.0f, 3.0f,
        "%.2f m");
    ImGui::EndDisabled();
    end_card();
}

void transitions_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-blend", "CAMERA TRANSITIONS");
    slider(draft, draft.chosen_changed, "Transition time when mounting",
        "Higher: the switch to this camera takes longer when you get on the board. 0: it cuts at once.",
        draft.chosen.take_blend_time, 0.0f, 5.0f, "%.2f s");
    slider(draft, draft.chosen_changed, "Transition time when dismounting",
        "Higher: the switch back to the game's camera takes longer when you get off the board. 0: it cuts at once.",
        draft.chosen.release_blend_time, 0.0f, 5.0f, "%.2f s");
    end_card();
}

void other_card(Draft& draft) {
    begin_card(draft.menu, "s3cam-other", "OTHER");
    toggle(draft, draft.chosen_changed, "Logging", "Write what the camera is doing, and every landing, to ReSkate.log.",
        draft.chosen.verbose);
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

// When the preset card next scans the folder (ImGui time); 0 = on its next frame.
double preset_scan_at = 0.0;

void presets_card(Draft& draft, PresetPage& page) {
    // Presets dropped into the folder show up by themselves: the folder is scanned every 2 s while this card shows,
    // here only, before the list is read below (a scan replaces the list).
    if (const double now = ImGui::GetTime(); now >= preset_scan_at) {
        preset_scan_at = now + 2.0;
        glue::s3cam_presets_refresh();
    }
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

    begin_card(draft.menu, "s3cam-presets", "PRESETS", "Save, load, and manage camera setups");
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
    note("To add a preset, put its .json file in the preset folder: it appears in the list by itself.");
    auto row = begin_row(2);
    if (cell(row, "Open preset folder", true, "Show the preset folder in Explorer. Drop .json preset files there to add them; copy them out to share them."))
        answer(glue::s3cam_presets_open_folder(), false);
    if (cell(row, "Refresh preset list", true, "Scan the folder again now (it also happens by itself every 2 seconds).")) {
        preset_scan_at = 0.0; // the next frame
        page.result = "Preset list refreshed.";
        page.result_ok = true;
    }

    const bool have = !page.selected.empty();
    const bool saved = chosen && !chosen->built_in;
    if (double_clicked) {
        answer(glue::s3cam_preset_load(page.selected), false);
        draft.next_changed = draft.chosen_changed = false; // this frame's edits would undo the load
    }

    row = begin_row(2);
    if (cell(row, "Load", have, "Apply the selected preset to the camera. Dynamic Camera stays on or off as it is. Double-click does the same.")) {
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
    if (cell(row, "Copy to clipboard", have, "Copy the selected preset's text to the clipboard, to paste it in a chat. Sharing the file from the preset folder works too.")) {
        const auto result = glue::s3cam_preset_export(page.selected);
        if (result.ok) ImGui::SetClipboardText(result.text.c_str());
        answer(result, false);
    }
    if (cell(row, "Paste from clipboard", true, "Add a preset from text someone shared with you (copy the text first). Or put the .json file in the preset folder.")) {
        const char* pasted = ImGui::GetClipboardText();
        answer(glue::s3cam_preset_import(pasted ? pasted : ""), true);
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
        feedback(draft.menu, "Dynamic Camera settings are back to their defaults.");
        draft.next_changed = draft.chosen_changed = false; // this frame's edits would undo the reset
    }
    end_card();
}
}

void s3cam_page(SkateMenu& menu, const Model& model, const CallbacksV3& callbacks) {
    Draft draft(menu, glue::s3cam_settings(), glue::s3cam_options());
    auto& state = page_state();
    s3cam_card(draft, model, callbacks);
    category_tabs(menu, state.tab, {"PRESETS", "CAMERA", "FOLLOW & MOVEMENT", "TRICKS & CLOSE-UPS", "AIR & LANDING", "CAMERA EFFECTS", "ADVANCED"},
        "s3cam-tabs");
    ImGui::PushID(state.tab);
    ImGui::BeginChild("s3cam-tab", ImVec2(0, page_body_height(menu)));
    switch (state.tab) {
    case 0: {
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
    case 1:
        camera_card(draft);
        camera_position_card(draft, state);
        distance_limits_card(draft);
        collision_card(draft);
        break;
    case 2:
        follow_card(draft);
        shoulder_card(draft);
        slope_card(draft);
        break;
    case 3:
        trick_turn_card(draft);
        manual_card(draft, state);
        grind_card(draft, state);
        closeup_shared_card(draft);
        break;
    case 4:
        big_air_card(draft);
        landing_view_card(draft);
        break;
    case 5:
        shake_card(draft);
        landing_bounce_card(draft);
        fov_card(draft);
        speed_fov_card(draft);
        big_air_fov_card(draft);
        break;
    default:
        native_plus_card(draft);
        manual_collision_card(draft);
        transitions_card(draft);
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
