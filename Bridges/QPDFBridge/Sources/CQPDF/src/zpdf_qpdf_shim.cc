/*
 * zpdf_qpdf_shim.cc — the extern "C" implementation over vendored qpdf.
 *
 * Written by Zenit PDF; not upstream code. See VENDORED.md.
 *
 * Everything qpdf-shaped stays inside this file: no C++ type, no exception and
 * no std:: object ever crosses into Swift.
 */

#include "zpdf_qpdf.h"

#include <qpdf/Buffer.hh>
#include <qpdf/Pl_Discard.hh>
#include <qpdf/QPDF.hh>
#include <qpdf/QPDFAcroFormDocumentHelper.hh>
#include <qpdf/QPDFCryptoProvider.hh>
#include <qpdf/QPDFExc.hh>
#include <qpdf/QPDFObjectHandle.hh>
#include <qpdf/QPDFPageDocumentHelper.hh>
#include <qpdf/QPDFPageLabelDocumentHelper.hh>
#include <qpdf/QPDFPageObjectHelper.hh>
#include <qpdf/QPDFWriter.hh>
#include <qpdf/global.hh>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <exception>
#include <cmath>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <new>
#include <set>
#include <string>
#include <vector>

#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

namespace
{
    // ---- process-wide serialisation -------------------------------------
    //
    // qpdf's parser limits live in a process-global registry
    // (qpdf::global::limits), and QPDFCryptoProvider keeps a global provider
    // registry. Both are read during parsing. Serialising every entry point is
    // the only way to make per-call limits mean anything.
    std::mutex&
    global_lock()
    {
        static std::mutex m;
        return m;
    }

    // ---- cancellation ----------------------------------------------------

    struct Cancelled
    {
    };

    // A configured bound was exceeded. Distinct from a qpdf error so that the
    // caller can tell "this file is too big for the policy we set" apart from
    // "this file is broken".
    struct LimitExceeded
    {
        std::string why;
    };

    struct Canceller
    {
        zpdf_qpdf_cancel_fn fn{nullptr};
        void* ctx{nullptr};

        void
        check() const
        {
            if (fn && fn(ctx) != 0) {
                throw Cancelled{};
            }
        }
    };

    // ---- report ----------------------------------------------------------

    void
    set_message(zpdf_qpdf_report* r, std::string const& text)
    {
        if (!r) {
            return;
        }
        std::size_t n = text.size();
        if (n >= ZPDFQPDF_MESSAGE_CAPACITY) {
            n = ZPDFQPDF_MESSAGE_CAPACITY - 1;
        }
        std::memcpy(r->message, text.data(), n);
        r->message[n] = '\0';
    }

    void
    append_warning(zpdf_qpdf_report* r, std::string const& text)
    {
        if (!r) {
            return;
        }
        r->warning_count += 1;
        std::size_t used = std::strlen(r->warnings);
        std::size_t room = ZPDFQPDF_WARNINGS_CAPACITY - 1 - used;
        std::string line = text;
        if (used > 0) {
            line = "\n" + line;
        }
        if (line.size() > room) {
            r->warnings_truncated = 1;
            return;
        }
        std::memcpy(r->warnings + used, line.data(), line.size());
        r->warnings[used + line.size()] = '\0';
    }

    void
    init_report(zpdf_qpdf_report* r)
    {
        if (!r) {
            return;
        }
        r->status = ZPDFQPDF_OK;
        r->warning_count = 0;
        r->warnings_truncated = 0;
        r->reserved = 0;
        r->message[0] = '\0';
        r->warnings[0] = '\0';
    }

    int32_t
    fail(zpdf_qpdf_report* r, int32_t status, std::string const& text)
    {
        set_message(r, text);
        if (r) {
            r->status = status;
        }
        return status;
    }

    // ---- options ---------------------------------------------------------

    struct Options
    {
        int64_t max_input_bytes{1LL << 30};
        int32_t max_pages{20000};
        bool attempt_recovery{true};
        uint32_t doc_max_warnings{10000};
        // BH-410: doc_max_warnings is how many warnings the caller wants *collected*.
        // qpdf's own limit aborts the parse when exceeded, so it is kept at no less than
        // the default instead of being lowered with the collection cap.
        uint32_t abort_max_warnings{10000};
        uint32_t parser_max_errors{1000};
        uint32_t parser_max_nesting{200};
        uint32_t parser_max_container_size{5000000};
        uint32_t max_stream_filters{8};
        uint32_t flate_max_memory{512u * 1024u * 1024u};
        uint32_t png_max_memory{512u * 1024u * 1024u};
        uint32_t tiff_max_memory{512u * 1024u * 1024u};
        uint32_t run_length_max_memory{512u * 1024u * 1024u};
        bool ignore_xref_streams{false};
    };

    Options
    resolve(zpdf_qpdf_options const* in)
    {
        Options o;
        if (!in) {
            return o;
        }
        if (in->max_input_bytes > 0) {
            o.max_input_bytes = in->max_input_bytes;
        }
        if (in->max_pages > 0) {
            o.max_pages = in->max_pages;
        }
        o.attempt_recovery = (in->attempt_recovery >= 0);
        if (in->doc_max_warnings > 0) {
            o.doc_max_warnings = in->doc_max_warnings;
        }
        o.abort_max_warnings = o.doc_max_warnings > o.abort_max_warnings
            ? o.doc_max_warnings : o.abort_max_warnings;
        if (in->parser_max_errors > 0) {
            o.parser_max_errors = in->parser_max_errors;
        }
        if (in->parser_max_nesting > 0) {
            o.parser_max_nesting = in->parser_max_nesting;
        }
        if (in->parser_max_container_size > 0) {
            o.parser_max_container_size = in->parser_max_container_size;
        }
        if (in->max_stream_filters > 0) {
            o.max_stream_filters = in->max_stream_filters;
        }
        if (in->flate_max_memory > 0) {
            o.flate_max_memory = in->flate_max_memory;
        }
        if (in->png_max_memory > 0) {
            o.png_max_memory = in->png_max_memory;
        }
        if (in->tiff_max_memory > 0) {
            o.tiff_max_memory = in->tiff_max_memory;
        }
        if (in->run_length_max_memory > 0) {
            o.run_length_max_memory = in->run_length_max_memory;
        }
        o.ignore_xref_streams = (in->ignore_xref_streams != 0);
        return o;
    }

    void
    apply_global_limits(Options const& o)
    {
        namespace lim = qpdf::global::limits;
        lim::doc_max_warnings(o.abort_max_warnings);
        lim::parser_max_errors(o.parser_max_errors);
        lim::parser_max_nesting(o.parser_max_nesting);
        lim::parser_max_container_size(o.parser_max_container_size);
        lim::parser_max_container_size_damaged(o.parser_max_container_size);
        lim::max_stream_filters(o.max_stream_filters);
        lim::flate_max_memory(o.flate_max_memory);
        lim::png_max_memory(o.png_max_memory);
        lim::tiff_max_memory(o.tiff_max_memory);
        lim::run_length_max_memory(o.run_length_max_memory);
    }

    // ---- paths -----------------------------------------------------------

    bool
    nonempty(char const* s)
    {
        return s != nullptr && s[0] != '\0';
    }

    // Canonical identity of a path that need not exist yet: realpath() the
    // parent directory (which must exist) and append the last component. Two
    // paths that canonicalise the same name the same file.
    bool
    canonical_identity(std::string const& path, std::string& out, std::string& why)
    {
        if (path.empty()) {
            why = "empty path";
            return false;
        }
        std::string dir;
        std::string base;
        auto slash = path.find_last_of('/');
        if (slash == std::string::npos) {
            dir = ".";
            base = path;
        } else if (slash == 0) {
            dir = "/";
            base = path.substr(1);
        } else {
            dir = path.substr(0, slash);
            base = path.substr(slash + 1);
        }
        if (base.empty() || base == "." || base == "..") {
            why = "path does not name a file: " + path;
            return false;
        }
        char buf[PATH_MAX];
        if (::realpath(dir.c_str(), buf) == nullptr) {
            why = "directory does not exist: " + dir;
            return false;
        }
        out = std::string(buf);
        if (out.empty() || out.back() != '/') {
            out += '/';
        }
        out += base;
        return true;
    }

    bool
    readable_regular_file(std::string const& path, int64_t& size, std::string& why)
    {
        struct stat st{};
        if (::stat(path.c_str(), &st) != 0) {
            why = "cannot stat " + path + ": " + std::strerror(errno);
            return false;
        }
        if (!S_ISREG(st.st_mode)) {
            why = "not a regular file: " + path;
            return false;
        }
        if (::access(path.c_str(), R_OK) != 0) {
            why = "not readable: " + path;
            return false;
        }
        size = static_cast<int64_t>(st.st_size);
        return true;
    }

    bool
    path_exists(std::string const& path)
    {
        struct stat st{};
        return ::stat(path.c_str(), &st) == 0;
    }

    // The "never mutate the input" gate. Runs before qpdf is constructed.
    int32_t
    check_output(
        std::vector<std::string> const& input_identities,
        std::string const& output_path,
        std::string& output_identity,
        zpdf_qpdf_report* report)
    {
        std::string why;
        if (!canonical_identity(output_path, output_identity, why)) {
            return fail(report, ZPDFQPDF_ERR_ARGUMENT, why);
        }
        for (auto const& in: input_identities) {
            if (in == output_identity) {
                return fail(
                    report,
                    ZPDFQPDF_ERR_OUTPUT_CONFLICT,
                    "refusing to write output over its own input: " + output_identity);
            }
        }
        if (path_exists(output_identity)) {
            return fail(
                report,
                ZPDFQPDF_ERR_OUTPUT_CONFLICT,
                "output already exists; every operation writes a new file: " + output_identity);
        }
        return ZPDFQPDF_OK;
    }

    // ---- error mapping ---------------------------------------------------

