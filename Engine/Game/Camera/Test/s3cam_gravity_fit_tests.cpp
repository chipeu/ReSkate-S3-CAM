#include "Engine/Game/Camera/s3_gravity_fit.h"

#include <cmath>
#include <cstdio>
#include <string_view>

// Spike S4 (s3_gravity_fit.h): the airborne-arc fit that measures skate.'s gravity in game.
namespace {
using namespace dingosdk::s3cam;
int failures = 0;

void expect(bool condition, std::string_view what) {
    if (condition) return;
    ++failures;
    std::printf("FAIL: %.*s\n", static_cast<int>(what.size()), what.data());
}
bool near(double a, double b, double tolerance) { return std::abs(a - b) <= tolerance; }

// One ballistic arc sampled at `hz`, starting at game clock `start` (large, as the game's is).
void record_arc(ArcRecorder& arc, double gravity, double hz, double start, double seconds, double jitter = 0) {
    const double up = gravity * seconds / 2; // lands where it took off
    for (int i = 0;; ++i) {
        const double t = i / hz;
        if (t > seconds) break;
        // Deterministic +-jitter, like float positions and uneven frame times.
        const double noise = jitter * ((i * 7919) % 13 - 6) / 6.0;
        arc.add(start + t, 3.0 + up * t - 0.5 * gravity * t * t + noise);
    }
}

void exact() {
    for (const double hz : {30.0, 60.0, 144.0, 1000.0}) {
        ArcRecorder arc;
        record_arc(arc, 9.81, hz, 86400.0, 0.6);
        const auto fit = arc.fit();
        expect(fit && near(fit->gravity, 9.81, 1e-4), "recovers gravity from a clean arc at any frame rate");
        expect(fit && fit->rms < 1e-6, "a clean arc fits with no residual");
    }
    ArcRecorder arc;
    record_arc(arc, 12.0, 60, 5000.0, 0.5);
    const auto fit = arc.fit();
    expect(fit && near(fit->gravity, 12.0, 1e-4), "recovers a gravity other than Earth's");
}

void noisy() {
    ArcRecorder arc;
    record_arc(arc, 9.81, 60, 1234.5, 0.7, 0.002);
    const auto fit = arc.fit();
    expect(fit && near(fit->gravity, 9.81, 0.25), "2 mm of position noise still gives gravity within 0.25");
    expect(fit && fit->rms < 0.003, "the residual reports the noise level");
}

void trimmed() {
    // Contact forces at either end (a pop going up, a landing compressing) must not bend the fit.
    ArcRecorder arc;
    const double hz = 60, seconds = 0.6, g = 9.81, up = g * seconds / 2;
    for (int i = 0; i <= static_cast<int>(seconds * hz); ++i) {
        const double t = i / hz;
        double y = up * t - 0.5 * g * t * t;
        if (i < 3) y -= 0.05 * (3 - i);                                          // still on the tail
        if (i > static_cast<int>(seconds * hz) - 3) y -= 0.05;                   // touching down
        arc.add(t, y);
    }
    const auto fit = arc.fit();
    expect(fit && near(fit->gravity, g, 0.05), "takeoff and touchdown samples are trimmed before fitting");
}

void rejects() {
    ArcRecorder empty;
    expect(!empty.fit(), "no samples, no fit");
    ArcRecorder short_hop;
    record_arc(short_hop, 9.81, 60, 0, 0.15);
    expect(!short_hop.fit(), "an arc under 0.25 s is too short to trust");
    ArcRecorder repeated;
    for (int i = 0; i < 40; ++i) repeated.add(10.0, 1.0); // a paused game repeats one tick
    expect(repeated.size() == 1, "time that does not advance is ignored");
    ArcRecorder bad;
    bad.add(NAN, 1); bad.add(1, INFINITY);
    expect(bad.size() == 0, "non-finite samples are ignored");
    ArcRecorder full;
    for (std::size_t i = 0; i < ArcRecorder::capacity + 50; ++i) full.add(static_cast<double>(i) / 144, 0);
    expect(full.size() == ArcRecorder::capacity, "storage is fixed; extra samples are dropped");
    record_arc(full, 9.81, 60, 1e6, 1.0);
    expect(full.size() == ArcRecorder::capacity, "a full recorder stays full until cleared");
    full.clear();
    expect(full.size() == 0, "clear empties the recorder");
}
} // namespace

int main() {
    exact();
    noisy();
    trimmed();
    rejects();
    if (failures) {
        std::printf("%d s3cam gravity fit test(s) failed\n", failures);
        return 1;
    }
    std::printf("s3cam gravity fit tests passed\n");
    return 0;
}
