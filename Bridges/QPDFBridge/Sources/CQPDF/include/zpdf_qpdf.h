/*
 * zpdf_qpdf.h — pure C ABI over the vendored qpdf C++ library.
 *
 * This header is the ONLY public header of the CQPDF target. It deliberately
 * exposes no C++ type, no exception and no ownership, so the Swift side imports
 * it as a plain C module and nothing in Zenit PDF has to enable Swift/C++
 * interop. Every function is synchronous, returns a status code, and never
 * throws: the implementation wraps qpdf in a catch-all.
 *
 * Contract, enforced in the implementation and asserted by the tests:
 *
 *   1. No function ever opens an input for writing. Inputs are opened "rb".
 *   2. Every function that produces a file writes a NEW file. If the output
 *      path already exists, or resolves to the same file as any input, the call
 *      fails with ZPDFQPDF_ERR_OUTPUT_CONFLICT before qpdf is even constructed.
 *   3. Output is written to a sibling temporary file and renamed into place
 *      only after a successful write, so a failed or cancelled operation leaves
 *      no partial file behind.
 *   4. Untrusted input is bounded: file size, page count and qpdf's own parser
 *      limits are all capped by zpdf_qpdf_options.
 *
 * Threading: qpdf's parser limits are process-global (qpdf::global::limits), so
 * every entry point in this shim takes one process-wide mutex for its whole
 * duration. Concurrency across documents must therefore come from separate
 * processes (the XPC RepairService), not from threads.
 */

#ifndef ZPDF_QPDF_H
#define ZPDF_QPDF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- status codes ------------------------------------------------------ */

#define ZPDFQPDF_OK                      0
#define ZPDFQPDF_ERR_ARGUMENT            1  /* null/empty path, bad count, bad range */
#define ZPDFQPDF_ERR_OUTPUT_CONFLICT     2  /* output exists, or is an input */
#define ZPDFQPDF_ERR_CANNOT_READ         3  /* missing, unreadable, not a regular file */
#define ZPDFQPDF_ERR_PASSWORD_REQUIRED   4  /* encrypted, no password supplied */
#define ZPDFQPDF_ERR_PASSWORD_INCORRECT  5  /* encrypted, supplied password rejected */
#define ZPDFQPDF_ERR_DAMAGED             6  /* unrecoverable structural damage */
#define ZPDFQPDF_ERR_WRITE               7  /* output could not be written or renamed */
#define ZPDFQPDF_ERR_UNSUPPORTED         8  /* qpdf understands the file but not this request */
#define ZPDFQPDF_ERR_CANCELLED           9  /* the cancel callback returned non-zero */
#define ZPDFQPDF_ERR_LIMIT              10  /* input exceeded a configured bound */
#define ZPDFQPDF_ERR_OUT_OF_MEMORY      11
#define ZPDFQPDF_ERR_INTERNAL           12  /* unexpected exception; a bug, reported not thrown */
#define ZPDFQPDF_ERR_PAGE_RANGE         13  /* page index out of range or duplicated */

/* ---- fixed-size report -------------------------------------------------- */

#define ZPDFQPDF_MESSAGE_CAPACITY  1024
#define ZPDFQPDF_WARNINGS_CAPACITY 8192

/*
 * Diagnostics for one call. Fixed-size on purpose: nothing is allocated for the
 * caller to free, and a hostile file that produces a hundred thousand warnings
 * cannot make the shim allocate without bound. `warning_count` is the true
 * count; `warnings` holds as many of them as fit, '\n'-separated.
 */
typedef struct zpdf_qpdf_report {
    int32_t status;
    int32_t warning_count;
    int32_t warnings_truncated;                    /* 1 if warnings[] lost entries */
    int32_t reserved;
    char message[ZPDFQPDF_MESSAGE_CAPACITY];       /* always NUL-terminated */
    char warnings[ZPDFQPDF_WARNINGS_CAPACITY];     /* always NUL-terminated */
} zpdf_qpdf_report;

/* ---- options ------------------------------------------------------------ */

/*
 * Bounds on untrusted input. A field set to 0 means "use the built-in default",
 * which is documented next to the field. The parser limits are applied to
 * qpdf's process-global limit registry for the duration of the call.
 */
typedef struct zpdf_qpdf_options {
    int64_t  max_input_bytes;            /* 0 -> 1 GiB. Checked before opening.   */
    int32_t  max_pages;                  /* 0 -> 20000                            */
    int32_t  attempt_recovery;           /* 0 -> on. Set to -1 to disable.        */
    uint32_t doc_max_warnings;           /* 0 -> 10000                            */
    uint32_t parser_max_errors;          /* 0 -> 1000                             */
    uint32_t parser_max_nesting;         /* 0 -> 200                              */
    uint32_t parser_max_container_size;  /* 0 -> 5000000                          */
    uint32_t max_stream_filters;         /* 0 -> 8                                */
    uint32_t flate_max_memory;           /* 0 -> 512 MiB. Bounds the zip bomb.    */
    uint32_t png_max_memory;             /* 0 -> 512 MiB                          */
    uint32_t tiff_max_memory;            /* 0 -> 512 MiB                          */
    uint32_t run_length_max_memory;      /* 0 -> 512 MiB                          */
    int32_t  ignore_xref_streams;        /* 1 -> force xref reconstruction path   */
} zpdf_qpdf_options;