    int32_t
    map_qpdf_exc(QPDFExc const& e, bool had_password)
    {
        switch (e.getErrorCode()) {
        case qpdf_e_password:
            return had_password ? ZPDFQPDF_ERR_PASSWORD_INCORRECT : ZPDFQPDF_ERR_PASSWORD_REQUIRED;
        case qpdf_e_system:
            return ZPDFQPDF_ERR_CANNOT_READ;
        case qpdf_e_unsupported:
            return ZPDFQPDF_ERR_UNSUPPORTED;
        case qpdf_e_pages:
            // BH-083: qpdf raises qpdf_e_pages for a broken /Pages tree (a loop, excessive
            // nesting, a missing /Kids), never for a caller's index — the shim's own
            // validate_indices reports those without passing through here. It is damage.
            return ZPDFQPDF_ERR_DAMAGED;
        case qpdf_e_internal:
            return ZPDFQPDF_ERR_INTERNAL;
        default:
            return ZPDFQPDF_ERR_DAMAGED;
        }
    }

    // ---- opening ----------------------------------------------------------

    struct OpenResult
    {
        std::shared_ptr<QPDF> pdf;
        int64_t file_size{0};
    };

    // Opens the input read-only, applying every bound. Throws QPDFExc,
    // Cancelled, or std::runtime_error on failure.
    OpenResult
    open_input(
        std::string const& path,
        char const* password,
        Options const& o,
        Canceller const& cancel,
        zpdf_qpdf_report* report)
    {
        cancel.check();
        OpenResult r;
        std::string why;
        if (!readable_regular_file(path, r.file_size, why)) {
            throw QPDFExc(qpdf_e_system, path, "", 0, why);
        }
        if (r.file_size > o.max_input_bytes) {
            throw LimitExceeded{
                "file is " + std::to_string(r.file_size) + " bytes, over the configured limit of " +
                std::to_string(o.max_input_bytes)};
        }
        r.pdf = QPDF::create();
        r.pdf->setSuppressWarnings(true);
        r.pdf->setMaxWarnings(o.abort_max_warnings);
        r.pdf->setAttemptRecovery(o.attempt_recovery);
        if (o.ignore_xref_streams) {
            r.pdf->setIgnoreXRefStreams(true);
        }
        r.pdf->processFile(path.c_str(), password);
        cancel.check();
        (void)report;
        return r;
    }

    // The collection cap for the call in progress (BH-410). Every entry point runs under
    // the shim's global mutex, so one slot is enough; set from Options by each entry.
    uint32_t g_collect_max_warnings = 10000;

    void
    drain_warnings(QPDF& pdf, zpdf_qpdf_report* report, zpdf_qpdf_inventory* inv)
    {
        for (auto const& w: pdf.getWarnings()) {
            std::string text = w.what();
            if (report && static_cast<uint32_t>(report->warning_count) >= g_collect_max_warnings) {
                report->warning_count += 1;
                report->warnings_truncated = 1;
            } else {
                append_warning(report, text);
            }
            if (!inv) {
                continue;
            }
            switch (w.getErrorCode()) {
            case qpdf_e_damaged_pdf:
                inv->damage_warning_count += 1;
                break;
            case qpdf_e_pages:
                inv->page_warning_count += 1;
                break;
            default:
                break;
            }
            // Upstream emits this exact string from Objects::reconstruct_xref
            // (QPDF_objects.cc:336). There is no public accessor for the flag,
            // so the string is the contract; VENDORED.md records that.
            if (text.find("reconstruct cross-reference table") != std::string::npos) {
                inv->xref_was_reconstructed = 1;
            }
        }
    }

    // The filters this build can actually decode. Deliberately written out
    // rather than asked of qpdf, because qpdf has no public "can you filter
    // this?" accessor and because the answer is a property of how this bridge
    // was compiled: /DCTDecode is missing here only because no libjpeg is
    // vendored. /CCITTFaxDecode and /JPXDecode are absent from upstream qpdf
    // itself. Abbreviations are the inline-image spellings qpdf also accepts.
    bool
    is_decodable_filter(std::string const& name)
    {
        return name == "/FlateDecode" || name == "/LZWDecode" || name == "/RunLengthDecode" ||
            name == "/ASCII85Decode" || name == "/ASCIIHexDecode" || name == "/Crypt" ||
            name == "/Fl" || name == "/LZW" || name == "/RL" || name == "/A85" || name == "/AHx";
    }

    // True when the stream declares at least one filter this build has no
    // decoder for. Distinguishes "qpdf has no decoder" from "qpdf refused to
    // decode", which look identical from pipeStreamData's return values but
    // mean completely different things: the first is normal, the second means
    // the data is damaged or hit a configured ceiling.
    bool
    declares_undecodable_filter(QPDFObjectHandle stream)
    {
        auto filter = stream.getDict().getKey("/Filter");
        if (filter.isName()) {
            return !is_decodable_filter(filter.getName());
        }
        if (filter.isArray()) {
            for (auto& item: filter.aitems()) {
                if (!item.isName() || !is_decodable_filter(item.getName())) {
                    return true;
                }
            }
        }
        return false;
    }

    // ---- writing ----------------------------------------------------------

    class CancelProgress: public QPDFWriter::ProgressReporter
    {
      public:
        explicit CancelProgress(Canceller const& c) :
            canceller(c)
        {
        }
        ~CancelProgress() override = default;
        void
        reportProgress(int) override
        {
            canceller.check();
        }

      private:
        Canceller canceller;
    };

    void
    configure_writer(QPDFWriter& w, uint32_t flags, Canceller const& cancel)
    {
        w.setPreserveEncryption((flags & ZPDFQPDF_WRITE_PRESERVE_ENCRYPTION) != 0);
        if (flags & ZPDFQPDF_WRITE_LINEARIZE) {
            w.setLinearization(true);
        }
        if (flags & ZPDFQPDF_WRITE_DETERMINISTIC_ID) {
            w.setDeterministicID(true);
        }
        if (flags & ZPDFQPDF_WRITE_QDF) {
            w.setQDFMode(true);
        }
        if (flags & ZPDFQPDF_WRITE_OBJECT_STREAMS_OFF) {
            w.setObjectStreamMode(qpdf_o_disable);
        }
        w.registerProgressReporter(std::make_shared<CancelProgress>(cancel));
    }

    // Repair step that qpdf itself does not perform.
    //
    // QPDFWriter::writeTrailer (QPDFWriter.cc:1484) writes the output trailer by
    // iterating the keys of the INPUT trailer, substituting the real object
    // count when it reaches "/Size". When a file is damaged badly enough that
    // qpdf cannot find a trailer at all -- the truncated fixture, where the
    // warning is "unable to find trailer dictionary while recovering damaged
    // file" -- the reconstructed trailer holds only /Root, so no /Size key is
    // ever visited and the output is written without one. /Size is required by
    // the PDF specification (ISO 32000-1 table 15), and CoreGraphics rejects the
    // file outright, which would make "repair" produce something no reader can
    // open.
    //
    // Seeding a placeholder makes the writer visit the key and emit the true
    // value. This touches the in-memory document only; the input file is not
    // opened for writing anywhere in this shim.
    void
    ensure_trailer_has_size(QPDF& pdf)
    {
        auto trailer = pdf.getTrailer();
        if (trailer.isDictionary() && !trailer.hasKey("/Size")) {
            trailer.replaceKey("/Size", QPDFObjectHandle::newInteger(0));
        }
    }

    // Writes to `identity + ".zpdf-partial"` and renames on success, so a failed
    // or cancelled write never leaves a readable half-file at the real path.
    void
    write_atomically(
        QPDF& pdf,
        std::string const& identity,
        uint32_t flags,
        Canceller const& cancel,
        std::function<void(QPDFWriter&)> const& extra = nullptr)
    {
        ensure_trailer_has_size(pdf);
        std::string temp = identity + ".zpdf-partial";
        if (path_exists(temp)) {
            throw std::runtime_error("temporary output already exists: " + temp);
        }
        try {
            QPDFWriter w(pdf, temp.c_str());
            configure_writer(w, flags, cancel);
            if (extra) {
                extra(w);
            }
            w.write();
        } catch (...) {
            ::unlink(temp.c_str());
            throw;
        }
        if (::rename(temp.c_str(), identity.c_str()) != 0) {
            std::string why = std::strerror(errno);
            ::unlink(temp.c_str());
            throw std::runtime_error("cannot move output into place: " + why);
        }
    }

    int32_t
    page_count_checked(QPDF& pdf, Options const& o)
    {
        auto const& pages = pdf.getAllPages();
        if (pages.size() > static_cast<std::size_t>(o.max_pages)) {
            throw LimitExceeded{
                "document has " + std::to_string(pages.size()) +
                " pages, over the configured limit of " + std::to_string(o.max_pages)};
        }
        return static_cast<int32_t>(pages.size());
    }

    // Every entry point funnels its exceptions through here so that no C++
    // exception can escape into Swift and no failure path can be forgotten.
    template <typename F>
    int32_t
    guarded(zpdf_qpdf_report* report, bool had_password, F&& body)
    {
        try {
            std::lock_guard<std::mutex> lock(global_lock());
            int32_t status = body();
            if (report) {
                report->status = status;
            }
            return status;
        } catch (Cancelled const&) {
            return fail(report, ZPDFQPDF_ERR_CANCELLED, "operation cancelled");
        } catch (LimitExceeded const& e) {
            return fail(report, ZPDFQPDF_ERR_LIMIT, e.why);
        } catch (QPDFExc const& e) {
            return fail(report, map_qpdf_exc(e, had_password), e.what());
        } catch (std::bad_alloc const&) {
            return fail(report, ZPDFQPDF_ERR_OUT_OF_MEMORY, "out of memory");
        } catch (std::exception const& e) {
            return fail(report, ZPDFQPDF_ERR_DAMAGED, e.what());
        } catch (...) {
            return fail(report, ZPDFQPDF_ERR_INTERNAL, "unknown C++ exception");
        }
    }
} // namespace

