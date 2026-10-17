#include "s3cam_config.h"
#include "s3cam.h"
#include "s3cam_preset_format.h"
#include "Engine/Core/Json/json.h"
#include "Engine/Core/Log/logging.h"
#include "Extension/Profile/local_profile_runtime.h"
#include <optional>
#include <string>
#include <utility>
#include <vector>

// The field table, the text choices and the load / save passes live in s3cam_preset_format.h, shared
// with the presets (s3cam_presets.cpp); this file only supplies the profile as the source of values.
namespace dingosdk::client_source::detail {
namespace {
using logging::Channel;
using logging::Level;
namespace cfgcam = dingosdk::s3cam;
namespace format = dingosdk::s3cam_format;

// The saved values of the profile's ReSkate store.
struct ProfileSource {
    std::optional<Json> operator()(const char* key) const noexcept { return profile_runtime::local_value(key); }
};
} // namespace

void s3cam_config_load() noexcept {
    try {
        auto camera = s3cam_settings();
        auto options = s3cam_options();
        ProfileSource source;
        const auto report = format::load_values(source, camera, options);

        format::drop_invalid_groups(camera);
        if (!s3cam_set_settings(camera)) {
            logging::log(Level::warning, Channel::skater, "s3cam: the saved settings are not valid together; keeping the defaults.");
            return;
        }
        s3cam_set_options(options);
        if (report.refused)
            logging::log(Level::warning, Channel::skater,
                "s3cam: {} saved value(s) were out of range or of the wrong type and keep their defaults (first: {}).",
                report.refused, report.first_refused);
    } catch (...) { /* Unreadable choices leave the current values in place. */ }
}

void s3cam_config_save() noexcept {
    try {
        profile_runtime::set_local_values(format::collect_values(s3cam_settings(), s3cam_options()));
    } catch (...) { /* Saving is best effort; the choices already apply. */ }
}

void s3cam_config_reset() noexcept {
    (void)s3cam_set_settings(cfgcam::CameraSettings{});
    s3cam_set_options(S3CamOptions{});
}
}