/* Fills `out` with the defaults described above. Never fails. */
void zpdf_qpdf_options_defaults(zpdf_qpdf_options* out);

/* ---- cancellation -------------------------------------------------------- */

/*
 * Called from the same thread that called the entry point, at operation
 * boundaries and from QPDFWriter's progress reporter. Return non-zero to abort;
 * the operation then fails with ZPDFQPDF_ERR_CANCELLED and writes no output.
 *
 * Cancellation is cooperative and therefore not instantaneous. It is checked:
 *   - before the input is opened,
 *   - after the document has been parsed,
 *   - once per page while inspecting or assembling pages,
 *   - at each of QPDFWriter's progress ticks during the write.
 * A single pathological object that takes a long time to parse cannot be
 * interrupted; that is what the parser limits above are for.
 */
typedef int32_t (*zpdf_qpdf_cancel_fn)(void* context);

/* ---- inventory ----------------------------------------------------------- */

typedef struct zpdf_qpdf_inventory {
    int64_t file_size;
    int64_t object_count;            /* indirect objects, qpdf's approximate count */
    int64_t stream_count;
    int64_t page_count;
    int32_t pdf_version_major;
    int32_t pdf_version_minor;
    int32_t extension_level;

    int32_t is_encrypted;
    int32_t encryption_revision;     /* /R, 0 when not encrypted */
    int32_t encryption_permissions;  /* /P, 0 when not encrypted */
    int32_t encryption_key_bits;
    int32_t user_password_matched;
    int32_t owner_password_matched;

    int32_t allow_accessibility;
    int32_t allow_extract_all;
    int32_t allow_print_low_res;
    int32_t allow_print_high_res;
    int32_t allow_modify_assembly;
    int32_t allow_modify_form;
    int32_t allow_modify_annotation;
    int32_t allow_modify_other;
    int32_t allow_modify_all;

    int32_t is_linearized;
    int32_t linearization_is_valid;  /* only meaningful when is_linearized */

    /* damage findings */
    int32_t xref_was_reconstructed;
    int32_t damage_warning_count;    /* warnings with error code qpdf_e_damaged_pdf */
    int32_t page_warning_count;      /* qpdf_e_pages */
    int32_t undecodable_stream_count;/* streams whose filters could not be applied */
    int32_t unfilterable_stream_count; /* streams qpdf cannot filter at all, e.g. DCT */
} zpdf_qpdf_inventory;

/* ---- write flags --------------------------------------------------------- */

#define ZPDFQPDF_WRITE_LINEARIZE            0x0001u
#define ZPDFQPDF_WRITE_PRESERVE_ENCRYPTION  0x0002u /* keep the input's encryption */
/* 0x0004u is retired (it removed restrictions and signatures, with no caller); do not reuse. */
#define ZPDFQPDF_WRITE_DETERMINISTIC_ID     0x0008u /* /ID from content, not from the clock */
#define ZPDFQPDF_WRITE_QDF                  0x0010u /* uncompressed, human-readable output */
#define ZPDFQPDF_WRITE_OBJECT_STREAMS_OFF   0x0020u /* write no object streams */

/* ---- entry points -------------------------------------------------------- */

/*
 * Accessors for the report's two text buffers.
 *
 * They exist because Swift's clang importer refuses to import a C fixed-size
 * array longer than 4096 elements as a tuple, so `report.warnings` is simply
 * not visible from Swift. Returning `const char*` sidesteps the importer
 * entirely and keeps the buffer sizes free to grow. The pointers are valid for
 * as long as the report is.
 */
const char* zpdf_qpdf_report_message(const zpdf_qpdf_report* report);
const char* zpdf_qpdf_report_warnings(const zpdf_qpdf_report* report);

/* qpdf's own version string, e.g. "12.4.1". */
const char* zpdf_qpdf_version(void);
/* The compiled-in crypto provider. Must be "native" in this build. */
const char* zpdf_qpdf_crypto_provider(void);
/* 1 when the build has DCT (JPEG) filter support. 0 in this build. */
int32_t zpdf_qpdf_has_dct_support(void);

/*
 * Parse `input_path` and fill `out`. Writes nothing. `password` may be NULL.
 * Returns ZPDFQPDF_OK even for a damaged file that could be recovered; the
 * damage is reported in the inventory and in `report->warnings`.
 */