// ---- version -------------------------------------------------------------

extern "C" const char*
zpdf_qpdf_version(void)
{
    static std::string const v = QPDF::QPDFVersion();
    return v.c_str();
}

extern "C" const char*
zpdf_qpdf_crypto_provider(void)
{
    static std::string const p = []() -> std::string {
        try {
            return QPDFCryptoProvider::getDefaultProvider();
        } catch (...) {
            return "";
        }
    }();
    return p.c_str();
}

extern "C" const char*
zpdf_qpdf_report_message(const zpdf_qpdf_report* report)
{
    static char const empty[] = "";
    return report ? report->message : empty;
}

extern "C" const char*
zpdf_qpdf_report_warnings(const zpdf_qpdf_report* report)
{
    static char const empty[] = "";
    return report ? report->warnings : empty;
}

extern "C" int32_t
zpdf_qpdf_has_dct_support(void)
{
#ifdef ZPDF_QPDF_NO_DCT
    return 0;
#else
    return 1;
#endif
}

extern "C" void
zpdf_qpdf_options_defaults(zpdf_qpdf_options* out)
{
    if (!out) {
        return;
    }
    Options o;
    out->max_input_bytes = o.max_input_bytes;
    out->max_pages = o.max_pages;
    out->attempt_recovery = 0;
    out->doc_max_warnings = o.doc_max_warnings;
    out->parser_max_errors = o.parser_max_errors;
    out->parser_max_nesting = o.parser_max_nesting;
    out->parser_max_container_size = o.parser_max_container_size;
    out->max_stream_filters = o.max_stream_filters;
    out->flate_max_memory = o.flate_max_memory;
    out->png_max_memory = o.png_max_memory;
    out->tiff_max_memory = o.tiff_max_memory;
    out->run_length_max_memory = o.run_length_max_memory;
    out->ignore_xref_streams = 0;
}

// ---- inspect --------------------------------------------------------------

extern "C" int32_t
zpdf_qpdf_inspect(
    const char* input_path,
    const char* password,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    zpdf_qpdf_inventory* out,
    zpdf_qpdf_report* report)
{
    init_report(report);
    if (!nonempty(input_path) || out == nullptr) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "input_path and out are required");
    }
    std::memset(out, 0, sizeof(*out));
    bool had_password = nonempty(password);

    return guarded(report, had_password, [&]() -> int32_t {
        Options o = resolve(options);
        g_collect_max_warnings = o.doc_max_warnings;
        apply_global_limits(o);
        Canceller canceller{cancel, cancel_context};

        OpenResult opened = open_input(input_path, password, o, canceller, report);
        QPDF& pdf = *opened.pdf;
        out->file_size = opened.file_size;

        int R = 0;
        int P = 0;
        int V = 0;
        QPDF::encryption_method_e stream_method = QPDF::e_none;
        QPDF::encryption_method_e string_method = QPDF::e_none;
        QPDF::encryption_method_e file_method = QPDF::e_none;
        out->is_encrypted =
            pdf.isEncrypted(R, P, V, stream_method, string_method, file_method) ? 1 : 0;
        if (out->is_encrypted) {
            out->encryption_revision = R;
            out->encryption_permissions = P;
            // The true key length, not /Length, which lies on some files.
            out->encryption_key_bits = static_cast<int32_t>(pdf.getEncryptionKey().size() * 8);
            out->user_password_matched = pdf.userPasswordMatched() ? 1 : 0;
            out->owner_password_matched = pdf.ownerPasswordMatched() ? 1 : 0;
        }
        out->allow_accessibility = pdf.allowAccessibility() ? 1 : 0;
        out->allow_extract_all = pdf.allowExtractAll() ? 1 : 0;
        out->allow_print_low_res = pdf.allowPrintLowRes() ? 1 : 0;
        out->allow_print_high_res = pdf.allowPrintHighRes() ? 1 : 0;
        out->allow_modify_assembly = pdf.allowModifyAssembly() ? 1 : 0;
        out->allow_modify_form = pdf.allowModifyForm() ? 1 : 0;
        out->allow_modify_annotation = pdf.allowModifyAnnotation() ? 1 : 0;
        out->allow_modify_other = pdf.allowModifyOther() ? 1 : 0;
        out->allow_modify_all = pdf.allowModifyAll() ? 1 : 0;

        std::string version = pdf.getPDFVersion();
        auto dot = version.find('.');
        if (dot != std::string::npos) {
            try {
                out->pdf_version_major = std::stoi(version.substr(0, dot));
                out->pdf_version_minor = std::stoi(version.substr(dot + 1));
            } catch (std::exception const&) {
                out->pdf_version_major = 0;
                out->pdf_version_minor = 0;
            }
        }
        out->extension_level = pdf.getExtensionLevel();

        out->page_count = page_count_checked(pdf, o);
        canceller.check();

        out->is_linearized = pdf.isLinearized() ? 1 : 0;
        if (out->is_linearized) {
            // checkLinearization writes to the logger; warnings are suppressed
            // on this QPDF, and the boolean is all we report.
            out->linearization_is_valid = pdf.checkLinearization() ? 1 : 0;
        }

        // Walk every object once: count streams, and try to decode each one so
        // that "damage" means more than "the xref was wrong".
        auto objects = pdf.getAllObjects();
        out->object_count = static_cast<int64_t>(objects.size());
        int64_t seen = 0;
        for (auto& obj: objects) {
            if ((++seen % 256) == 0) {
                canceller.check();
            }
            if (!obj.isStream()) {
                continue;
            }
            out->stream_count += 1;
            Pl_Discard discard;
            bool filtering_attempted = false;
            bool ok = false;
            try {
                ok = obj.pipeStreamData(
                    &discard, &filtering_attempted, 0, qpdf_dl_generalized, true, false);
            } catch (Cancelled const&) {
                throw;
            } catch (std::exception const&) {
                ok = false;
            }
            if (!filtering_attempted) {
                if (declares_undecodable_filter(obj)) {
                    // No decoder exists for one of the declared filters — in
                    // this build that means /DCTDecode. The stream is copied
                    // through byte for byte on write; it is not damage.
                    out->unfilterable_stream_count += 1;
                } else {
                    // Every declared filter is one qpdf can decode, so qpdf
                    // declined for another reason: corrupt data, or one of the
                    // configured memory ceilings. That is a finding.
                    out->undecodable_stream_count += 1;
                }
            } else if (!ok) {
                out->undecodable_stream_count += 1;
            }
        }

        drain_warnings(pdf, report, out);
        if (out->undecodable_stream_count > 0 && out->damage_warning_count == 0) {
            out->damage_warning_count = out->undecodable_stream_count;
        }
        return ZPDFQPDF_OK;
    });
}

// ---- write copy -----------------------------------------------------------

extern "C" int32_t
zpdf_qpdf_write_copy(
    const char* input_path,
    const char* password,
    const char* output_path,
    uint32_t write_flags,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    zpdf_qpdf_report* report)
{
    init_report(report);
    if (!nonempty(input_path) || !nonempty(output_path)) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "input_path and output_path are required");
    }
    bool had_password = nonempty(password);

    return guarded(report, had_password, [&]() -> int32_t {
        std::string in_identity;
        std::string why;
        if (!canonical_identity(input_path, in_identity, why)) {
            return fail(report, ZPDFQPDF_ERR_CANNOT_READ, why);
        }
        std::string out_identity;
        int32_t gate = check_output({in_identity}, output_path, out_identity, report);
        if (gate != ZPDFQPDF_OK) {
            return gate;
        }

        Options o = resolve(options);
        g_collect_max_warnings = o.doc_max_warnings;
        apply_global_limits(o);
        Canceller canceller{cancel, cancel_context};

        OpenResult opened = open_input(in_identity, password, o, canceller, report);
        QPDF& pdf = *opened.pdf;
        (void)page_count_checked(pdf, o);

        write_atomically(pdf, out_identity, write_flags, canceller);
        drain_warnings(pdf, report, nullptr);
        return ZPDFQPDF_OK;
    });
}

// ---- extract pages ---------------------------------------------------------

namespace
{
    // Builds a new document from selected pages of `source`. `source` must
    // outlive `dest`.
    //
    // NL-DOCS-08: the copy keeps what a sheet is known by and what its layers
    // are — the source's page labels for the pages taken, renumbered for their
    // new positions, and the document's optional-content definitions
    // (/OCProperties), so layered content keeps its layer panel — and the named
    // destinations of the pages taken, so the links on them still land. The page
    // objects, the layer groups and the destinations are copied through one
    // foreign-object map, so all refer to the same new objects. The outline
    // (bookmarks) is not carried.
    //
    // Called once per source when several are merged: the labels continue from
    // the pages already in `dest` (a source without labels numbering its pages
    // as decimals from there), and each source's layer groups join the
    // destination's lists.
    void
    append_array_items(QPDFObjectHandle target, std::string const& key, QPDFObjectHandle from)
    {
        QPDFObjectHandle items = from.getKey(key);
        if (!items.isArray()) {
            return;
        }
        QPDFObjectHandle existing = target.getKey(key);
        if (!existing.isArray()) {
            target.replaceKey(key, items);
            return;
        }
        for (auto& item: items.getArrayAsVector()) {
            existing.appendItem(item);
        }
    }

    // ---- named destinations (it1r NL-DOCS-08) ----
    //
    // A drawing names places in itself two ways: the PDF 1.1 catalog /Dests
    // dictionary (keys are PDF names) and the /Names /Dests name tree (keys are
    // byte strings). A link on a page names one — `/Dest /detail`,
    // `/Dest (detail)`, or a GoTo action's /D — so a copy that leaves them
    // behind keeps links that point nowhere. The copy carries every named
    // destination whose page it takes, through the same foreign-object map as
    // the pages, so each lands on the copied page.

