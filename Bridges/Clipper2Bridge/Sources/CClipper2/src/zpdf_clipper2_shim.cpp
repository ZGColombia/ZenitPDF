/*
 * zpdf_clipper2_shim.cpp — implementation of the pure C ABI declared in
 * include/zpdf_clipper2.h. Written for Zenit PDF; not part of upstream Clipper2.
 *
 * Every entry point is noexcept at the ABI level: C++ exceptions thrown by
 * Clipper2 (Clipper2Exception, std::bad_alloc, ...) are caught here and turned
 * into status codes.
 */

#include "zpdf_clipper2.h"

#include "clipper2/clipper.h"

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

namespace {

#ifdef ZPCLIPPER2_TESTING_HOOKS
// Test seam: the number of allocations still allowed to succeed before one is refused, or -1
// when disarmed. Set by zpclipper2_testing_fail_allocation_after(); consulted by shim_malloc.
std::atomic<int32_t> g_allocations_before_failure{-1};
// Test seam for BH-394: a lower ceiling on output counts, so the overflow refusal can be
// exercised without allocating 2^31 vertices. INT32_MAX (the real bound) unless lowered.
std::atomic<int32_t> g_max_output_count{INT32_MAX};
#endif

size_t max_output_count() {
#ifdef ZPCLIPPER2_TESTING_HOOKS
    return static_cast<size_t>(g_max_output_count.load());
#else
    return static_cast<size_t>(INT32_MAX);
#endif
}

// Every buffer handed to the caller is allocated here so that the boundary tests can make one
// allocation fail on demand. Outside a testing build this is std::malloc and nothing else.
void *shim_malloc(size_t size) {
#ifdef ZPCLIPPER2_TESTING_HOOKS
    int32_t remaining = g_allocations_before_failure.load();
    while (remaining >= 0) {
        if (g_allocations_before_failure.compare_exchange_weak(remaining, remaining - 1)) {
            if (remaining == 0) return nullptr;
            break;
        }
    }
#endif
    return std::malloc(size);
}

using Clipper2Lib::ClipType;
using Clipper2Lib::FillRule;
using Clipper2Lib::Path64;
using Clipper2Lib::Paths64;
using Clipper2Lib::Point64;

// Clipper2 refuses coordinates beyond INT64_MAX >> 2; keep a little headroom so
// that intermediate cross-products inside the engine stay in range.
constexpr double kMaxScaledCoord = 4.6e18 / 4.0;

bool decode_fill_rule(int32_t raw, FillRule &out) {
    switch (raw) {
        case ZPCLIPPER2_FILL_EVEN_ODD: out = FillRule::EvenOdd; return true;
        case ZPCLIPPER2_FILL_NON_ZERO: out = FillRule::NonZero; return true;
        case ZPCLIPPER2_FILL_POSITIVE: out = FillRule::Positive; return true;
        case ZPCLIPPER2_FILL_NEGATIVE: out = FillRule::Negative; return true;
        default: return false;
    }
}

bool decode_clip_type(int32_t raw, ClipType &out) {
    switch (raw) {
        case ZPCLIPPER2_CLIP_INTERSECTION: out = ClipType::Intersection; return true;
        case ZPCLIPPER2_CLIP_UNION:        out = ClipType::Union;        return true;
        case ZPCLIPPER2_CLIP_DIFFERENCE:   out = ClipType::Difference;   return true;
        default: return false;
    }
}

bool scale_is_valid(double scale) {
    return std::isfinite(scale) && scale > 0.0;
}

// Converts one caller-space coordinate into Clipper2's integer space.
int32_t scale_coordinate(double value, double scale, int64_t &out) {
    if (!std::isfinite(value)) return ZPCLIPPER2_ERR_NON_FINITE;
    const double scaled = value * scale;
    if (!std::isfinite(scaled)) return ZPCLIPPER2_ERR_OVERFLOW;
    if (scaled > kMaxScaledCoord || scaled < -kMaxScaledCoord) return ZPCLIPPER2_ERR_OVERFLOW;
    out = static_cast<int64_t>(std::llround(scaled));
    return ZPCLIPPER2_OK;
}

// Reads a flattened polygon soup into Paths64. Empty input yields empty output.
//
// CR-141: `coord_count` is the length of the `coords` buffer in doubles, and the sum of
// 2 * lengths[i] is checked against it before the first coordinate is read. The lengths
// array is the caller's claim about a buffer only the caller has measured; with nothing
// to check it against, a single oversized entry walked the reader off the end. Our own
// Swift wrapper never passed a wrong length, which is exactly why this stayed latent in
// a header anyone may call.
int32_t read_paths(const double  *coords,
                   int32_t        coord_count,
                   const int32_t *lengths,
                   int32_t        path_count,
                   double         scale,
                   Paths64       &out) {
    if (path_count < 0) return ZPCLIPPER2_ERR_BAD_PATH_COUNT;
    if (path_count == 0) { out.clear(); return ZPCLIPPER2_OK; }
    if (coords == nullptr || lengths == nullptr) return ZPCLIPPER2_ERR_NULL_ARGUMENT;
    if (coord_count < 0) return ZPCLIPPER2_ERR_BAD_PATH_COUNT;

    // int64_t so the running total cannot wrap however hostile the lengths are.
    int64_t required = 0;
    for (int32_t i = 0; i < path_count; ++i) {
        const int32_t n = lengths[i];
        if (n < 0) return ZPCLIPPER2_ERR_BAD_PATH_COUNT;
        required += 2 * static_cast<int64_t>(n);
        if (required > static_cast<int64_t>(coord_count)) return ZPCLIPPER2_ERR_COORD_OVERRUN;
    }

    out.clear();
    out.reserve(static_cast<size_t>(path_count));

    size_t cursor = 0;
    for (int32_t i = 0; i < path_count; ++i) {
        const int32_t n = lengths[i];
        if (n < 0) return ZPCLIPPER2_ERR_BAD_PATH_COUNT;
        Path64 path;
        path.reserve(static_cast<size_t>(n));
        for (int32_t j = 0; j < n; ++j) {
            int64_t x = 0;
            int64_t y = 0;
            int32_t status = scale_coordinate(coords[cursor], scale, x);
            if (status != ZPCLIPPER2_OK) return status;
            status = scale_coordinate(coords[cursor + 1], scale, y);
            if (status != ZPCLIPPER2_OK) return status;
            cursor += 2;
            path.push_back(Point64(x, y));
        }
        out.push_back(std::move(path));
    }
    return ZPCLIPPER2_OK;
}

// Writes Paths64 back out as caller-space doubles. Takes ownership of nothing;
// *out receives malloc'd buffers that zpclipper2_paths_free() releases.
//
// CR-142: *out is not touched until the call has succeeded. Zeroing it first contradicted
// the header's own "*out is untouched otherwise", and it does so at the worst moment —
// an allocation failure would clear the caller's struct, so a caller that kept a previous
// result there lost the pointers to it and leaked them.
int32_t write_paths(const Paths64 &paths, double scale, ZPClipper2Paths *out) {
    // BH-394: every count crosses the ABI as int32_t. A large enough boolean result can
    // exceed it; the static_cast used to wrap the counts negative.
    const size_t kMaxCount = max_output_count();
    if (paths.size() > kMaxCount) return ZPCLIPPER2_ERR_OVERFLOW;
    size_t vertex_total = 0;
    for (const Path64 &path : paths) {
        if (path.size() > kMaxCount) return ZPCLIPPER2_ERR_OVERFLOW;
        vertex_total += path.size();
        if (vertex_total > kMaxCount) return ZPCLIPPER2_ERR_OVERFLOW;
    }

    if (paths.empty()) {
        out->coords = nullptr;
        out->path_lengths = nullptr;
        out->path_count = 0;
        out->vertex_count = 0;
        return ZPCLIPPER2_OK;
    }

    int32_t *lengths = static_cast<int32_t *>(
        shim_malloc(sizeof(int32_t) * paths.size()));
    if (lengths == nullptr) return ZPCLIPPER2_ERR_OUT_OF_MEMORY;

    double *coords = nullptr;
    if (vertex_total > 0) {
        coords = static_cast<double *>(shim_malloc(sizeof(double) * 2 * vertex_total));
        if (coords == nullptr) {
            std::free(lengths);
            return ZPCLIPPER2_ERR_OUT_OF_MEMORY;
        }
    }

    size_t cursor = 0;
    for (size_t i = 0; i < paths.size(); ++i) {
        lengths[i] = static_cast<int32_t>(paths[i].size());
        for (const Point64 &p : paths[i]) {
            // BH-393: divide, as documented. Multiplying by the inexact reciprocal turned
            // 100000 / 1e6 = 0.1 into 0.09999999999999999.
            coords[cursor++] = static_cast<double>(p.x) / scale;
            coords[cursor++] = static_cast<double>(p.y) / scale;
        }
    }

    out->coords = coords;
    out->path_lengths = lengths;
    out->path_count = static_cast<int32_t>(paths.size());
    out->vertex_count = static_cast<int32_t>(vertex_total);
    return ZPCLIPPER2_OK;
}

} // namespace