int32_t zpdf_qpdf_inspect(
    const char* input_path,
    const char* password,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    zpdf_qpdf_inventory* out,
    zpdf_qpdf_report* report);

/*
 * Read `input_path` (with recovery) and write a structurally rebuilt copy to
 * `output_path`. This is the repair operation; with ZPDFQPDF_WRITE_LINEARIZE it
 * is also the linearize operation, and without
 * ZPDFQPDF_WRITE_PRESERVE_ENCRYPTION it is also the decrypt operation.
 */
int32_t zpdf_qpdf_write_copy(
    const char* input_path,
    const char* password,
    const char* output_path,
    uint32_t write_flags,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    zpdf_qpdf_report* report);

/*
 * Write a new document containing only the given 0-based page indices, in the
 * given order. Duplicates are rejected (ZPDFQPDF_ERR_PAGE_RANGE) because a
 * duplicated page shares one object and silently produces a document whose page
 * count does not match the request.
 */
int32_t zpdf_qpdf_extract_pages(
    const char* input_path,
    const char* password,
    const char* output_path,
    const int32_t* page_indices,
    int32_t page_index_count,
    uint32_t write_flags,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    zpdf_qpdf_report* report);

/*
 * Split the input into consecutive groups of `pages_per_file` pages, written as
 * `<output_directory>/<basename>-NNNN.pdf` with NNNN starting at 0001. The
 * input is parsed once. On success `*out_file_count` receives the number of
 * files written. If any output path already exists, nothing is written at all.
 *
 * A failure or a cancellation part-way through removes every file the call had
 * already moved into place, so a split that does not finish leaves nothing
 * behind. `*out_file_count` then receives the number of files that had been
 * written before the failure — all of them removed again; a removal that fails
 * is reported in `report->warnings` — so the caller can tell how far it got.
 */
int32_t zpdf_qpdf_split_pages(
    const char* input_path,
    const char* password,
    const char* output_directory,
    const char* basename,
    int32_t pages_per_file,
    uint32_t write_flags,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    int32_t* out_file_count,
    zpdf_qpdf_report* report);

/*
 * Write each group of 0-based page indices as its own new document,
 * `<output_directory>/<basename>-NNNN.pdf` with NNNN starting at 0001, in group
 * order. The groups are the consecutive runs of `page_indices` whose lengths
 * `group_sizes` gives (`group_count` of them). The input is parsed once — the
 * point of this call: Split into Sheets writes one file per sheet, and opening
 * the drawing once per sheet dominated the time (NL-DOCS-08). Each file keeps
 * what zpdf_qpdf_extract_pages keeps. Output paths, cancellation, failure and
 * `*out_file_count` behave as in zpdf_qpdf_split_pages; a duplicate index
 * inside one group is rejected, and the same page may appear in several groups.
 */
int32_t zpdf_qpdf_extract_page_groups(
    const char* input_path,
    const char* password,
    const char* output_directory,
    const char* basename,
    const int32_t* page_indices,
    const int32_t* group_sizes,
    int32_t group_count,
    uint32_t write_flags,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    int32_t* out_file_count,
    zpdf_qpdf_report* report);

/*
 * Concatenate `input_count` documents into `output_path`, in order. `passwords`
 * may be NULL, or an array of `input_count` entries each of which may be NULL.
 */
int32_t zpdf_qpdf_merge(
    const char* const* input_paths,
    const char* const* passwords,
    int32_t input_count,
    const char* output_path,
    uint32_t write_flags,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    zpdf_qpdf_report* report);

/* ---- transform (flatten, compress, sanitize, encrypt) -------------------- */

#define ZPDFQPDF_OP_FLATTEN_ANNOTATIONS 0x0001u /* burn visible annotations and form fields into the pages */
#define ZPDFQPDF_OP_COMPRESS            0x0002u /* object streams, recompressed Flate, unreferenced resources dropped */
#define ZPDFQPDF_OP_SANITIZE            0x0004u /* drop JavaScript, embedded files, open/additional actions, metadata */
#define ZPDFQPDF_OP_ENCRYPT             0x0008u /* AES-256 (R6) with the passwords and permissions below */
#define ZPDFQPDF_OP_DOWNSAMPLE_IMAGES   0x0010u /* pictures above image_target_dpi handed to image_callback (NL-PDF-08) */

/* How an image's bytes are handed over, and how a replacement is written. */
#define ZPDFQPDF_IMAGE_DCT     1  /* the JPEG bytes of a /DCTDecode stream; a replacement is written /DCTDecode */
#define ZPDFQPDF_IMAGE_SAMPLES 2  /* decoded 8-bit samples, row-major, no padding; a replacement is written /FlateDecode */