    // At most this many named destinations are read from one source: far past
    // any drawing set, and a bound on a hostile name tree.
    constexpr std::size_t max_named_destinations = 1000000;

    // A destination's explicit form: the array itself, or the /D of the
    // dictionary form (PDF 1.1's << /D [...] >>, whose other keys are dropped so
    // nothing but the page is pulled into the copy).
    QPDFObjectHandle
    explicit_destination(QPDFObjectHandle value)
    {
        if (value.isDictionary()) {
            value = value.getKey("/D");
        }
        return value.isArray() ? value : QPDFObjectHandle::newNull();
    }

    bool
    targets_taken_page(QPDFObjectHandle const& destination, std::set<QPDFObjGen> const& taken)
    {
        if (!destination.isArray() || destination.getArrayNItems() < 1) {
            return false;
        }
        QPDFObjectHandle page = destination.getArrayItem(0);
        return page.isIndirect() && taken.count(page.getObjGen()) > 0;
    }

    // Every entry of a name tree, keys as their raw bytes (not re-encoded, so a
    // link's string still matches). Loops, depth and size are bounded.
    void
    collect_name_tree(
        QPDFObjectHandle node,
        std::map<std::string, QPDFObjectHandle>& out,
        std::set<QPDFObjGen>& seen,
        int depth,
        Canceller const& cancel)
    {
        if (depth > 64 || !node.isDictionary()) {
            return;
        }
        if (node.isIndirect() && !seen.insert(node.getObjGen()).second) {
            return;
        }
        cancel.check();
        QPDFObjectHandle names = node.getKey("/Names");
        if (names.isArray()) {
            int count = names.getArrayNItems();
            for (int i = 0; i + 1 < count && out.size() < max_named_destinations; i += 2) {
                QPDFObjectHandle key = names.getArrayItem(i);
                if (key.isString()) {
                    out.emplace(key.getStringValue(), names.getArrayItem(i + 1));
                }
            }
        }
        QPDFObjectHandle kids = node.getKey("/Kids");
        if (kids.isArray()) {
            for (auto& kid: kids.getArrayAsVector()) {
                if (out.size() >= max_named_destinations) {
                    return;
                }
                collect_name_tree(kid, out, seen, depth + 1, cancel);
            }
        }
    }

    // Points `holder[key]` at its renamed destination when it names one this
    // source carried. Returns false when it names a destination this source did
    // not carry: in a merge that name could resolve to another source's
    // destination of the same name (S-066), in an extract it resolves to nothing.
    // An explicit destination (an array) or no reference at all is left as it is.
    bool
    retarget_reference(
        QPDFObjectHandle holder,
        std::string const& key,
        std::map<std::string, QPDFObjectHandle> const& carried_names,
        std::map<std::string, QPDFObjectHandle> const& carried_strings,
        std::map<std::string, std::string> const& renamed_names,
        std::map<std::string, std::string> const& renamed_strings)
    {
        QPDFObjectHandle reference = holder.getKey(key);
        if (reference.isName()) {
            std::string const name = reference.getName();
            if (carried_names.count(name) == 0) {
                return false;
            }
            auto found = renamed_names.find(name);
            if (found != renamed_names.end()) {
                holder.replaceKey(key, QPDFObjectHandle::newName(found->second));
            }
        } else if (reference.isString()) {
            std::string const name = reference.getStringValue();
            if (carried_strings.count(name) == 0) {
                return false;
            }
            auto found = renamed_strings.find(name);
            if (found != renamed_strings.end()) {
                holder.replaceKey(key, QPDFObjectHandle::newString(found->second));
            }
        }
        return true;
    }

    // Writes `names` (catalog /Dests) and `strings` (the /Names /Dests tree) into
    // `dest`, renaming a key an earlier source already uses; records each rename.
    void
    carry_destinations(
        QPDF& source,
        QPDF& dest,
        std::map<std::string, QPDFObjectHandle> const& names,
        std::map<std::string, QPDFObjectHandle> const& strings,
        std::map<std::string, std::string>& renamed_names,
        std::map<std::string, std::string>& renamed_strings,
        Canceller const& cancel)
    {
        // One copy for all of them: the pages they name were copied by addPage,
        // so the map sends each destination to its copied page.
        QPDFObjectHandle name_values = QPDFObjectHandle::newDictionary();
        for (auto& entry: names) {
            name_values.replaceKey(entry.first, entry.second);
        }
        QPDFObjectHandle string_values = QPDFObjectHandle::newArray();
        for (auto& entry: strings) {
            string_values.appendItem(QPDFObjectHandle::newString(entry.first));
            string_values.appendItem(entry.second);
        }
        QPDFObjectHandle container = QPDFObjectHandle::newDictionary();
        container.replaceKey("/N", name_values);
        container.replaceKey("/S", string_values);
        QPDFObjectHandle copied = dest.copyForeignObject(source.makeIndirectObject(container));

        QPDFObjectHandle dest_root = dest.getRoot();
        if (!names.empty()) {
            QPDFObjectHandle target = dest_root.getKey("/Dests");
            if (!target.isDictionary()) {
                target = dest.makeIndirectObject(QPDFObjectHandle::newDictionary());
                dest_root.replaceKey("/Dests", target);
            }
            QPDFObjectHandle values = copied.getKey("/N");
            for (auto const& key: values.getKeys()) {
                std::string name = key;
                for (int n = 2; target.hasKey(name); ++n) {
                    name = key + "-" + std::to_string(n);
                }
                if (name != key) {
                    renamed_names.emplace(key, name);
                }
                target.replaceKey(name, values.getKey(key));
            }
        }
        if (!strings.empty()) {
            // The copy's name tree is one flat, sorted /Names array; a source merged
            // before this one may have started it.
            std::map<std::string, QPDFObjectHandle> tree;
            QPDFObjectHandle existing_names = dest_root.getKey("/Names");
            if (existing_names.isDictionary()) {
                std::set<QPDFObjGen> seen;
                collect_name_tree(existing_names.getKey("/Dests"), tree, seen, 0, cancel);
            }
            QPDFObjectHandle values = copied.getKey("/S");
            int count = values.getArrayNItems();
            for (int i = 0; i + 1 < count; i += 2) {
                std::string key = values.getArrayItem(i).getStringValue();
                std::string name = key;
                for (int n = 2; tree.count(name) > 0; ++n) {
                    name = key + "-" + std::to_string(n);
                }
                if (name != key) {
                    renamed_strings.emplace(key, name);
                }
                tree.emplace(name, values.getArrayItem(i + 1));
            }
            QPDFObjectHandle flat = QPDFObjectHandle::newArray();
            for (auto& entry: tree) {
                flat.appendItem(QPDFObjectHandle::newString(entry.first));
                flat.appendItem(entry.second);
            }
            QPDFObjectHandle node = QPDFObjectHandle::newDictionary();
            node.replaceKey("/Names", flat);
            if (!existing_names.isDictionary()) {
                existing_names = QPDFObjectHandle::newDictionary();
                dest_root.replaceKey("/Names", existing_names);
            }
            existing_names.replaceKey("/Dests", dest.makeIndirectObject(node));
        }
    }

    // The links on this source's pages (from `first_position` on): a name the
    // source carried follows its rename; a `/Dest` or GoTo action naming one it
    // did not carry is removed, leaving a link that goes nowhere rather than one
    // that lands on another drawing's sheet (S-066). Each annotation and action
    // is decided once, so a rename is not renamed again and an action shared by
    // two links is removed from both.
    void
    retarget_links(
        QPDF& dest,
        long long first_position,
        std::map<std::string, QPDFObjectHandle> const& names,
        std::map<std::string, QPDFObjectHandle> const& strings,
        std::map<std::string, std::string> const& renamed_names,
        std::map<std::string, std::string> const& renamed_strings,
        Canceller const& cancel)
    {
        std::set<QPDFObjGen> visited;
        std::map<QPDFObjGen, bool> action_lands;
        auto pages = QPDFPageDocumentHelper(dest).getAllPages();
        for (std::size_t i = static_cast<std::size_t>(first_position); i < pages.size(); ++i) {
            cancel.check();
            QPDFObjectHandle annotations = pages[i].getObjectHandle().getKey("/Annots");
            if (!annotations.isArray()) {
                continue;
            }
            for (auto& annotation: annotations.getArrayAsVector()) {
                if (!annotation.isDictionary() ||
                    (annotation.isIndirect() && !visited.insert(annotation.getObjGen()).second)) {
                    continue;
                }
                if (!retarget_reference(annotation, "/Dest", names, strings, renamed_names, renamed_strings)) {
                    annotation.removeKey("/Dest");
                }
                QPDFObjectHandle action = annotation.getKey("/A");
                if (!action.isDictionary() || !action.getKey("/S").isNameAndEquals("/GoTo")) {
                    continue;
                }
                bool lands = true;
                if (action.isIndirect()) {
                    auto decided = action_lands.find(action.getObjGen());
                    if (decided != action_lands.end()) {
                        lands = decided->second;
                    } else {
                        lands = retarget_reference(action, "/D", names, strings, renamed_names, renamed_strings);
                        action_lands.emplace(action.getObjGen(), lands);
                    }
                } else {
                    lands = retarget_reference(action, "/D", names, strings, renamed_names, renamed_strings);
                }
                if (!lands) {
                    annotation.removeKey("/A");
                }
            }
        }
    }

