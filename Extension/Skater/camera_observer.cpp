#include "camera_observer.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Build/supported_build.h"
#include "Engine/Game/Build/addresses.h"
#include "Engine/Game/Build/20260929/camera_observer.h"
#include "Engine/Game/Build/20260929/engine.h"
#include <Windows.h>
#include "Engine/Core/Hooks/hooks.h"
#include <array>
#include <atomic>
#include <intrin.h>
#include <mutex>

namespace dingosdk {
namespace {
using CameraCallback = void (*)(std::uintptr_t, std::uintptr_t, std::uintptr_t);
namespace camera_addresses = addr::camera_observer;
constexpr std::uintptr_t camera_rva = camera_addresses::camera_callback, camera_image_size = supported_build::game_image_size;
constexpr auto camera_prefix = camera_addresses::camera_callback_prefix;
enum class CameraPhase { outside, native, post, overflow };
struct CameraError {
    DWORD value{GetLastError()};
    ~CameraError() { SetLastError(value); }
};
bool camera_range(std::uintptr_t address, std::size_t size) {
    return address >= 0x10000 && size && size <= memory::highest_user_address &&
        address <= memory::highest_user_address - size;
}
bool camera_object(std::uintptr_t address) { return camera_range(address, 8) && !(address & 7); }
struct CameraTickFrame { std::uintptr_t client{}; CameraPhase phase{CameraPhase::native}; };
struct CameraThread {
    std::array<CameraTickFrame, 32> frames{};
    std::uint32_t depth{}, overflow{}, callbacks{}, native_scopes{}, post_scopes{};
};
thread_local CameraThread camera_thread;
struct CameraIdentity {
    bool available{}, tls_available{}, helper_available{}, entry_backlink{}, helper_backlink{};
    bool helper_type_matches{}, evaluator_available{}, evaluator_context_matches{}, camera_backlink{}, selected_entry{};
    std::uintptr_t callback{}, entry{}, helper{}, graph{}, entry_context{}, tls_context{};
    std::uintptr_t evaluator{}, evaluator_context{}, camera{};
    std::array<bool, 3> helper_present{};
};
struct CameraSample {
    std::uint64_t id{}, before_at{}, generation{};
    DWORD thread{};
    CameraPhase phase{CameraPhase::outside};
    bool ended{}, returned{}, same_identity{}, known_caller{}, isolated{};
    CameraIdentity before, after;
};
// Readiness belongs to the current native thread and its latest verified sample.
thread_local CameraSample camera_local_sample;
struct CameraObserver {
    std::uintptr_t base{};
    std::atomic<CameraCallback> original{};
    std::atomic<bool> active{};
    std::mutex initialization;
    bool attempted{};
    std::atomic<std::uint64_t> calls{}, callbacks_active{}, native_active{}, post_active{};
    std::atomic<std::uint64_t> observation_generation{};
};
CameraObserver& camera_state() { static auto* state = new CameraObserver; return *state; }
std::atomic<CameraUpdatedListener> camera_updated_listener{};
CameraPhase camera_current_phase() noexcept {
    if (camera_thread.overflow) return CameraPhase::overflow;
    return camera_thread.depth ? camera_thread.frames[camera_thread.depth - 1].phase : CameraPhase::outside;
}
// The identity reads below run in the camera callback and in every tick's phase
// check: guarded same-process copies, not a system call per field.
std::uintptr_t camera_entry_identity(std::uintptr_t base, std::uintptr_t callback) noexcept {
    std::uintptr_t vtable{}, entry{}, entry_vtable{};
    if (!camera_object(callback) || !camera_range(callback, 0x28) || !memory::peek(callback, vtable) ||
        vtable != base + camera_addresses::callback_vtable || !memory::peek(callback + 0x10, entry) || !camera_object(entry) ||
        !memory::peek(entry, entry_vtable)) return 0;
    // Two native constructors create entry variants through the same base
    // constructor (+60 callback, +90 client context). Gameplay switches between
    // them; accepting only the first loses tracking when the alternate becomes
    // selected after a camera/editor transition.
    if (entry_vtable != base + camera_addresses::entry_vtable &&
        entry_vtable != base + camera_addresses::alternate_entry_vtable) return 0;
    return entry;
}
CameraIdentity camera_identity(std::uintptr_t base, std::uintptr_t callback, std::uintptr_t evaluator = 0) noexcept {
    CameraIdentity result; result.callback = callback;
    result.entry = camera_entry_identity(base, callback);
    if (!result.entry || !camera_range(result.entry, 0x98) ||
        !memory::peek(callback + 0x18, result.helper) || !memory::peek(callback + 0x20, result.graph) ||
        !memory::peek(result.entry + 0x90, result.entry_context)) return result;
    std::uintptr_t backlink{};
    result.entry_backlink = memory::peek(result.entry + 0x60, backlink) && backlink == callback;
    if (camera_object(result.helper) && camera_range(result.helper, 0x70)) {
        std::uintptr_t vtable{};
        result.helper_type_matches = memory::peek(result.helper, vtable) && vtable == base + camera_addresses::helper_vtable;
        result.helper_backlink = memory::peek(result.helper + 0x50, backlink) && backlink == callback;
        std::array<std::uintptr_t, 3> values{};
        result.helper_available = memory::peek(result.helper + 0x58, values);
        if (result.helper_available) for (std::size_t i = 0; i < values.size(); ++i) result.helper_present[i] = values[i] != 0;
    }
    // The evaluator comes from input+8 only for the verified native caller.
    // Save numeric identities, never the caller's input/output scratch pointers.
    if (camera_object(evaluator) && camera_range(evaluator, 0x140)) {
        result.evaluator = evaluator;
        std::uintptr_t collection{}, begin{}, end{}, selected{}, vtable{};
        if (memory::peek(evaluator, result.evaluator_context) && camera_object(result.evaluator_context) &&
            memory::peek(evaluator + 0x138, result.camera) && camera_object(result.camera) &&
            camera_range(result.camera, 0x188) && memory::peek(result.camera, vtable) &&
            vtable == base + addr::engine::camera_vtable) {
            result.evaluator_available = true;
            result.evaluator_context_matches = result.evaluator_context == result.entry_context;
            result.camera_backlink = memory::peek(result.camera + 0x180, backlink) && backlink == evaluator;
        }
        if (memory::peek(evaluator + 8, collection) && camera_object(collection) && camera_range(collection, 0x18) &&
            memory::peek(collection, backlink) && backlink == evaluator &&
            memory::peek(collection + 8, begin) && memory::peek(collection + 0x10, end) &&
            camera_object(begin) && end > begin && (end - begin) % 0x10 == 0 && (end - begin) / 0x10 <= 32 &&
            camera_range(begin, end - begin) && memory::peek(end - 0x10, selected) && selected == result.entry) {
            // Reject a header or final selection that changed during this copy.
            std::uintptr_t again{};
            result.selected_entry = memory::peek(evaluator + 8, again) && again == collection &&
                memory::peek(collection + 8, again) && again == begin &&
                memory::peek(collection + 0x10, again) && again == end &&
                memory::peek(end - 0x10, again) && again == selected;
        }
    }
    std::uint32_t index{};
    std::uintptr_t block{};
    unsigned char initialized{};
    const auto array = static_cast<std::uintptr_t>(__readgsqword(0x58));
    if (memory::peek(base + addr::engine::tls_index, index) && index <= 4095 && camera_object(array) &&
        camera_range(array, std::size_t{index} * 8 + 8) && memory::peek(array + std::uintptr_t{index} * 8, block) &&
        camera_object(block) && camera_range(block, 0xb1a) && memory::peek(block + 0xb19, initialized) && initialized &&
        memory::peek(block + 0x550, result.tls_context) && camera_object(result.tls_context)) result.tls_available = true;
    result.available = true;
    return result;
}
bool camera_same_identity(const CameraIdentity& before, const CameraIdentity& after) noexcept {
    return before.available && after.available && before.callback == after.callback &&
        before.entry == after.entry && before.helper == after.helper && before.graph == after.graph &&
        before.entry_context == after.entry_context && before.evaluator == after.evaluator &&
        before.camera == after.camera && before.evaluator_context == after.evaluator_context;
}
bool camera_idle_identity(const CameraIdentity& value, std::uintptr_t context) noexcept {
    return value.available && value.tls_available && value.tls_context == context && value.entry_context == context &&
        value.entry_backlink && value.helper_backlink && value.helper_type_matches && value.evaluator_available &&
        value.evaluator_context_matches && value.camera_backlink && value.selected_entry && value.helper_available &&
        value.helper_present == std::array<bool, 3>{false, false, false};
}
bool camera_isolated_callback(const CameraObserver& state) noexcept {
    return camera_current_phase() == CameraPhase::outside && camera_thread.callbacks == 1 &&
        state.callbacks_active.load() == 1 && !state.native_active.load() && !state.post_active.load();
}
bool camera_begin_sample(CameraObserver& state, CameraSample& sample, std::uint64_t id,
                         std::uintptr_t callback, std::uintptr_t caller, std::uintptr_t time_input) noexcept {
    try {
        // Only the verified native caller can establish readiness.
        if (caller != state.base + camera_addresses::native_caller_return) return false;
        const auto now = GetTickCount64();
        const auto generation = state.observation_generation.load();
        std::uintptr_t evaluator{};
        if (camera_range(time_input, 0x10)) (void)memory::peek(time_input + 8, evaluator);
        const auto& previous = camera_local_sample;
        if (previous.id && previous.generation == generation && previous.before.callback == callback &&
            previous.before.evaluator == evaluator && now - previous.before_at < 500) return false;
        sample = {};
        sample.id = id; sample.before_at = now; sample.thread = GetCurrentThreadId();
        sample.generation = generation; sample.isolated = camera_isolated_callback(state);
        sample.known_caller = true;
        sample.phase = camera_current_phase();
        sample.before = camera_identity(state.base, callback, evaluator);
        return true;
    } catch (...) { return false; }
}
void camera_end_sample(CameraObserver& state, CameraSample& sample, std::uintptr_t callback, bool returned) noexcept {
    try {
        sample.after = camera_identity(state.base, callback, sample.before.evaluator);
        sample.ended = true; sample.returned = returned;
        sample.same_identity = camera_same_identity(sample.before, sample.after);
        sample.isolated = sample.isolated && camera_isolated_callback(state) &&
            sample.generation == state.observation_generation.load();
        if (sample.known_caller && sample.returned && sample.same_identity && sample.isolated &&
            camera_idle_identity(sample.after, sample.after.entry_context)) camera_local_sample = sample;
    } catch (...) {}
}
struct CameraCall {
    CameraObserver& state;
    std::uintptr_t callback;
    std::uint64_t id;
    CameraSample sample;
    bool sampled{}, finished{};
    CameraCall(CameraObserver& value, std::uintptr_t object, std::uintptr_t caller = 0,
               std::uintptr_t time_input = 0) noexcept : state(value), callback(object), id(++state.calls) {
        const auto before = state.callbacks_active.fetch_add(1);
        if (before > camera_thread.callbacks) ++state.observation_generation;
        if (state.post_active.load() > camera_thread.post_scopes) ++state.observation_generation;
        if (state.native_active.load() > camera_thread.native_scopes) ++state.observation_generation;
        ++camera_thread.callbacks;
        sampled = camera_begin_sample(state, sample, id, callback, caller, time_input);
    }
    void finish(bool returned) noexcept {
        if (finished) return;
        CameraError error;
        finished = true;
        if (state.post_active.load() > camera_thread.post_scopes) ++state.observation_generation;
        if (!returned) ++state.observation_generation;
        if (sampled) camera_end_sample(state, sample, callback, returned);
        --camera_thread.callbacks;
        --state.callbacks_active;
    }
    ~CameraCall() { finish(false); }
};
// After a native update returns: hands the camera it evaluated to the listener, only for the
// verified native caller, reading it the way camera_identity does.
void camera_notify_updated(const CameraObserver& state, std::uintptr_t caller, std::uintptr_t time_input,
    std::uintptr_t output) noexcept {
    const auto listener = camera_updated_listener.load(std::memory_order_acquire);
    if (!listener || caller != state.base + camera_addresses::native_caller_return) return;
    std::uintptr_t evaluator{}, camera{}, vtable{};
    if (camera_range(time_input, 0x10) && memory::peek(time_input + 8, evaluator) && camera_object(evaluator) &&
        camera_range(evaluator, 0x140) && memory::peek(evaluator + 0x138, camera) && camera_object(camera) &&
        camera_range(camera, 0x188) && memory::peek(camera, vtable) && vtable == state.base + addr::engine::camera_vtable)
        listener(camera, output);
}
void camera_hook(std::uintptr_t callback, std::uintptr_t time_input, std::uintptr_t output) {
    const auto incoming = GetLastError();
    const auto caller = reinterpret_cast<std::uintptr_t>(_ReturnAddress());
    auto& state = camera_state();
    const auto original = state.original.load(std::memory_order_acquire);
    CameraCall call(state, callback, caller, time_input);
    SetLastError(incoming);
    original(callback, time_input, output);
    const auto returned = GetLastError();
    call.finish(true);
    camera_notify_updated(state, caller, time_input, output);
    SetLastError(returned);
}
}
void set_camera_updated_listener(CameraUpdatedListener listener) noexcept {
    camera_updated_listener.store(listener, std::memory_order_release);
}
bool start_camera_observer(std::uintptr_t base) noexcept {
    CameraError error;
    try {
        auto& state = camera_state();
        std::lock_guard lock(state.initialization);
        if (state.attempted) return state.base == base && state.active.load();
        state.attempted = true; state.base = base;
        std::array<unsigned char, 24> bytes{};
        if (!camera_object(base) || !camera_range(base, camera_image_size) ||
            !memory::read(base + camera_rva, bytes) || bytes != camera_prefix) return false;
        void* original{};
        auto* target = reinterpret_cast<void*>(base + camera_rva);
        if (hook_prepare(target, reinterpret_cast<void*>(&camera_hook), &original) != HookOk) return false;
        if (!original) { (void)hook_remove(target); return false; }
        state.original.store(reinterpret_cast<CameraCallback>(original), std::memory_order_release);
        // Publish the trampoline before enabling. Keep it allocated even if enable
        // reports failure; a detour may already be on a native thread's stack.
        if (hook_enable(target) != HookOk) return false;
        state.active.store(true);
        return true;
    } catch (...) { return false; }
}
void camera_tick_enter(std::uintptr_t client) noexcept {
    CameraError error;
    try {
        auto& state = camera_state();
        if (state.callbacks_active.load() > camera_thread.callbacks) ++state.observation_generation;
        if (camera_thread.overflow || camera_thread.depth == camera_thread.frames.size()) {
            ++camera_thread.overflow; ++state.observation_generation; return;
        }
        camera_thread.frames[camera_thread.depth++] = {client, CameraPhase::native};
        ++camera_thread.native_scopes; ++state.native_active;
    } catch (...) {}
}
void camera_tick_native_return() noexcept {
    CameraError error;
    try {
        auto& state = camera_state();
        if (camera_thread.overflow) return;
        if (!camera_thread.depth || camera_thread.frames[camera_thread.depth - 1].phase != CameraPhase::native) {
            ++state.observation_generation; return;
        }
        camera_thread.frames[camera_thread.depth - 1].phase = CameraPhase::post;
        --camera_thread.native_scopes; --state.native_active;
        ++camera_thread.post_scopes; ++state.post_active;
        if (state.callbacks_active.load() > camera_thread.callbacks) ++state.observation_generation;
    } catch (...) {}
}
void camera_tick_leave() noexcept {
    CameraError error;
    try {
        auto& state = camera_state();
        if (camera_thread.overflow) { --camera_thread.overflow; return; }
        if (!camera_thread.depth) { ++state.observation_generation; return; }
        if (camera_thread.frames[--camera_thread.depth].phase == CameraPhase::native) {
            --camera_thread.native_scopes; --state.native_active;
        } else { --camera_thread.post_scopes; --state.post_active; }
    } catch (...) {}
}
bool camera_post_phase_idle(const CameraObserver& state) noexcept {
    return camera_thread.depth == 1 && !camera_thread.overflow && !camera_thread.callbacks &&
        camera_current_phase() == CameraPhase::post && camera_thread.post_scopes == 1 &&
        !camera_thread.native_scopes && !state.callbacks_active.load() && !state.native_active.load() &&
        state.post_active.load() == 1;
}
const char* camera_probe_unavailable_reason(std::uintptr_t context) noexcept {
    CameraError error;
    try {
        auto& state = camera_state();
        if (!camera_object(context)) return "Waiting for the local camera context.";
        if (!state.active.load()) return "Camera hook is unavailable for this launch.";
        if (!state.calls.load()) return "Waiting for the first camera update.";
        if (!camera_post_phase_idle(state)) return "Waiting for the camera update to finish.";
        const auto generation = state.observation_generation.load();
        const auto& sample = camera_local_sample;
        // Overlap invalidates old evidence, not the entire launch. Only a new
        // isolated callback may establish readiness again; counters stay intact.
        if (sample.id && sample.known_caller && sample.ended && sample.returned && sample.same_identity &&
            sample.isolated && sample.generation == generation && sample.thread == GetCurrentThreadId() &&
            sample.phase == CameraPhase::outside && camera_idle_identity(sample.after, context)) {
            // Leaving freecam, respawning or joining may replace the native
            // selection. A historical address alone never authorizes a call.
            const auto current = camera_identity(state.base, sample.after.callback, sample.after.evaluator);
            if (camera_same_identity(sample.after, current) && camera_idle_identity(current, context) &&
                generation == state.observation_generation.load() && camera_post_phase_idle(state)) return nullptr;
        }
    } catch (...) {}
    return "Waiting for a verified local camera update.";
}
bool camera_probe_phase_observed(std::uintptr_t context) noexcept {
    return camera_probe_unavailable_reason(context) == nullptr;
}
}