/*
 * One picture the transform proposes to downsample: an image XObject with 8 bits
 * per component in DeviceGray, DeviceRGB or a one- or three-component ICCBased
 * space, no /Mask, no /Decode, not an image mask, and either /DCTDecode alone or
 * filters qpdf can fully decode. JBIG2, CCITT, JPX, inline images, masks and
 * anything else are never offered and never touched.
 *
 * `effective_dpi` is the LOWEST resolution at which the image is painted on any
 * page (the largest placement wins), measured by following q/Q/cm through the
 * page content and nested forms, and the page's /UserUnit. An image that is
 * never painted from page content, or sits on a page whose content could not be
 * parsed, is never offered.
 */
typedef struct zpdf_qpdf_image {
    int32_t object_number;
    int32_t generation;
    int32_t width;
    int32_t height;
    int32_t components;       /* 1 or 3 */
    int32_t encoding;         /* ZPDFQPDF_IMAGE_* */
    double  effective_dpi;
    const uint8_t* data;      /* valid only during the callback */
    size_t  length;
} zpdf_qpdf_image;

/*
 * What the callback puts in place of the image. `data` must come from malloc();
 * the shim takes ownership and frees it whether or not the replacement is
 * accepted. A replacement is refused (and the image left as it was) unless it is
 * strictly smaller in both dimensions and, for SAMPLES, exactly
 * width * height * components bytes long.
 */
typedef struct zpdf_qpdf_image_replacement {
    int32_t width;
    int32_t height;
    int32_t encoding;         /* ZPDFQPDF_IMAGE_* */
    int32_t reserved;
    uint8_t* data;
    size_t  length;
} zpdf_qpdf_image_replacement;

/* Return 1 after filling `out` to replace the image, 0 to leave it. */
typedef int32_t (*zpdf_qpdf_image_fn)(void* context, const zpdf_qpdf_image* image, zpdf_qpdf_image_replacement* out);

#define ZPDFQPDF_PRINT_NONE 0
#define ZPDFQPDF_PRINT_LOW  1
#define ZPDFQPDF_PRINT_FULL 2

/*
 * What one transform does. Operations apply in the order flatten, sanitize,
 * compress, encrypt. Encryption replaces whatever encryption the input had; an
 * encrypted input without ZPDFQPDF_OP_ENCRYPT is written decrypted (the caller
 * opened it with its password and asked for a changed copy).
 *
 * `user_password` may be NULL or empty (anyone may open, permissions still
 * bind); `owner_password` must be non-empty when ZPDFQPDF_OP_ENCRYPT is set and
 * must differ from the user password, or the call fails with
 * ZPDFQPDF_ERR_ARGUMENT — an owner password equal to the user password grants
 * every permission to everybody who can open the file.
 */
typedef struct zpdf_qpdf_transform {
    uint32_t operations;
    int32_t  allow_print;     /* ZPDFQPDF_PRINT_* */
    int32_t  allow_modify;    /* assemble pages and modify content */
    int32_t  allow_extract;   /* copy text and graphics (accessibility is always allowed) */
    int32_t  allow_annotate;  /* add annotations and fill forms */
    const char* user_password;
    const char* owner_password;
    double image_target_dpi;              /* ZPDFQPDF_OP_DOWNSAMPLE_IMAGES: pictures above 1.25x this are offered */
    zpdf_qpdf_image_fn image_callback;    /* required with ZPDFQPDF_OP_DOWNSAMPLE_IMAGES */
    void* image_context;
} zpdf_qpdf_transform;

/* Tallies of what a transform removed or changed. */
typedef struct zpdf_qpdf_transform_result {
    int32_t flattened_annotation_count;   /* annotations burned into page content */
    int32_t removed_javascript;           /* 1 when a /Names /JavaScript tree was removed */
    int32_t removed_embedded_files;       /* 1 when a /Names /EmbeddedFiles tree was removed */
    int32_t removed_actions;              /* /OpenAction, /AA and JavaScript /A entries removed */
    int32_t removed_metadata;             /* 1 when /Metadata or /Info was removed */
    int32_t downsampled_images;           /* pictures replaced at a lower resolution */
    int32_t offered_images;               /* pictures above the target handed to the callback */
    int32_t reserved;
} zpdf_qpdf_transform_result;

/*
 * Read `input_path` and write a transformed copy to `output_path`. The input is
 * never modified; the output contract is the same as zpdf_qpdf_write_copy's.
 * `write_flags` accepts LINEARIZE and DETERMINISTIC_ID (the latter is refused
 * with ENCRYPT). `result` may be NULL.
 */
int32_t zpdf_qpdf_transform_copy(
    const char* input_path,
    const char* password,
    const char* output_path,
    const zpdf_qpdf_transform* transform,
    uint32_t write_flags,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    zpdf_qpdf_transform_result* result,
    zpdf_qpdf_report* report);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ZPDF_QPDF_H */