    // Carries the named destinations of the pages taken from `source` (already
    // added to `dest` from position `first_position` on). A name a source merged
    // earlier already uses is renamed, and the links on this source's pages
    // follow it; a link naming a destination this source did not carry loses
    // that name, so no link lands in another drawing.
    void
    carry_named_destinations(
        QPDF& source,
        QPDF& dest,
        std::set<QPDFObjGen> const& taken,
        long long first_position,
        Canceller const& cancel)
    {
        QPDFObjectHandle root = source.getRoot();
        std::map<std::string, QPDFObjectHandle> names;
        QPDFObjectHandle dests = root.getKey("/Dests");
        if (dests.isDictionary()) {
            for (auto const& key: dests.getKeys()) {
                if (names.size() >= max_named_destinations) {
                    break;
                }
                QPDFObjectHandle destination = explicit_destination(dests.getKey(key));
                if (targets_taken_page(destination, taken)) {
                    names.emplace(key, destination);
                }
            }
        }
        std::map<std::string, QPDFObjectHandle> strings;
        QPDFObjectHandle name_dictionary = root.getKey("/Names");
        if (name_dictionary.isDictionary()) {
            std::map<std::string, QPDFObjectHandle> tree;
            std::set<QPDFObjGen> seen;
            collect_name_tree(name_dictionary.getKey("/Dests"), tree, seen, 0, cancel);
            for (auto& entry: tree) {
                QPDFObjectHandle destination = explicit_destination(entry.second);
                if (targets_taken_page(destination, taken)) {
                    strings.emplace(entry.first, destination);
                }
            }
        }
        std::map<std::string, std::string> renamed_names;
        std::map<std::string, std::string> renamed_strings;
        if (!names.empty() || !strings.empty()) {
            carry_destinations(source, dest, names, strings, renamed_names, renamed_strings, cancel);
        }
        retarget_links(dest, first_position, names, strings, renamed_names, renamed_strings, cancel);
    }

    void
    assemble(
        QPDF& source,
        QPDF& dest,
        std::vector<int32_t> const& indices,
        Canceller const& cancel)
    {
        QPDFPageDocumentHelper src_pages(source);
        auto all = src_pages.getAllPages();
        QPDFPageDocumentHelper dst_pages(dest);
        long long first_position = static_cast<long long>(dst_pages.getAllPages().size());
        std::set<QPDFObjGen> taken;
        for (auto index: indices) {
            cancel.check();
            auto& page = all.at(static_cast<std::size_t>(index));
            taken.insert(page.getObjectHandle().getObjGen());
            dst_pages.addPage(page, false);
        }
        carry_named_destinations(source, dest, taken, first_position, cancel);

        QPDFPageLabelDocumentHelper labels(source);
        QPDFObjectHandle existing_labels = dest.getRoot().getKey("/PageLabels");
        bool dest_has_labels = existing_labels.isDictionary() && existing_labels.getKey("/Nums").isArray();
        if (labels.hasPageLabels() || dest_has_labels) {
            std::vector<QPDFObjectHandle> new_labels;
            if (!dest_has_labels && first_position > 0) {
                // Pages merged before this source had no labels: they read as decimals.
                new_labels.push_back(QPDFObjectHandle::newInteger(0));
                new_labels.push_back(QPDFObjectHandle::parse("<< /S /D >>"));
            }
            if (labels.hasPageLabels()) {
                long long position = first_position;
                for (auto index: indices) {
                    cancel.check();
                    labels.getLabelsForPageRange(index, index, position, new_labels);
                    ++position;
                }
            } else {
                // A source without labels: its pages read as decimals, continuing from
                // where they start. (qpdf's fabricated entry names no style, and a label
                // with no style has no number at all.)
                new_labels.push_back(QPDFObjectHandle::newInteger(first_position));
                new_labels.push_back(QPDFObjectHandle::parse(
                    "<< /S /D /St " + std::to_string(first_position + 1) + " >>"));
            }
            if (dest_has_labels) {
                QPDFObjectHandle nums = existing_labels.getKey("/Nums");
                for (auto& item: new_labels) {
                    nums.appendItem(item);
                }
            } else {
                QPDFObjectHandle page_labels = QPDFObjectHandle::newDictionary();
                page_labels.replaceKey("/Nums", QPDFObjectHandle::newArray(new_labels));
                dest.getRoot().replaceKey("/PageLabels", page_labels);
            }
        }

        QPDFObjectHandle optional_content = source.getRoot().getKey("/OCProperties");
        if (optional_content.isDictionary()) {
            if (!optional_content.isIndirect()) {
                optional_content = source.makeIndirectObject(optional_content);
            }
            QPDFObjectHandle copied = dest.copyForeignObject(optional_content);
            QPDFObjectHandle existing = dest.getRoot().getKey("/OCProperties");
            if (!existing.isDictionary()) {
                dest.getRoot().replaceKey("/OCProperties", copied);
            } else {
                append_array_items(existing, "/OCGs", copied);
                QPDFObjectHandle defaults = existing.getKey("/D");
                QPDFObjectHandle more = copied.getKey("/D");
                if (defaults.isDictionary() && more.isDictionary()) {
                    for (auto const& key: {"/Order", "/ON", "/OFF", "/Locked"}) {
                        append_array_items(defaults, key, more);
                    }
                }
            }
        }
    }

    // The output keeps at least the version of every source it was made from:
    // a new document starts at PDF 1.3, and a 1.3 file's layer definitions are
    // ignored by readers (optional content is PDF 1.5).
    std::function<void(QPDFWriter&)>
    keep_versions(std::vector<QPDF*> const& sources)
    {
        return [sources](QPDFWriter& w) {
            for (auto* source: sources) {
                w.setMinimumPDFVersion(source->getPDFVersion(), source->getExtensionLevel());
            }
        };
    }

    int32_t
    validate_indices(
        std::vector<int32_t> const& indices, int32_t page_count, zpdf_qpdf_report* report)
    {
        std::set<int32_t> seen;
        for (auto index: indices) {
            if (index < 0 || index >= page_count) {
                return fail(
                    report,
                    ZPDFQPDF_ERR_PAGE_RANGE,
                    "page index " + std::to_string(index) + " is outside 0..." +
                        std::to_string(page_count - 1));
            }
            if (!seen.insert(index).second) {
                return fail(
                    report,
                    ZPDFQPDF_ERR_PAGE_RANGE,
                    "page index " + std::to_string(index) + " appears more than once");
            }
        }
        return ZPDFQPDF_OK;
    }
} // namespace

extern "C" int32_t
zpdf_qpdf_extract_pages(
    const char* input_path,
    const char* password,
    const char* output_path,
    const int32_t* page_indices,
    int32_t page_index_count,
    uint32_t write_flags,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    zpdf_qpdf_report* report)
{
    init_report(report);
    if (!nonempty(input_path) || !nonempty(output_path)) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "input_path and output_path are required");
    }
    if (page_indices == nullptr || page_index_count <= 0) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "at least one page index is required");
    }
    bool had_password = nonempty(password);

    return guarded(report, had_password, [&]() -> int32_t {
        std::string in_identity;
        std::string why;
        if (!canonical_identity(input_path, in_identity, why)) {
            return fail(report, ZPDFQPDF_ERR_CANNOT_READ, why);
        }
        std::string out_identity;
        int32_t gate = check_output({in_identity}, output_path, out_identity, report);
        if (gate != ZPDFQPDF_OK) {
            return gate;
        }

        Options o = resolve(options);
        g_collect_max_warnings = o.doc_max_warnings;
        apply_global_limits(o);
        Canceller canceller{cancel, cancel_context};

        OpenResult opened = open_input(in_identity, password, o, canceller, report);
        QPDF& pdf = *opened.pdf;
        int32_t page_count = page_count_checked(pdf, o);

        std::vector<int32_t> indices(
            page_indices, page_indices + static_cast<std::size_t>(page_index_count));
        int32_t bad = validate_indices(indices, page_count, report);
        if (bad != ZPDFQPDF_OK) {
            return bad;
        }

        auto dest = QPDF::create();
        dest->emptyPDF();
        assemble(pdf, *dest, indices, canceller);
        write_atomically(*dest, out_identity, write_flags, canceller, keep_versions({&pdf}));
        drain_warnings(pdf, report, nullptr);
        return ZPDFQPDF_OK;
    });
}

// ---- page groups (split, extract page groups) -------------------------------

namespace
{
    // At most this many files from one call, and this many page indices in all:
    // far past a drawing set, and a bound on what a request can ask for.
    constexpr int32_t max_page_groups = 100000;
    constexpr long long max_page_group_indices = 10000000;

    // Writes each group of pages of `pdf` as `<directory>/<basename>-NNNN.pdf`,
    // NNNN from 0001, with the input parsed once. Every output path is gated
    // before any file is written, so a collision on the last group cannot leave
    // the first groups on disk; a failure or a cancellation part-way through
    // removes the files already moved into place, and *out_file_count carries
    // how far the call had got (CR-129).
    int32_t
    write_page_groups(
        QPDF& pdf,
        std::string const& in_identity,
        std::vector<std::vector<int32_t>> const& groups,
        std::string dir,
        std::string const& basename,
        uint32_t write_flags,
        Canceller const& canceller,
        int32_t* out_file_count,
        zpdf_qpdf_report* report)
    {
        if (groups.empty()) {
            return fail(report, ZPDFQPDF_ERR_PAGE_RANGE, "document has no pages");
        }
        if (dir.back() != '/') {
            dir += '/';
        }
        std::vector<std::string> outputs;
        outputs.reserve(groups.size());
        for (std::size_t g = 0; g < groups.size(); ++g) {
            char suffix[16];
            std::snprintf(suffix, sizeof(suffix), "-%04d.pdf", static_cast<int>(g + 1));
            std::string identity;
            int32_t gate = check_output({in_identity}, dir + basename + suffix, identity, report);
            if (gate != ZPDFQPDF_OK) {
                return gate;
            }
            outputs.push_back(identity);
        }
        std::vector<std::string> promoted;
        promoted.reserve(groups.size());
        try {
            for (std::size_t g = 0; g < groups.size(); ++g) {
                canceller.check();
                auto dest = QPDF::create();
                dest->emptyPDF();
                assemble(pdf, *dest, groups[g], canceller);
                write_atomically(*dest, outputs[g], write_flags, canceller, keep_versions({&pdf}));
                promoted.push_back(outputs[g]);
                if (out_file_count) {
                    *out_file_count = static_cast<int32_t>(g + 1);
                }
            }
        } catch (...) {
            for (auto const& path: promoted) {
                if (::unlink(path.c_str()) != 0 && errno != ENOENT) {
                    append_warning(
                        report, "could not remove split output " + path + ": " + std::strerror(errno));
                }
            }
            throw;
        }
        return ZPDFQPDF_OK;
    }
} // namespace

