import Testing
import ZPDFQPDF

/// The three facts about this build that the licence review depends on.
@Suite("Build facts")
struct BuildFactsTests {

    @Test("qpdf is the pinned upstream revision's version")
    func vendoredVersion() {
        // RESEARCH_REPOSITORIES.lock.json pins qpdf at
        // dfd251125cadb59fe04836f9197c3ef94f99cf55, whose include/qpdf/DLL.h
        // declares 12.4.1. If this fails, the vendored copy drifted.
        #expect(QPDF.vendoredVersion == "12.4.1")
    }

    @Test("the crypto provider is native, never GnuTLS or OpenSSL")
    func cryptoProviderIsNative() {
        // qpdf's CMake would silently prefer GnuTLS (LGPL-2.1-or-later) when it
        // is installed. This build compiles only QPDFCrypto_native.cc and does
        // not even vendor the other two providers' headers.
        #expect(QPDF.cryptoProvider == "native")
    }

    @Test("the build has no DCT (JPEG) filter")
    func noDCTSupport() {
        // No libjpeg is vendored. DCT streams are copied through unmodified;
        // DCTPassthroughTests proves that is enough.
        #expect(QPDF.hasDCTSupport == false)
    }
}
