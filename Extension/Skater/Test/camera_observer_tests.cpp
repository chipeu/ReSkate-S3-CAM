// Exercise the observer against memory owned by this process. No game, hooks,
// or native camera calls are used; only the native TLS lookup is substituted.
#include <Windows.h>
#include <intrin.h>
#include <array>
#include <cstring>
#include <future>
#include <iostream>
#include <stdexcept>
#include <thread>
thread_local std::array<std::uintptr_t, 1> fixture_tls;
unsigned __int64 fixture_gs(unsigned long) { return reinterpret_cast<std::uintptr_t>(fixture_tls.data()); }
#define __readgsqword fixture_gs
#include "Extension/Skater/camera_observer.cpp"
#undef __readgsqword

namespace dingosdk {
HookStatus WINAPI hook_prepare(void*, void*, void**) { return HookNotInitialized; }
HookStatus WINAPI hook_enable(void*) { return HookNotInitialized; }
HookStatus WINAPI hook_remove(void*) { return HookNotInitialized; }
}
using namespace dingosdk;
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
template<std::size_t N> struct Block {
    alignas(8) std::array<std::byte, N> bytes{};
    std::uintptr_t address() const { return reinterpret_cast<std::uintptr_t>(bytes.data()); }
    template<class T> void put(std::size_t at, T value) { std::memcpy(bytes.data() + at, &value, sizeof(value)); }
};
struct Camera {
    Block<0x28> callback;
    Block<0x98> entry;
    Block<0x70> helper;
    Block<0x140> evaluator;
    Block<0x188> camera;
    Block<0x18> collection;
    Block<0x10> selection, input;
    Block<8> context, graph;
    explicit Camera(std::uintptr_t entry_type = camera_addresses::entry_vtable) {
        const auto base = camera_state().base;
        callback.put(0, base + camera_addresses::callback_vtable);
        callback.put(0x10, entry.address()); callback.put(0x18, helper.address()); callback.put(0x20, graph.address());
        entry.put(0, base + entry_type); entry.put(0x60, callback.address()); entry.put(0x90, context.address());
        helper.put(0, base + camera_addresses::helper_vtable); helper.put(0x50, callback.address());
        evaluator.put(0, context.address()); evaluator.put(8, collection.address()); evaluator.put(0x138, camera.address());
        camera.put(0, base + addr::engine::camera_vtable); camera.put(0x180, evaluator.address());
        collection.put(0, evaluator.address()); collection.put(8, selection.address()); collection.put(0x10, selection.address() + 0x10);
        selection.put(0, entry.address()); input.put(8, evaluator.address());
    }
};
struct NativeTls {
    Block<0xb20> block;
    explicit NativeTls(const Camera& camera) {
        block.put(0xb19, static_cast<unsigned char>(1)); block.put(0x550, camera.context.address());
        fixture_tls[0] = block.address();
    }
    ~NativeTls() { fixture_tls[0] = 0; }
};
void observe(Camera& camera, bool returned = true) {
    CameraCall call(camera_state(), camera.callback.address(),
        camera_state().base + camera_addresses::native_caller_return, camera.input.address());
    call.finish(returned);
}
bool ready(Camera& camera) {
    camera_tick_enter(0x10000);
    camera_tick_native_return();
    const bool result = camera_probe_phase_observed(camera.context.address());
    camera_tick_leave();
    return result;
}
void native_entry_variants() {
    // The live stuck-camera capture selected the alternate entry. Both constructors
    // initialize the same evaluator-facing entry base, then set their own type.
    Camera alternate(camera_addresses::alternate_entry_vtable);
    NativeTls tls(alternate);
    observe(alternate);
    check(ready(alternate), "The alternate native entry must establish camera readiness");
    alternate.entry.put(0, camera_state().base + camera_addresses::alternate_entry_vtable + 0x10);
    check(!ready(alternate), "Unverified entry types remain rejected");
    alternate.entry.put(0, camera_state().base + camera_addresses::alternate_entry_vtable);
    alternate.entry.put(0x60, std::uintptr_t{});
    check(!ready(alternate), "Supported entry variants still require a reciprocal callback");
    alternate.entry.put(0x60, alternate.callback.address());
    check(ready(alternate), "A supported entry with restored ownership remains usable");
}
void recovery() {
    Camera camera;
    NativeTls tls(camera);
    observe(camera);
    check(ready(camera), "An isolated local update enables flight");
    check(!camera_probe_phase_observed(camera.context.address()), "Flight is blocked outside the native post-tick phase");
    camera_tick_enter(0x10000); camera_tick_native_return();
    std::promise<void> entered, release;
    auto released = release.get_future();
    std::thread worker([&] {
        NativeTls worker_tls(camera);
        CameraCall call(camera_state(), camera.callback.address(),
            camera_state().base + camera_addresses::native_caller_return, camera.input.address());
        entered.set_value(); released.wait(); call.finish(true);
    });
    entered.get_future().wait();
    const bool during = camera_probe_phase_observed(camera.context.address());
    release.set_value(); worker.join();
    const bool after = camera_probe_phase_observed(camera.context.address());
    camera_tick_leave();
    check(!during && !after, "An overlap blocks both active operations and stale pre-overlap evidence");
    observe(camera);
    check(ready(camera), "A fresh isolated update recovers without restarting or resetting counters");

    camera.helper.put(0x60, camera.input.address());
    check(!ready(camera), "Live helper scratch pointers block flight even with a previous valid sample");
    camera.helper.put(0x60, std::uintptr_t{});
    camera.selection.put(0, std::uintptr_t{});
    check(!ready(camera), "A changed camera selection invalidates historical readiness");
    camera.selection.put(0, camera.entry.address());
    check(ready(camera), "An unchanged idle ownership chain is valid between sampled updates");

    std::thread fresh_thread([&] {
        NativeTls worker_tls(camera);
        check(!ready(camera), "Another thread cannot borrow the local camera observation");
    });
    fresh_thread.join();
    observe(camera, false);
    check(!ready(camera), "A native exception invalidates previous evidence even during sampling throttle");
    observe(camera);
    check(ready(camera), "An isolated returned update recovers after a failed update");
}
void replacement_cameras() {
    // Many identities, as after repeated respawns/editor transitions/joins.
    // Keep allocations alive to avoid reuse.
    std::array<std::unique_ptr<Camera>, 80> cameras;
    for (std::size_t i = 0; i < cameras.size(); ++i) {
        auto& item = cameras[i];
        item = std::make_unique<Camera>(i % 2 ? camera_addresses::alternate_entry_vtable : camera_addresses::entry_vtable);
        NativeTls tls(*item);
        observe(*item);
        check(ready(*item), "Replacement cameras remain usable");
        Camera other;
        check(!camera_probe_phase_observed(other.context.address()), "A different world cannot use the previous observation");
    }
}
std::uintptr_t updated_camera{};
int updated_calls{};
void record_update(std::uintptr_t camera) noexcept { updated_camera = camera; ++updated_calls; }
// S3Cam spike S1c: the listener gets the evaluated camera after a verified native update only.
void updated_listener() {
    Camera camera;
    const auto native = camera_state().base + camera_addresses::native_caller_return;
    camera_notify_updated(camera_state(), native, camera.input.address());
    check(updated_calls == 0, "No listener, no call");
    set_camera_updated_listener(&record_update);
    camera_notify_updated(camera_state(), native, camera.input.address());
    check(updated_calls == 1 && updated_camera == camera.camera.address(), "The listener receives the evaluated camera");
    camera_notify_updated(camera_state(), native + 1, camera.input.address());
    check(updated_calls == 1, "Other callers are ignored");
    camera.camera.put(0, std::uintptr_t{0});
    camera_notify_updated(camera_state(), native, camera.input.address());
    check(updated_calls == 1, "A camera of another type is ignored");
    set_camera_updated_listener(nullptr);
    camera.camera.put(0, camera_state().base + addr::engine::camera_vtable);
    camera_notify_updated(camera_state(), native, camera.input.address());
    check(updated_calls == 1, "A removed listener is not called");
}
int main() {
    try {
        const auto image = reinterpret_cast<std::uintptr_t>(VirtualAlloc(nullptr, 0x7900000, MEM_RESERVE, PAGE_READWRITE));
        check(image != 0, "Reserve fixture address range");
        check(VirtualAlloc(reinterpret_cast<void*>(image + (addr::engine::tls_index & ~std::uintptr_t{0xfff})), 4096, MEM_COMMIT, PAGE_READWRITE) != nullptr,
            "Commit fixture TLS index page");
        camera_state().base = image; camera_state().active = true;
        native_entry_variants(); recovery(); replacement_cameras(); updated_listener();
        VirtualFree(reinterpret_cast<void*>(image), 0, MEM_RELEASE);
        std::cout << "Camera observation recovery checks passed.\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