// ---- split -----------------------------------------------------------------

extern "C" int32_t
zpdf_qpdf_split_pages(
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
    zpdf_qpdf_report* report)
{
    init_report(report);
    if (out_file_count) {
        *out_file_count = 0;
    }
    if (!nonempty(input_path) || !nonempty(output_directory) || !nonempty(basename)) {
        return fail(
            report,
            ZPDFQPDF_ERR_ARGUMENT,
            "input_path, output_directory and basename are required");
    }
    if (pages_per_file <= 0) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "pages_per_file must be positive");
    }
    if (std::strchr(basename, '/') != nullptr) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "basename must not contain a path separator");
    }
    bool had_password = nonempty(password);

    return guarded(report, had_password, [&]() -> int32_t {
        std::string in_identity;
        std::string why;
        if (!canonical_identity(input_path, in_identity, why)) {
            return fail(report, ZPDFQPDF_ERR_CANNOT_READ, why);
        }

        Options o = resolve(options);
        g_collect_max_warnings = o.doc_max_warnings;
        apply_global_limits(o);
        Canceller canceller{cancel, cancel_context};

        OpenResult opened = open_input(in_identity, password, o, canceller, report);
        QPDF& pdf = *opened.pdf;
        int32_t page_count = page_count_checked(pdf, o);
        if (page_count == 0) {
            return fail(report, ZPDFQPDF_ERR_PAGE_RANGE, "document has no pages");
        }

        std::vector<std::vector<int32_t>> groups;
        // In 64 bits: `first + pages_per_file` near INT32_MAX must not wrap.
        for (long long first = 0; first < page_count; first += pages_per_file) {
            std::vector<int32_t> indices;
            for (long long index = first; index < page_count && index < first + pages_per_file; ++index) {
                indices.push_back(static_cast<int32_t>(index));
            }
            groups.push_back(indices);
        }
        int32_t written = write_page_groups(
            pdf, in_identity, groups, output_directory, basename, write_flags, canceller,
            out_file_count, report);
        if (written != ZPDFQPDF_OK) {
            return written;
        }
        drain_warnings(pdf, report, nullptr);
        return ZPDFQPDF_OK;
    });
}

// ---- extract page groups ---------------------------------------------------

extern "C" int32_t
zpdf_qpdf_extract_page_groups(
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
    zpdf_qpdf_report* report)
{
    init_report(report);
    if (out_file_count) {
        *out_file_count = 0;
    }
    if (!nonempty(input_path) || !nonempty(output_directory) || !nonempty(basename)) {
        return fail(
            report,
            ZPDFQPDF_ERR_ARGUMENT,
            "input_path, output_directory and basename are required");
    }
    if (std::strchr(basename, '/') != nullptr) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "basename must not contain a path separator");
    }
    if (page_indices == nullptr || group_sizes == nullptr || group_count <= 0 ||
        group_count > max_page_groups) {
        return fail(
            report,
            ZPDFQPDF_ERR_ARGUMENT,
            "between 1 and " + std::to_string(max_page_groups) + " page groups are required");
    }
    std::vector<std::vector<int32_t>> groups;
    groups.reserve(static_cast<std::size_t>(group_count));
    long long offset = 0;
    for (int32_t g = 0; g < group_count; ++g) {
        int32_t size = group_sizes[g];
        if (size <= 0 || offset + size > max_page_group_indices) {
            return fail(report, ZPDFQPDF_ERR_ARGUMENT, "every page group needs at least one page");
        }
        groups.emplace_back(page_indices + offset, page_indices + offset + size);
        offset += size;
    }
    bool had_password = nonempty(password);

    return guarded(report, had_password, [&]() -> int32_t {
        std::string in_identity;
        std::string why;
        if (!canonical_identity(input_path, in_identity, why)) {
            return fail(report, ZPDFQPDF_ERR_CANNOT_READ, why);
        }

        Options o = resolve(options);
        g_collect_max_warnings = o.doc_max_warnings;
        apply_global_limits(o);
        Canceller canceller{cancel, cancel_context};

        OpenResult opened = open_input(in_identity, password, o, canceller, report);
        QPDF& pdf = *opened.pdf;
        int32_t page_count = page_count_checked(pdf, o);
        for (auto const& group: groups) {
            int32_t bad = validate_indices(group, page_count, report);
            if (bad != ZPDFQPDF_OK) {
                return bad;
            }
        }
        int32_t written = write_page_groups(
            pdf, in_identity, groups, output_directory, basename, write_flags, canceller,
            out_file_count, report);
        if (written != ZPDFQPDF_OK) {
            return written;
        }
        drain_warnings(pdf, report, nullptr);
        return ZPDFQPDF_OK;
    });
}

// ---- merge -----------------------------------------------------------------

extern "C" int32_t
zpdf_qpdf_merge(
    const char* const* input_paths,
    const char* const* passwords,
    int32_t input_count,
    const char* output_path,
    uint32_t write_flags,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    zpdf_qpdf_report* report)
{
    init_report(report);
    if (input_paths == nullptr || input_count <= 0) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "at least one input is required");
    }
    if (!nonempty(output_path)) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "output_path is required");
    }
    bool had_password = false;
    for (int32_t i = 0; i < input_count; ++i) {
        if (passwords && nonempty(passwords[i])) {
            had_password = true;
        }
    }

    return guarded(report, had_password, [&]() -> int32_t {
        std::vector<std::string> identities;
        identities.reserve(static_cast<std::size_t>(input_count));
        for (int32_t i = 0; i < input_count; ++i) {
            if (!nonempty(input_paths[i])) {
                return fail(
                    report, ZPDFQPDF_ERR_ARGUMENT, "input " + std::to_string(i) + " is empty");
            }
            std::string identity;
            std::string why;
            if (!canonical_identity(input_paths[i], identity, why)) {
                return fail(report, ZPDFQPDF_ERR_CANNOT_READ, why);
            }
            identities.push_back(identity);
        }
        std::string out_identity;
        int32_t gate = check_output(identities, output_path, out_identity, report);
        if (gate != ZPDFQPDF_OK) {
            return gate;
        }

        Options o = resolve(options);
        g_collect_max_warnings = o.doc_max_warnings;
        apply_global_limits(o);
        Canceller canceller{cancel, cancel_context};

        // Every source must stay alive until the destination is written,
        // because copyForeignObject keeps reading from it.
        std::vector<std::shared_ptr<QPDF>> sources;
        sources.reserve(static_cast<std::size_t>(input_count));
        auto dest = QPDF::create();
        dest->emptyPDF();

        int64_t total_pages = 0;
        for (int32_t i = 0; i < input_count; ++i) {
            canceller.check();
            char const* pw = (passwords != nullptr) ? passwords[i] : nullptr;
            // BH-406: whether *this* source carried a password decides required vs
            // incorrect; one flag over all sources told a user their password was rejected
            // for a file they had not supplied one for.
            OpenResult opened;
            try {
                opened = open_input(identities[static_cast<std::size_t>(i)], pw, o, canceller, report);
            } catch (QPDFExc const& e) {
                if (e.getErrorCode() != qpdf_e_password) {
                    throw;
                }
                return fail(
                    report,
                    nonempty(pw) ? ZPDFQPDF_ERR_PASSWORD_INCORRECT : ZPDFQPDF_ERR_PASSWORD_REQUIRED,
                    "input " + std::to_string(i) + ": " + e.what());
            }
            int32_t count = page_count_checked(*opened.pdf, o);
            total_pages += count;
            if (total_pages > o.max_pages) {
                throw LimitExceeded{
                    "merged document would have " + std::to_string(total_pages) +
                    " pages, over the configured limit of " + std::to_string(o.max_pages)};
            }
            std::vector<int32_t> indices;
            indices.reserve(static_cast<std::size_t>(count));
            for (int32_t p = 0; p < count; ++p) {
                indices.push_back(p);
            }
            assemble(*opened.pdf, *dest, indices, canceller);
            drain_warnings(*opened.pdf, report, nullptr);
            sources.push_back(opened.pdf);
        }

        std::vector<QPDF*> versions;
        for (auto& source: sources) {
            versions.push_back(source.get());
        }
        write_atomically(*dest, out_identity, write_flags, canceller, keep_versions(versions));
        return ZPDFQPDF_OK;
    });
}

// ---- transform ---------------------------------------------------------------

