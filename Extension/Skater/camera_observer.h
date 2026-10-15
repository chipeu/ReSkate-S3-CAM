#pragma once
#include <cstdint>

namespace dingosdk {
// Caller validates the executable and initializes Detours hook service before starting.
// Keep this module and its trampoline loaded while any detour can run.
bool start_camera_observer(std::uintptr_t image_base) noexcept;
void camera_tick_enter(std::uintptr_t client) noexcept;
void camera_tick_native_return() noexcept;
void camera_tick_leave() noexcept;
// A bounded observation gate, not a native lifetime/concurrency lock. Requires
// the current outer post-tick phase and a completed same-thread/context sample
// since the last observed overlap, with its ownership chain revalidated now.
bool camera_probe_phase_observed(std::uintptr_t context) noexcept;
// Called right after each native camera update from the verified native caller returns, on that
// thread and before the caller uses the update's output, with the game camera it evaluated
// (engine::camera_vtable; evaluator +0x138) and the caller's output buffer (layout unknown; read
// and written only through guarded copies). One listener at a time; null removes it. S3Cam
// spikes S1c/S1d (Extension/Camera/s3cam_probe.h).
using CameraUpdatedListener = void (*)(std::uintptr_t camera, std::uintptr_t output) noexcept;
void set_camera_updated_listener(CameraUpdatedListener listener) noexcept;
// Null means ready. A new isolated local callback can recover after overlap.
const char* camera_probe_unavailable_reason(std::uintptr_t context) noexcept;
}
