# Third-party notices

Zenit PDF is MIT licensed, Copyright (c) 2026 ZENIT GROUP S.A.S. The components below retain their own licenses.

| Component | License | Source record |
|---|---|---|
| qpdf | Apache-2.0, with its NOTICE and an embedded RSA MD5 notice below; a vendored subset, one file modified | [Vendoring](Bridges/QPDFBridge/VENDORED.md) |
| libxlsxwriter | BSD-2-Clause, with embedded notices below (minizip: zlib licence, altered source versions) | [Vendoring](Bridges/LibXlsxWriterBridge/VENDORED.md) |
| Clipper2 | BSL-1.0; Copyright Angus Johnson 2010-2026, as stated in the upstream source headers (the upstream LICENSE names no holder) | [Vendoring](Bridges/Clipper2Bridge/VENDORED.md) |
| GRDB.swift | MIT, with embedded Ruby on Rails Active Support (MIT) and Swift.org (Apache-2.0 with Runtime Library Exception) notices below | [Package manifest](Packages/ZPDFPersistence/Package.swift) |

The complete texts below are byte-for-byte copies of the bundle license resources in `Apps/ZenitPDF/Bundle/Licenses/`, which ship in the app and are shown under Help > Licences. Inside each text, the header, the section headings, the short lead-in before each embedded licence comment, and the sections headed "notes by Zenit PDF (not upstream text)" are Zenit PDF's own text; everything else is upstream text reproduced verbatim. See the [shipped notice inventory](Docs/Licences/SHIPPED_NOTICES.tsv). Personal names in these texts are required upstream attributions.

### Repository-only material (not shipped in the app)

| Material | License | Where |
|---|---|---|
| Contributor Covenant, version 2.1 | CC BY 4.0 | Adapted, with modifications, in [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md); attribution in that file |

### Altered source versions

The minizip files `ioapi.h`, `zip.h` and `zip.c` in `Bridges/LibXlsxWriterBridge/Sources/CXlsxWriter/minizip/`, and the `ioapi.h` and `zip.h` copies under `Bridges/LibXlsxWriterBridge/Sources/CXlsxWriter/include/xlsxwriter/third_party/`, are altered source versions, not the original MiniZip software (zlib licence, condition 2). They are MiniZip as distributed in zlib 1.3.1 `contrib/minizip`, altered by libxlsxwriter; Zenit PDF's only change to them is the altered-source marking comment at the top of each file. The other vendored minizip file, `ioapi.c`, is unaltered, and minizip's `crypt.h` (Info-ZIP-derived encryption code, never compiled because `zip.h` defines `NOCRYPT`) is not vendored. The alterations are recorded in the [libxlsxwriter vendoring record](Bridges/LibXlsxWriterBridge/VENDORED.md). The one qpdf file Zenit PDF modified, `libqpdf/QPDF_Stream.cc`, is described in the [qpdf vendoring record](Bridges/QPDFBridge/VENDORED.md) and in the qpdf notice below.

### Acknowledgements without licence obligation