namespace
{
    // Removes the constructs that make a PDF do something when opened, and the
    // metadata that says who made it. Page and annotation actions are handled
    // too: an /AA on a page runs on page open as surely as one in the catalog.
    void
    sanitize(QPDF& pdf, zpdf_qpdf_transform_result& result)
    {
        auto root = pdf.getRoot();
        for (auto key: {"/OpenAction", "/AA"}) {
            if (root.hasKey(key)) {
                root.removeKey(key);
                result.removed_actions += 1;
            }
        }
        auto names = root.getKey("/Names");
        if (names.isDictionary()) {
            if (names.hasKey("/JavaScript")) {
                names.removeKey("/JavaScript");
                result.removed_javascript = 1;
            }
            if (names.hasKey("/EmbeddedFiles")) {
                names.removeKey("/EmbeddedFiles");
                result.removed_embedded_files = 1;
            }
        }
        if (root.hasKey("/AF")) {
            root.removeKey("/AF");
            result.removed_embedded_files = 1;
        }
        if (root.hasKey("/Metadata")) {
            root.removeKey("/Metadata");
            result.removed_metadata = 1;
        }
        auto trailer = pdf.getTrailer();
        if (trailer.hasKey("/Info")) {
            trailer.removeKey("/Info");
            result.removed_metadata = 1;
        }
        for (auto& page: QPDFPageDocumentHelper(pdf).getAllPages()) {
            auto object = page.getObjectHandle();
            if (object.hasKey("/AA")) {
                object.removeKey("/AA");
                result.removed_actions += 1;
            }
            if (object.hasKey("/Metadata")) {
                object.removeKey("/Metadata");
                result.removed_metadata = 1;
            }
            auto annots = object.getKey("/Annots");
            if (!annots.isArray()) {
                continue;
            }
            for (auto& annot: annots.aitems()) {
                if (!annot.isDictionary()) {
                    continue;
                }
                if (annot.hasKey("/AA")) {
                    annot.removeKey("/AA");
                    result.removed_actions += 1;
                }
                auto action = annot.getKey("/A");
                if (action.isDictionary()) {
                    auto type = action.getKey("/S");
                    if (type.isName() &&
                        (type.getName() == "/JavaScript" || type.getName() == "/Launch")) {
                        annot.removeKey("/A");
                        result.removed_actions += 1;
                    }
                }
            }
        }
        auto form = root.getKey("/AcroForm");
        if (form.isDictionary() && form.hasKey("/XFA")) {
            form.removeKey("/XFA");
            result.removed_actions += 1;
        }
    }

    // ---- picture downsampling (NL-PDF-08) -------------------------------

    struct Affine
    {
        double a{1}, b{0}, c{0}, d{1}, e{0}, f{0};
    };

    // `m` applied first, then `ctm`: the matrix a `cm` operator (or a form's
    // /Matrix) makes current.
    Affine
    concat(Affine const& m, Affine const& ctm)
    {
        return Affine{
            m.a * ctm.a + m.b * ctm.c,
            m.a * ctm.b + m.b * ctm.d,
            m.c * ctm.a + m.d * ctm.c,
            m.c * ctm.b + m.d * ctm.d,
            m.e * ctm.a + m.f * ctm.c + ctm.e,
            m.e * ctm.b + m.f * ctm.d + ctm.f};
    }

    bool
    read_matrix(QPDFObjectHandle array, Affine& out)
    {
        if (!array.isArray() || array.getArrayNItems() != 6) {
            return false;
        }
        double v[6];
        for (int i = 0; i < 6; ++i) {
            auto item = array.getArrayItem(i);
            if (!item.isNumber()) {
                return false;
            }
            v[i] = item.getNumericValue();
            if (!std::isfinite(v[i])) {
                return false;
            }
        }
        out = Affine{v[0], v[1], v[2], v[3], v[4], v[5]};
        return true;
    }

    // Lowest placement resolution per image object, and the images that must not
    // be touched (placed from content that could not be parsed).
    struct Placements
    {
        std::map<QPDFObjGen, double> dpi;
        std::set<QPDFObjGen> unsafe;
    };

    class PlacementTracker: public QPDFObjectHandle::ParserCallbacks
    {
      public:
        PlacementTracker(
            QPDFObjectHandle resources,
            Affine base,
            double user_unit,
            Placements& placements,
            std::set<QPDFObjGen>& visiting,
            int depth) :
            resources_(resources),
            ctm_(base),
            user_unit_(user_unit),
            placements_(placements),
            visiting_(visiting),
            depth_(depth)
        {
        }

        void
        handleObject(QPDFObjectHandle object) override
        {
            if (!object.isOperator()) {
                if (operands_.size() < 16) {
                    operands_.push_back(object);
                } else {
                    operands_.clear();
                }
                return;
            }
            std::string const op = object.getOperatorValue();
            if (op == "q") {
                if (stack_.size() < 4096) {
                    stack_.push_back(ctm_);
                }
            } else if (op == "Q") {
                if (!stack_.empty()) {
                    ctm_ = stack_.back();
                    stack_.pop_back();
                }
            } else if (op == "cm" && operands_.size() == 6) {
                auto array = QPDFObjectHandle::newArray(operands_);
                Affine m;
                if (read_matrix(array, m)) {
                    ctm_ = concat(m, ctm_);
                }
            } else if (op == "Do" && operands_.size() == 1 && operands_[0].isName()) {
                paint(operands_[0].getName());
            }
            operands_.clear();
        }

        void
        handleEOF() override
        {
        }

      private:
        void
        paint(std::string const& name)
        {
            if (!resources_.isDictionary()) {
                return;
            }
            auto xobjects = resources_.getKey("/XObject");
            if (!xobjects.isDictionary()) {
                return;
            }
            auto xobject = xobjects.getKey(name);
            if (!xobject.isStream()) {
                return;
            }
            auto dict = xobject.getDict();
            auto subtype = dict.getKey("/Subtype");
            if (!subtype.isName()) {
                return;
            }
            if (subtype.getName() == "/Image") {
                auto w = dict.getKey("/Width");
                auto h = dict.getKey("/Height");
                if (!w.isInteger() || !h.isInteger()) {
                    return;
                }
                // The unit square, mapped: placed size in points, times the user unit.
                double const placed_w = std::hypot(ctm_.a, ctm_.b) * user_unit_;
                double const placed_h = std::hypot(ctm_.c, ctm_.d) * user_unit_;
                QPDFObjGen const og = xobject.getObjGen();
                if (!(placed_w > 1e-6) || !(placed_h > 1e-6) || !std::isfinite(placed_w) || !std::isfinite(placed_h)) {
                    // Painted degenerate or at an unmeasurable size: never touched.
                    placements_.unsafe.insert(og);
                    return;
                }
                double const dpi_w = static_cast<double>(w.getIntValue()) / (placed_w / 72.0);
                double const dpi_h = static_cast<double>(h.getIntValue()) / (placed_h / 72.0);
                double const dpi = std::min(dpi_w, dpi_h);
                auto found = placements_.dpi.find(og);
                if (found == placements_.dpi.end() || dpi < found->second) {
                    placements_.dpi[og] = dpi;
                }
            } else if (subtype.getName() == "/Form" && depth_ < 8) {
                QPDFObjGen const og = xobject.getObjGen();
                if (visiting_.count(og)) {
                    return;
                }
                Affine matrix;
                Affine base = ctm_;
                if (read_matrix(dict.getKey("/Matrix"), matrix)) {
                    base = concat(matrix, ctm_);
                }
                auto inner = dict.getKey("/Resources");
                visiting_.insert(og);
                PlacementTracker child(inner.isDictionary() ? inner : resources_, base, user_unit_, placements_, visiting_, depth_ + 1);
                try {
                    QPDFObjectHandle::parseContentStream(xobject, &child);
                } catch (...) {
                    mark_unsafe(inner.isDictionary() ? inner : resources_, placements_);
                }
                visiting_.erase(og);
            }
        }

      public:
        static void
        mark_unsafe(QPDFObjectHandle resources, Placements& placements)
        {
            if (!resources.isDictionary()) {
                return;
            }
            auto xobjects = resources.getKey("/XObject");
            if (!xobjects.isDictionary()) {
                return;
            }
            for (auto& item: xobjects.ditems()) {
                if (item.second.isStream()) {
                    placements.unsafe.insert(item.second.getObjGen());
                }
            }
        }

      private:
        QPDFObjectHandle resources_;
        Affine ctm_;
        double user_unit_;
        Placements& placements_;
        std::set<QPDFObjGen>& visiting_;
        int depth_;
        std::vector<QPDFObjectHandle> operands_;
        std::vector<Affine> stack_;
    };

    // 1 or 3 components for the colour spaces a replacement keeps unchanged; 0 otherwise.
    int32_t
    image_components(QPDFObjectHandle space)
    {
        if (space.isName()) {
            if (space.getName() == "/DeviceGray") {
                return 1;
            }
            if (space.getName() == "/DeviceRGB") {
                return 3;
            }
            return 0;
        }
        if (space.isArray() && space.getArrayNItems() == 2) {
            auto family = space.getArrayItem(0);
            auto profile = space.getArrayItem(1);
            if (family.isName() && family.getName() == "/ICCBased" && profile.isStream()) {
                auto n = profile.getDict().getKey("/N");
                if (n.isInteger() && (n.getIntValue() == 1 || n.getIntValue() == 3)) {
                    return static_cast<int32_t>(n.getIntValue());
                }
            }
        }
        return 0;
    }

