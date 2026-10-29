/*
 * zpdf_clipper2.h — pure C ABI over the vendored Clipper2 C++ library.
 *
 * This header is the ONLY public header of the CClipper2 target. It deliberately
 * exposes no C++ types, so the Swift side can import it as a plain C module with
 * no Swift/C++ interop enabled.
 *
 * Coordinate model
 * ----------------
 * All coordinates cross this boundary as `double` values in the caller's own
 * space (for Zenit PDF: PDF page points). The shim multiplies them by `scale`
 * and rounds to `int64_t` before handing them to Clipper2, which is an exact
 * integer-arithmetic clipper, then divides by `scale` on the way out.
 * See VENDORED.md for the precision discussion.
 */

#ifndef ZPDF_CLIPPER2_H
#define ZPDF_CLIPPER2_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- status codes ------------------------------------------------------ */

#define ZPCLIPPER2_OK                    0
#define ZPCLIPPER2_ERR_NULL_ARGUMENT     1
#define ZPCLIPPER2_ERR_BAD_SCALE         2
#define ZPCLIPPER2_ERR_BAD_PATH_COUNT    3
#define ZPCLIPPER2_ERR_NON_FINITE        4
#define ZPCLIPPER2_ERR_OVERFLOW          5
#define ZPCLIPPER2_ERR_BAD_ENUM          6
#define ZPCLIPPER2_ERR_CLIPPER_THREW     7
#define ZPCLIPPER2_ERR_OUT_OF_MEMORY     8
/*
 * The path lengths claim more coordinates than the coords buffer holds. Refused
 * before a single coordinate is read.
 */
#define ZPCLIPPER2_ERR_COORD_OVERRUN     9

/* ---- enumerations (mirrored, NOT the C++ values) ----------------------- */

#define ZPCLIPPER2_FILL_EVEN_ODD  0
#define ZPCLIPPER2_FILL_NON_ZERO  1
#define ZPCLIPPER2_FILL_POSITIVE  2
#define ZPCLIPPER2_FILL_NEGATIVE  3

#define ZPCLIPPER2_CLIP_INTERSECTION 0
#define ZPCLIPPER2_CLIP_UNION        1
#define ZPCLIPPER2_CLIP_DIFFERENCE   2

#define ZPCLIPPER2_PIP_ON      0
#define ZPCLIPPER2_PIP_INSIDE  1
#define ZPCLIPPER2_PIP_OUTSIDE 2

/*
 * Flattened polygon soup.
 *
 * `coords` holds interleaved x,y pairs for every path back to back;
 * `path_lengths[i]` is the vertex count of path i, so path i occupies
 * 2 * sum(path_lengths[0..<i]) ..< 2 * sum(path_lengths[0...i]) of `coords`.
 *
 * A value produced by this library must be released with
 * zpclipper2_paths_free(). A zeroed struct is a valid empty result.
 */
typedef struct ZPClipper2Paths {
    double  *coords;
    int32_t *path_lengths;
    int32_t  path_count;
    int32_t  vertex_count; /* total vertices; coords has 2 * vertex_count doubles */
} ZPClipper2Paths;

/* Releases memory owned by *paths and zeroes it. Safe on NULL / zeroed input. */
void zpclipper2_paths_free(ZPClipper2Paths *paths);

/*
 * Boolean operation. `clip_*` may describe zero paths (pass NULL/0), which is
 * the normalising self-union form used to clean self-intersecting input.
 * When `preserve_collinear` is zero, vertices that lie on a straight edge are
 * dropped from the result (Clipper2's own default keeps them).
 * Writes the result into *out on ZPCLIPPER2_OK; *out is untouched otherwise.
 *
 * `*_coord_count` is the number of doubles the matching coords buffer holds —
 * 2 per vertex. The lengths array is a claim made by the caller and this is the
 * only thing that can check it: without the count, a lengths entry larger than
 * the buffer sends the reader off the end of it. Sum(2 * lengths[i]) must not
 * exceed the count, or the call is refused with ZPCLIPPER2_ERR_COORD_OVERRUN
 * before anything is read.
 */
int32_t zpclipper2_boolean(int32_t clip_type,
                           int32_t fill_rule,
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
                           ZPClipper2Paths *out);

/*
 * Exact integer point-in-polygon test on the scaled coordinates.
 * Writes ZPCLIPPER2_PIP_* into *out.
 *
 * `coord_count` is the length of `coords` in doubles; 2 * vertex_count must not exceed it,
 * or the call is refused with ZPCLIPPER2_ERR_COORD_OVERRUN (the CR-141 bound). The ring is
 * interpreted under `fill_rule` (ZPCLIPPER2_FILL_*): even-odd parity, or the winding
 * number for non-zero / positive / negative. A point on an edge is ZPCLIPPER2_PIP_ON
 * under every rule.
 */
int32_t zpclipper2_point_in_polygon(double x,
                                    double y,
                                    const double *coords,
                                    int32_t       coord_count,
                                    int32_t       vertex_count,
                                    int32_t       fill_rule,
                                    double        scale,
                                    int32_t      *out);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ZPDF_CLIPPER2_H */