- **hilbert_curves** ([github.com/rawrunprotected/hilbert_curves](https://github.com/rawrunprotected/hilbert_curves)). Its README states "The code in this repository is released into the public domain." Its `hilbertXYToIndex` is ported, fixed at 16 bits per axis, into `Packages/ZPDFGeometry/Sources/ZPDFGeometry/Index/HilbertCurve.swift`.
- **flatbush** ([github.com/mourner/flatbush](https://github.com/mourner/flatbush), ISC) is the design reference for `Packages/ZPDFGeometry/Sources/ZPDFGeometry/Index/PackedRTree.swift`: a Hilbert-packed, flat-array R-tree with a default node size of 16. PackedRTree.swift is an independent Swift implementation and contains no code copied from flatbush.


## qpdf

````text
================================================================================
qpdf
================================================================================
Pinned revision: dfd25112
This notice ships inside Zenit PDF.app/Contents/Resources/Licenses and is shown
in the About window's Acknowledgements section (Help ▸ Licences). This header,
the section headings, the short lead-in before each embedded licence comment
and the sections headed "notes by Zenit PDF" are Zenit PDF's own text.
Everything else is reproduced verbatim from the upstream files listed below;
each SHA-256 is reproducible with `shasum -a 256 <file>` against the clone at
the revision above, or at the revision named on the line.
  LICENSE.txt  sha256 cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
  NOTICE.md  sha256 b207f65a9e5491195ded63b2941199b19a4d30148871f2742c88eae7bfc513a6
  libqpdf/MD5_native.cc  sha256 0534460b7414e3a250f5bddb3c9906dbbfce4bc98de27ea2daf265eb318b483f  (licence comment only)

--------------------------------------------------------------------------------
qpdf — notes by Zenit PDF (not upstream text)
--------------------------------------------------------------------------------

Zenit PDF vendors a subset of qpdf: 210 files from the revision above, which
declares version 12.4.1 in include/qpdf/DLL.h and is a development snapshot 26
commits after the v12.4.0 tag, plus one header written for Zenit PDF
(libqpdf/qpdf/qpdf-config.h, below). The file list and digests are recorded in
Bridges/QPDFBridge/VENDORED.md in the Zenit PDF source repository.

Changes made by Zenit PDF:
- libqpdf/QPDF_Stream.cc is modified: the DCTDecode (JPEG) filter include and
  its /DCTDecode and /DCT registrations are compiled out with
  ZPDF_QPDF_NO_DCT, because this build links no libjpeg (see VENDORED.md
  section 3). Pl_DCT.cc is not included, so this build does not decode DCT
  (JPEG) streams.
- libqpdf/qpdf/qpdf-config.h is written for Zenit PDF in place of the header
  that qpdf's CMake build generates.
All other vendored files are unmodified. The build uses qpdf's native crypto
provider and links no libjpeg, GnuTLS or OpenSSL; the command-line job layer
is not included.

The compiled sphlib SHA-2 files (libqpdf/sha2.c, libqpdf/sha2big.c,
sphinclude/sph/sph_sha2.h, sph_types.h and md_helper.c) state
"Copyright (c) 2007-2010  Projet RNRT SAPHIR" in their own headers; qpdf's
NOTICE.md below reproduces the same MIT licence with the years 2007-2011.

--------------------------------------------------------------------------------
qpdf — LICENSE.txt
--------------------------------------------------------------------------------


                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

--------------------------------------------------------------------------------
qpdf — NOTICE.md
--------------------------------------------------------------------------------

qpdf is copyright (c) 2005-2021 Jay Berkenbilt, 2022-2026 Jay Berkenbilt and Manfred Holger

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

Versions of qpdf prior to version 7 were released under the terms of version 2.0 of the Artistic License. At your option, you may continue to consider qpdf to be licensed under those terms. Please see the manual for additional information.

The qpdf distribution includes a copy of [qtest](https://qtest.sourceforge.io), which is released under the terms of the [version 2.0 of the Artistic license](https://opensource.org/licenses/Artistic-2.0), which can be found at https://opensource.org/licenses/Artistic-2.0.

The Rijndael encryption implementation used as the basis for AES encryption and decryption support comes from Philip J. Erdelsky's public domain implementation.  The files `libqpdf/rijndael.cc` and `libqpdf/qpdf/rijndael.h` remain in the public domain.  They were obtained from
* http://www.efgh.com/software/rijndael.htm
* http://www.efgh.com/software/rijndael.txt

The embedded sha2 code comes from sphlib 3.0
* http://www.saphir2.com/sphlib/

That code has the following license:
  ```
  Copyright (c) 2007-2011  Projet RNRT SAPHIR

  Permission is hereby granted, free of charge, to any person obtaining
  a copy of this software and associated documentation files (the
  "Software"), to deal in the Software without restriction, including
  without limitation the rights to use, copy, modify, merge, publish,
  distribute, sublicense, and/or sell copies of the Software, and to
  permit persons to whom the Software is furnished to do so, subject to
  the following conditions:

  The above copyright notice and this permission notice shall be included
  in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
  CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
  TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
  SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
  ```

--------------------------------------------------------------------------------
qpdf — embedded: RSA Data Security MD5 (libqpdf/MD5_native.cc)
--------------------------------------------------------------------------------

Compiled into Zenit PDF: libqpdf/MD5_native.cc,
derived from the RSA Data Security, Inc. MD5 Message-Digest Algorithm.
Its licence comment, reproduced verbatim from that file:

// This file implements a class for computation of MD5 checksums.
// It is derived from the reference algorithm for MD5 as given in
// RFC 1321.  The original copyright notice is as follows:
//
/////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 1991-2, RSA Data Security, Inc. Created 1991. All
// rights reserved.
//
// License to copy and use this software is granted provided that it
// is identified as the "RSA Data Security, Inc. MD5 Message-Digest
// Algorithm" in all material mentioning or referencing this software
// or this function.
//
// License is also granted to make and use derivative works provided
// that such works are identified as "derived from the RSA Data
// Security, Inc. MD5 Message-Digest Algorithm" in all material
// mentioning or referencing the derived work.
//
// RSA Data Security, Inc. makes no representations concerning either
// the merchantability of this software or the suitability of this
// software for any particular purpose. It is provided "as is"
// without express or implied warranty of any kind.
//
// These notices must be retained in any copies of any part of this
// documentation and/or software.
//
/////////////////////////////////////////////////////////////////////////
````


## libxlsxwriter

The opening "notes by Zenit PDF" section of the text below says the same for app users. Not every component named on libxlsxwriter's license page below is in Zenit PDF. The bridge builds with `USE_STANDARD_TMPFILE` and `USE_NO_MD5` and without `USE_DTOA_LIBRARY`, so tmpfileplus (MPL-2.0), the Openwall md5 and emyg_dtoa are neither vendored nor compiled. libxlsxwriter itself, minizip (zlib license) and the FreeBSD `queue.h` and `tree.h` macro headers are compiled in. The page is reproduced whole because it is upstream's license file. The flag decisions are recorded in the [vendoring record](Bridges/LibXlsxWriterBridge/VENDORED.md) and in conflict 3 of the [license evidence](Docs/Licences/LICENSE_EVIDENCE.md).

```text
================================================================================
libxlsxwriter
================================================================================
Pinned revision: 3227eb0c
This notice ships inside Zenit PDF.app/Contents/Resources/Licenses and is shown
in the About window's Acknowledgements section (Help ▸ Licences). This header,
the section headings, the short lead-in before each embedded licence comment
and the sections headed "notes by Zenit PDF" are Zenit PDF's own text.
Everything else is reproduced verbatim from the upstream files listed below;
each SHA-256 is reproducible with `shasum -a 256 <file>` against the clone at
the revision above, or at the revision named on the line.
  License.txt  sha256 be1d70d4ec6e0388522bdd584e747971c9e1b16960539c7140929d63dd2130bc

--------------------------------------------------------------------------------
libxlsxwriter — notes by Zenit PDF (not upstream text)
--------------------------------------------------------------------------------

What this build contains: Zenit PDF compiles libxlsxwriter with
USE_STANDARD_TMPFILE and USE_NO_MD5 and without USE_DTOA_LIBRARY, so
tmpfileplus (MPL-2.0), the md5 code and emyg_dtoa, which the upstream licence
page below names, are not vendored, compiled or linked into this
application. Compiled in are:
- libxlsxwriter itself; one file, src/utility.c, is modified by Zenit PDF so
  that it builds without the tmpfileplus header;
- the writer half of minizip (zlib licence; Copyright (C) 1998-2010 Gilles
  Vollant, Zip64 support Copyright (C) 2009-2010 Mathias Svensson). Its
  ioapi.h, zip.h and zip.c are altered source versions, not the original
  MiniZip software, and are marked as such at the top of each file; ioapi.c
  is unaltered. The alterations are recorded in
  Bridges/LibXlsxWriterBridge/VENDORED.md in the Zenit PDF source repository;
- the FreeBSD queue.h (Copyright (c) 1991, 1993 The Regents of the University
  of California) and tree.h (Copyright 2002 Niels Provos) macro headers.
zlib itself is the macOS system library. The upstream licence page is
reproduced whole because it is upstream's licence file.

--------------------------------------------------------------------------------
libxlsxwriter — License.txt
--------------------------------------------------------------------------------

/**

@page license License

Libxlsxwriter is released under a FreeBSD license:

    Copyright 2014-2026, John McNamara <jmcnamara@cpan.org>
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are
    met:

    1. Redistributions of source code must retain the above copyright notice,
       this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
    IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
    THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
    PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
    CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
    EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
    PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
    PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
    LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
    NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
    SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

    The views and conclusions contained in the software and documentation are
    those of the authors and should not be interpreted as representing
    official policies, either expressed or implied, of the FreeBSD Project.


Libxlsxwriter includes the `queue.h` and `tree.h` macros from FreeBSD. It also
includes and, unless overridden, uses the optional libraries `minizip`,
`tmpfileplus` and `md5`. It also includes the `emyg_dtoa` library but doesn't
use it by default. These components have the following licenses:


Queue.h from FreeBSD:

    Copyright (c) 1991, 1993
     The Regents of the University of California.  All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:
    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
    4. Neither the name of the University nor the names of its contributors
       may be used to endorse or promote products derived from this software
       without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
    ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
    ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
    FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
    OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
    HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
    OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
    SUCH DAMAGE.


Tree.h from FreeBSD:

    Copyright 2002 Niels Provos <provos@citi.umich.edu>
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:
    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.

    THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
    IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
    OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
    IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
    NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
    DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
    THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
    THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


The `minizip` files used in the libxlsxwriter source tree are taken from the
`zlib` ` contrib/minizip` directory. [Zlib](http://www.zlib.net) has the
following License/Copyright:

    (C) 1995-2013 Jean-loup Gailly and Mark Adler

    This software is provided 'as-is', without any express or implied
    warranty.  In no event will the authors be held liable for any damages
    arising from the use of this software.

    Permission is granted to anyone to use this software for any purpose,
    including commercial applications, and to alter it and redistribute it
    freely, subject to the following restrictions:

    1. The origin of this software must not be misrepresented; you must not
       claim that you wrote the original software. If you use this software
       in a product, an acknowledgment in the product documentation would be
       appreciated but is not required.
    2. Altered source versions must be plainly marked as such, and must not be
       misrepresented as being the original software.
    3. This notice may not be removed or altered from any source distribution.

    Jean-loup Gailly        Mark Adler
    jloup@gzip.org          madler@alumni.caltech.edu

The `minizip` files have the following additional copyright declarations:

    Copyright (C) 1998-2010 Gilles Vollant
    (minizip) ( http://www.winimage.com/zLibDll/minizip.html )

    Modifications for Zip64 support
    Copyright (C) 2009-2010 Mathias Svensson ( http://result42.com )

Note, it is possible to compile libxlsxwriter without statically linking the
`minizip` files and instead dynamically linking to `lminizip`, see
@ref gsg_minizip.

[Tmpfileplus](http://www.di-mgt.com.au/c_function_to_create_temp_file.html)
has the following license:

    This Source Code Form is subject to the terms of the Mozilla Public
    License, v. 2.0. If a copy of the MPL was not distributed with this
    file, You can obtain one at http://mozilla.org/MPL/2.0/.

    Copyright (c) 2012-16 David Ireland, DI Management Services Pty Ltd
    <http://www.di-mgt.com.au/contact/>.

See the [Mozilla Public License, v. 2.0](http://mozilla.org/MPL/2.0/).

Note, it is possible to compile libxlsxwriter using the standard library
`tmpfile()` function instead of `tmpfileplus`, see @ref gsg_tmpdir.

The [Milo Yip DTOA library](https://github.com/miloyip/dtoa-benchmark) for
converting doubles to strings. It has the following license:

    Copyright (C) 2015 Doug Currie
    based on dtoa_milo.h
    Copyright (C) 2014 Milo Yip

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in
    all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
    THE SOFTWARE.

This Milo Yip DTOA library (emyg_dtoa) is used to avoid issues where the
standard sprintf() dtoa function changes output based on locale settings. It
is also 40-50% faster than the standard dtoa for raw numeric data. The use of
this library is optional. If you wish to use it you can pass
`USE_DTOA_LIBRARY=1` to make when compiling.

[Openwall MD5](https://openwall.info/wiki/people/solar/software/public-domain-source-code/md5)
has the following licence:

    This software was written by Alexander Peslyak in 2001.  No copyright is
    claimed, and the software is hereby placed in the public domain.
    In case this attempt to disclaim copyright and place the software in the
    public domain is deemed null and void, then the software is
    Copyright (c) 2001 Alexander Peslyak and it is hereby released to the
    general public under the following terms:

    Redistribution and use in source and binary forms, with or without
    modification, are permitted.

    There's ABSOLUTELY NO WARRANTY, express or implied.

    (This is a heavily cut-down "BSD license".)

Note, the MD5 library is used to avoid including duplicate image files in the
xlsx file. If you don't want to use this code, and the additional licence, you
can use OpenSSL's MD5 functions instead by passing `USE_OPENSSL_MD5=1` to
make. If this functionality isn't required it is possible to compile
libxlsxwriter without image deduplication by passing `USE_NO_MD5=1` to make.

See also @ref gsg_md5.

Next: @ref changes
*/
```


## Clipper2

```text
================================================================================
Clipper2
================================================================================
Pinned revision: f9c5eb6e
This notice ships inside Zenit PDF.app/Contents/Resources/Licenses and is shown
in the About window's Acknowledgements section (Help ▸ Licences). This header,
the section headings, the short lead-in before each embedded licence comment
and the sections headed "notes by Zenit PDF" are Zenit PDF's own text.
Everything else is reproduced verbatim from the upstream files listed below;
each SHA-256 is reproducible with `shasum -a 256 <file>` against the clone at
the revision above, or at the revision named on the line.
  LICENSE  sha256 c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566

--------------------------------------------------------------------------------
Clipper2 — notes by Zenit PDF (not upstream text)
--------------------------------------------------------------------------------

The upstream LICENSE below names no copyright holder. The vendored Clipper2
source headers state "Copyright :  Angus Johnson" with year ranges from
2010-2023 to 2010-2026 (2010-2026 in clipper.engine.cpp and
clipper.triangulation.cpp). Zenit PDF vendors twelve files of Clipper2's C++
library unmodified from the revision above, which declares version 2.0.1 in
clipper.version.h and is a development snapshot 16 commits after the
Clipper2_2.0.1 tag.

--------------------------------------------------------------------------------
Clipper2 — LICENSE
--------------------------------------------------------------------------------

Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```


## GRDB.swift

```text
================================================================================
GRDB.swift
================================================================================
Pinned revision: 0d8cf958
This notice ships inside Zenit PDF.app/Contents/Resources/Licenses and is shown
in the About window's Acknowledgements section (Help ▸ Licences). This header,
the section headings, the short lead-in before each embedded licence comment
and the sections headed "notes by Zenit PDF" are Zenit PDF's own text.
Everything else is reproduced verbatim from the upstream files listed below;
each SHA-256 is reproducible with `shasum -a 256 <file>` against the clone at
the revision above, or at the revision named on the line.
  LICENSE  sha256 9853f9dce81365fcc1d9b46004633354450164b8d17904e92e80c444545f7e87
  GRDB/Utils/Inflections+English.swift  sha256 80b42f1c5e10d486d684a94fdd5adc923fb9aacbb004a686c666ee98b699ac37  (licence comment only)
  GRDB/Core/Cursor.swift  sha256 87679f629ff3b24cd747b12bf5a966f8e1dff4536253efaad785dd0975a6aad0  (licence comment only)
  GRDB/Record/EncodableRecord.swift  sha256 b2329647c24b327338c7deb72625430e7bfa0a76ee088208b439e41e58a5ced8  (licence comment only)
  GRDB/Record/FetchableRecord.swift  sha256 faa0d2bb012f406c8ab287ebbd8ab51c615e464414bdb124d31135de89a21cf9  (licence comment only)
  LICENSE.txt  sha256 cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30  (from the qpdf clone at dfd25112)

--------------------------------------------------------------------------------
GRDB.swift — notes by Zenit PDF (not upstream text)
--------------------------------------------------------------------------------

GRDB.swift is resolved by Swift Package Manager at the revision above, a
development snapshot 2 commits after the v7.11.1 tag, and compiled into Zenit
PDF unmodified. Besides GRDB's own licence, four compiled GRDB files carry
licence notices of their own, reproduced below: the Ruby on Rails Active
Support MIT notice in GRDB/Utils/Inflections+English.swift, and Swift.org
notices (Apache License v2.0 with Runtime Library Exception, Apple Inc. and
the Swift project authors) in GRDB/Core/Cursor.swift,
GRDB/Record/EncodableRecord.swift and GRDB/Record/FetchableRecord.swift.
The full Apache License 2.0 text is reproduced at the end of this notice. The
Swift project's licence adds the Runtime Library Exception, published with
that licence at https://swift.org/LICENSE.txt.

--------------------------------------------------------------------------------
GRDB.swift — LICENSE
--------------------------------------------------------------------------------

Copyright (C) 2015-2025 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

--------------------------------------------------------------------------------
GRDB.swift — embedded: Ruby on Rails Active Support inflections (MIT) (GRDB/Utils/Inflections+English.swift)
--------------------------------------------------------------------------------

Compiled into Zenit PDF: GRDB/Utils/Inflections+English.swift,
whose English inflection rules are ported from Ruby on Rails Active Support.
Its licence comment, reproduced verbatim from that file:

// Copyright (C) 2015-2023 Gwendal Roué
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// =============================================================================
//
// Copyright (c) 2005-2019 David Heinemeier Hansson
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

--------------------------------------------------------------------------------
GRDB.swift — embedded: Swift.org (Apache-2.0 with Runtime Library Exception) (GRDB/Core/Cursor.swift)
--------------------------------------------------------------------------------

Compiled into Zenit PDF: GRDB/Core/Cursor.swift,
parts of which are derived from the Swift.org open source project.
Its licence comment, reproduced verbatim from that file:

//===----------------------------------------------------------------------===//
//
// Parts of this file are derived from the Swift.org open source project:
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

--------------------------------------------------------------------------------
GRDB.swift — embedded: swift-corelibs-foundation (Apache-2.0 with Runtime Library Exception) (GRDB/Record/EncodableRecord.swift)
--------------------------------------------------------------------------------

Compiled into Zenit PDF: GRDB/Record/EncodableRecord.swift,
whose _convertToSnakeCase function is copied from swift-corelibs-foundation.
Its licence comment, reproduced verbatim from that file:

        //===----------------------------------------------------------------------===//
        //
        // This function is part of the Swift.org open source project
        //
        // Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
        // Licensed under Apache License v2.0 with Runtime Library Exception
        //
        // See https://swift.org/LICENSE.txt for license information
        // See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
        //
        //===----------------------------------------------------------------------===//

--------------------------------------------------------------------------------
GRDB.swift — embedded: swift-corelibs-foundation (Apache-2.0 with Runtime Library Exception) (GRDB/Record/FetchableRecord.swift)
--------------------------------------------------------------------------------

Compiled into Zenit PDF: GRDB/Record/FetchableRecord.swift,
whose _convertFromSnakeCase function is copied from swift-corelibs-foundation.
Its licence comment, reproduced verbatim from that file:

        //===----------------------------------------------------------------------===//
        //
        // This function is part of the Swift.org open source project
        //
        // Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
        // Licensed under Apache License v2.0 with Runtime Library Exception
        //
        // See https://swift.org/LICENSE.txt for license information
        // See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
        //
        //===----------------------------------------------------------------------===//

--------------------------------------------------------------------------------
GRDB.swift — Apache License 2.0, for the Swift.org-derived code above
--------------------------------------------------------------------------------


                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright [yyyy] [name of copyright owner]

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```