    void
    downsample_images(
        QPDF& pdf,
        zpdf_qpdf_transform const& spec,
        Canceller const& canceller,
        zpdf_qpdf_transform_result& result)
    {
        Placements placements;
        for (auto& page: QPDFPageDocumentHelper(pdf).getAllPages()) {
            canceller.check();
            auto object = page.getObjectHandle();
            double user_unit = 1;
            auto unit = object.getKey("/UserUnit");
            if (unit.isNumber() && std::isfinite(unit.getNumericValue()) && unit.getNumericValue() > 0) {
                user_unit = unit.getNumericValue();
            }
            auto resources = page.getAttribute("/Resources", false);
            std::set<QPDFObjGen> visiting;
            PlacementTracker tracker(resources, Affine{}, user_unit, placements, visiting, 0);
            try {
                page.parseContents(&tracker);
            } catch (...) {
                PlacementTracker::mark_unsafe(resources, placements);
            }
        }

        double const target = spec.image_target_dpi;
        for (auto const& entry: placements.dpi) {
            canceller.check();
            if (placements.unsafe.count(entry.first) || !(entry.second > target * 1.25)) {
                continue;
            }
            auto image = pdf.getObject(entry.first);
            if (!image.isStream()) {
                continue;
            }
            auto dict = image.getDict();
            auto mask = dict.getKey("/ImageMask");
            if ((mask.isBool() && mask.getBoolValue()) || dict.hasKey("/Mask") || dict.hasKey("/Decode")) {
                continue;
            }
            auto bpc = dict.getKey("/BitsPerComponent");
            if (!bpc.isInteger() || bpc.getIntValue() != 8) {
                continue;
            }
            int32_t const components = image_components(dict.getKey("/ColorSpace"));
            if (components == 0) {
                continue;
            }
            long long const width = dict.getKey("/Width").getIntValue();
            long long const height = dict.getKey("/Height").getIntValue();
            // The product is computed with overflow reported: /Width and /Height are the file's,
            // and an unchecked 64-bit multiplication is undefined behaviour on overflow. Two
            // values whose product wraps to 1 used to pass both checks below and reach the Swift
            // resampler as 2147483647 x 2147483647 (U-052). With pixels <= 200 000 000 and
            // components <= 4, `pixels * components` and each edge's int32 cast are in range.
            long long pixels = 0;
            if (width < 2 || height < 2 || __builtin_mul_overflow(width, height, &pixels) || pixels > 200000000LL) {
                continue;
            }
            auto filter = dict.getKey("/Filter");
            if (filter.isArray() && filter.getArrayNItems() == 1) {
                filter = filter.getArrayItem(0);
            }
            bool const dct = filter.isName() && filter.getName() == "/DCTDecode";
            std::shared_ptr<Buffer> bytes;
            try {
                if (dct) {
                    bytes = image.getRawStreamData();
                } else {
                    // Throws unless qpdf can undo every filter in the chain; a chain with
                    // DCT in it cannot be undone by this build, so it is never offered.
                    bytes = image.getStreamData(qpdf_dl_generalized);
                }
            } catch (...) {
                continue;  // JBIG2, CCITT, JPX, damaged data: left exactly as it is
            }
            if (!bytes) {
                continue;
            }
            if (!dct && static_cast<long long>(bytes->getSize()) != pixels * components) {
                continue;
            }
            zpdf_qpdf_image offered{};
            offered.object_number = entry.first.getObj();
            offered.generation = entry.first.getGen();
            offered.width = static_cast<int32_t>(width);
            offered.height = static_cast<int32_t>(height);
            offered.components = components;
            offered.encoding = dct ? ZPDFQPDF_IMAGE_DCT : ZPDFQPDF_IMAGE_SAMPLES;
            offered.effective_dpi = entry.second;
            offered.data = bytes->getBuffer();
            offered.length = bytes->getSize();
            result.offered_images += 1;
            zpdf_qpdf_image_replacement out{};
            int32_t const replace = spec.image_callback(spec.image_context, &offered, &out);
            std::unique_ptr<uint8_t, decltype(&::free)> owned(out.data, &::free);
            if (replace != 1 || !out.data || out.length == 0) {
                continue;
            }
            if (out.width < 1 || out.height < 1 || out.width >= width || out.height >= height) {
                continue;
            }
            std::string data(reinterpret_cast<char const*>(out.data), out.length);
            if (out.encoding == ZPDFQPDF_IMAGE_DCT) {
                image.replaceStreamData(data, QPDFObjectHandle::newName("/DCTDecode"), QPDFObjectHandle::newNull());
            } else if (out.encoding == ZPDFQPDF_IMAGE_SAMPLES) {
                if (static_cast<long long>(out.length) != static_cast<long long>(out.width) * out.height * components) {
                    continue;
                }
                // Written raw here; the writer compresses it with Flate.
                image.replaceStreamData(data, QPDFObjectHandle::newNull(), QPDFObjectHandle::newNull());
            } else {
                continue;
            }
            dict.replaceKey("/Width", QPDFObjectHandle::newInteger(out.width));
            dict.replaceKey("/Height", QPDFObjectHandle::newInteger(out.height));
            result.downsampled_images += 1;
        }
    }

    int32_t
    count_annotations(QPDF& pdf)
    {
        int32_t total = 0;
        for (auto& page: QPDFPageDocumentHelper(pdf).getAllPages()) {
            auto annots = page.getObjectHandle().getKey("/Annots");
            if (annots.isArray()) {
                total += static_cast<int32_t>(annots.getArrayNItems());
            }
        }
        return total;
    }
} // namespace

extern "C" int32_t
zpdf_qpdf_transform_copy(
    const char* input_path,
    const char* password,
    const char* output_path,
    const zpdf_qpdf_transform* transform,
    uint32_t write_flags,
    const zpdf_qpdf_options* options,
    zpdf_qpdf_cancel_fn cancel,
    void* cancel_context,
    zpdf_qpdf_transform_result* result,
    zpdf_qpdf_report* report)
{
    init_report(report);
    zpdf_qpdf_transform_result tally{};
    if (result) {
        *result = tally;
    }
    if (!nonempty(input_path) || !nonempty(output_path) || transform == nullptr) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "input_path, output_path and transform are required");
    }
    uint32_t const known = ZPDFQPDF_OP_FLATTEN_ANNOTATIONS | ZPDFQPDF_OP_COMPRESS |
        ZPDFQPDF_OP_SANITIZE | ZPDFQPDF_OP_ENCRYPT | ZPDFQPDF_OP_DOWNSAMPLE_IMAGES;
    if (transform->operations == 0 || (transform->operations & ~known) != 0) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "no operation, or an unknown one, was requested");
    }
    bool const downsample = (transform->operations & ZPDFQPDF_OP_DOWNSAMPLE_IMAGES) != 0;
    if (downsample) {
        if (transform->image_callback == nullptr || !std::isfinite(transform->image_target_dpi) ||
            transform->image_target_dpi < 36 || transform->image_target_dpi > 2400) {
            return fail(report, ZPDFQPDF_ERR_ARGUMENT, "downsampling needs a callback and a target between 36 and 2400 dpi");
        }
    }
    uint32_t const allowed_flags = ZPDFQPDF_WRITE_LINEARIZE | ZPDFQPDF_WRITE_DETERMINISTIC_ID;
    if ((write_flags & ~allowed_flags) != 0) {
        return fail(report, ZPDFQPDF_ERR_ARGUMENT, "a transform accepts only the linearize and deterministic-ID write flags");
    }
    bool const encrypt = (transform->operations & ZPDFQPDF_OP_ENCRYPT) != 0;
    std::string user = transform->user_password ? transform->user_password : "";
    std::string owner = transform->owner_password ? transform->owner_password : "";
    if (encrypt) {
        if (owner.empty()) {
            return fail(report, ZPDFQPDF_ERR_ARGUMENT, "encryption needs an owner password");
        }
        if (owner == user) {
            return fail(report, ZPDFQPDF_ERR_ARGUMENT, "the owner password must differ from the open password");
        }
        if (write_flags & ZPDFQPDF_WRITE_DETERMINISTIC_ID) {
            return fail(report, ZPDFQPDF_ERR_ARGUMENT, "a deterministic /ID cannot be derived for an encrypted file");
        }
        if (transform->allow_print < ZPDFQPDF_PRINT_NONE || transform->allow_print > ZPDFQPDF_PRINT_FULL) {
            return fail(report, ZPDFQPDF_ERR_ARGUMENT, "allow_print is not one of the ZPDFQPDF_PRINT_* values");
        }
    }
    bool had_password = nonempty(password);

    return guarded(report, had_password, [&]() -> int32_t {
        std::string in_identity;
        std::string why;
        if (!canonical_identity(input_path, in_identity, why)) {
            return fail(report, ZPDFQPDF_ERR_CANNOT_READ, why);
        }
        std::string out_identity;
        int32_t gate = check_output({in_identity}, output_path, out_identity, report);
        if (gate != ZPDFQPDF_OK) {
            return gate;
        }

        Options o = resolve(options);
        g_collect_max_warnings = o.doc_max_warnings;
        apply_global_limits(o);
        Canceller canceller{cancel, cancel_context};

        OpenResult opened = open_input(in_identity, password, o, canceller, report);
        QPDF& pdf = *opened.pdf;
        (void)page_count_checked(pdf, o);
        canceller.check();

        if (transform->operations & ZPDFQPDF_OP_FLATTEN_ANNOTATIONS) {
            int32_t before = count_annotations(pdf);
            // Filled form fields keep their look: generate the appearances qpdf
            // can before burning them in.
            QPDFAcroFormDocumentHelper(pdf).generateAppearancesIfNeeded();
            QPDFPageDocumentHelper(pdf).flattenAnnotations();
            tally.flattened_annotation_count = before - count_annotations(pdf);
            canceller.check();
        }
        if (transform->operations & ZPDFQPDF_OP_SANITIZE) {
            sanitize(pdf, tally);
        }
        if (downsample) {
            downsample_images(pdf, *transform, canceller, tally);
        }
        bool const compress = (transform->operations & ZPDFQPDF_OP_COMPRESS) != 0;
        if (compress) {
            QPDFPageDocumentHelper(pdf).removeUnreferencedResources();
        }

        auto extra = [&](QPDFWriter& w) {
            if (downsample) {
                // Replacement samples are handed over raw: they must be compressed.
                w.setCompressStreams(true);
            }
            if (compress) {
                w.setObjectStreamMode(qpdf_o_generate);
                w.setCompressStreams(true);
                w.setRecompressFlate(true);
                w.setDecodeLevel(qpdf_dl_generalized);
            }
            if (encrypt) {
                auto print = transform->allow_print == ZPDFQPDF_PRINT_FULL
                    ? qpdf_r3p_full
                    : transform->allow_print == ZPDFQPDF_PRINT_LOW ? qpdf_r3p_low : qpdf_r3p_none;
                bool modify = transform->allow_modify != 0;
                bool annotate = transform->allow_annotate != 0;
                w.setR6EncryptionParameters(
                    user.c_str(),
                    owner.c_str(),
                    true,  // accessibility: screen readers are never locked out
                    transform->allow_extract != 0,
                    modify,
                    annotate,
                    annotate,
                    modify,
                    print,
                    true);
            }
        };
        write_atomically(pdf, out_identity, write_flags, canceller, extra);
        drain_warnings(pdf, report, nullptr);
        if (result) {
            *result = tally;
        }
        return ZPDFQPDF_OK;
    });
}