extern "C" {

void zpclipper2_paths_free(ZPClipper2Paths *paths) {
    if (paths == nullptr) return;
    std::free(paths->coords);
    std::free(paths->path_lengths);
    paths->coords = nullptr;
    paths->path_lengths = nullptr;
    paths->path_count = 0;
    paths->vertex_count = 0;
}

int32_t zpclipper2_boolean(int32_t clip_type_raw,
                           int32_t fill_rule_raw,
                           const double  *subject_coords,
                           int32_t        subject_coord_count,
                           const int32_t *subject_lengths,
                           int32_t        subject_path_count,
                           const double  *clip_coords,
                           int32_t        clip_coord_count,
                           const int32_t *clip_lengths,
                           int32_t        clip_path_count,
                           int32_t        preserve_collinear,
                           double         scale,
                           ZPClipper2Paths *out) {
    if (out == nullptr) return ZPCLIPPER2_ERR_NULL_ARGUMENT;
    if (!scale_is_valid(scale)) return ZPCLIPPER2_ERR_BAD_SCALE;

    ClipType clip_type;
    FillRule fill_rule;
    if (!decode_clip_type(clip_type_raw, clip_type)) return ZPCLIPPER2_ERR_BAD_ENUM;
    if (!decode_fill_rule(fill_rule_raw, fill_rule)) return ZPCLIPPER2_ERR_BAD_ENUM;

    try {
        Paths64 subjects;
        Paths64 clips;
        int32_t status = read_paths(subject_coords, subject_coord_count, subject_lengths,
                                    subject_path_count, scale, subjects);
        if (status != ZPCLIPPER2_OK) return status;
        status = read_paths(clip_coords, clip_coord_count, clip_lengths,
                            clip_path_count, scale, clips);
        if (status != ZPCLIPPER2_OK) return status;

        // Driving Clipper64 directly (rather than the Union/Intersect/... free
        // functions) is what makes PreserveCollinear reachable.
        Clipper2Lib::Clipper64 clipper;
        clipper.PreserveCollinear(preserve_collinear != 0);
        if (!subjects.empty()) clipper.AddSubject(subjects);
        if (!clips.empty()) clipper.AddClip(clips);

        Paths64 solution;
        if (!clipper.Execute(clip_type, fill_rule, solution))
            return ZPCLIPPER2_ERR_CLIPPER_THREW;
        return write_paths(solution, scale, out);
    } catch (const std::bad_alloc &) {
        return ZPCLIPPER2_ERR_OUT_OF_MEMORY;
    } catch (...) {
        return ZPCLIPPER2_ERR_CLIPPER_THREW;
    }
}

int32_t zpclipper2_point_in_polygon(double x,
                                    double y,
                                    const double *coords,
                                    int32_t       coord_count,
                                    int32_t       vertex_count,
                                    int32_t       fill_rule_raw,
                                    double        scale,
                                    int32_t      *out) {
    if (out == nullptr) return ZPCLIPPER2_ERR_NULL_ARGUMENT;
    if (!scale_is_valid(scale)) return ZPCLIPPER2_ERR_BAD_SCALE;
    if (vertex_count < 0 || coord_count < 0) return ZPCLIPPER2_ERR_BAD_PATH_COUNT;
    if (vertex_count > 0 && coords == nullptr) return ZPCLIPPER2_ERR_NULL_ARGUMENT;
    // BH-395: the CR-141 bound, here too. The caller's vertex count is a claim about a
    // buffer only the caller measured; check it against the buffer length in int64.
    if (2 * static_cast<int64_t>(vertex_count) > static_cast<int64_t>(coord_count))
        return ZPCLIPPER2_ERR_COORD_OVERRUN;
    FillRule fill_rule;
    if (!decode_fill_rule(fill_rule_raw, fill_rule)) return ZPCLIPPER2_ERR_BAD_ENUM;

    try {
        int64_t px = 0;
        int64_t py = 0;
        int32_t status = scale_coordinate(x, scale, px);
        if (status != ZPCLIPPER2_OK) return status;
        status = scale_coordinate(y, scale, py);
        if (status != ZPCLIPPER2_OK) return status;

        Path64 polygon;
        polygon.reserve(static_cast<size_t>(vertex_count));
        for (int32_t i = 0; i < vertex_count; ++i) {
            int64_t vx = 0;
            int64_t vy = 0;
            const size_t index = 2 * static_cast<size_t>(i);   // no int32 overflow (BH-395)
            status = scale_coordinate(coords[index], scale, vx);
            if (status != ZPCLIPPER2_OK) return status;
            status = scale_coordinate(coords[index + 1], scale, vy);
            if (status != ZPCLIPPER2_OK) return status;
            polygon.push_back(Point64(vx, vy));
        }

        const Point64 point(px, py);
        const Clipper2Lib::PointInPolygonResult parity = Clipper2Lib::PointInPolygon(point, polygon);
        if (parity == Clipper2Lib::PointInPolygonResult::IsOn) {
            *out = ZPCLIPPER2_PIP_ON;
            return ZPCLIPPER2_OK;
        }
        // BH-397: Clipper2's PointInPolygon is even-odd. The booleans default to non-zero,
        // so the fill rule is honoured here with a winding number on the lattice
        // (128-bit cross products: the coordinates reach ±1.15e18).
        bool inside = false;
        if (fill_rule == FillRule::EvenOdd) {
            inside = parity == Clipper2Lib::PointInPolygonResult::IsInside;
        } else {
            int64_t winding = 0;
            const size_t n = polygon.size();
            for (size_t k = 0; k < n; ++k) {
                const Point64 &a = polygon[k];
                const Point64 &b = polygon[(k + 1) % n];
                const __int128 cross =
                    static_cast<__int128>(b.x - a.x) * static_cast<__int128>(point.y - a.y) -
                    static_cast<__int128>(point.x - a.x) * static_cast<__int128>(b.y - a.y);
                if (a.y <= point.y) {
                    if (b.y > point.y && cross > 0) ++winding;
                } else if (b.y <= point.y && cross < 0) {
                    --winding;
                }
            }
            switch (fill_rule) {
                case FillRule::NonZero:  inside = winding != 0; break;
                case FillRule::Positive: inside = winding > 0;  break;
                case FillRule::Negative: inside = winding < 0;  break;
                default:                 inside = winding != 0; break;
            }
        }
        *out = inside ? ZPCLIPPER2_PIP_INSIDE : ZPCLIPPER2_PIP_OUTSIDE;
        return ZPCLIPPER2_OK;
    } catch (const std::bad_alloc &) {
        return ZPCLIPPER2_ERR_OUT_OF_MEMORY;
    } catch (...) {
        return ZPCLIPPER2_ERR_CLIPPER_THREW;
    }
}

#ifdef ZPCLIPPER2_TESTING_HOOKS
/*
 * Test seam, deliberately absent from zpdf_clipper2.h and from release builds. After
 * `successes` further allocations have succeeded, the next one returns NULL and the seam
 * disarms itself. A negative count disarms it immediately.
 */
void zpclipper2_testing_fail_allocation_after(int32_t successes) {
    g_allocations_before_failure.store(successes < 0 ? -1 : successes);
}

/* BH-394 seam: the ceiling on output path/vertex counts; <= 0 restores INT32_MAX. */
void zpclipper2_testing_set_max_output_count(int32_t limit) {
    g_max_output_count.store(limit <= 0 ? INT32_MAX : limit);
}
#endif

} // extern "C"
