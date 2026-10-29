# Privacy

Zenit PDF processes drawings and project data locally. The application makes no network
connections, collects no telemetry or analytics, and requires no account. It has no update
feature; downloading a release from GitHub is a separate action in your browser.

Projects can contain original and working drawings, measurements, markup history, author
labels, photos, OCR text, thumbnails, and exports. These are files on storage you control.
Author labels may come from your configured identity; review them before sharing a project
or exported report. Deleting a markup does not automatically delete its photo attachments.

Shared Review reads and writes review files in a folder you choose. If that folder is on a
network volume or synchronized by another application, that service controls transport and
retention. Zenit PDF does not operate a collaboration server or upload service.

Exports and Send Project create files for you to share. Review their contents and destination.
Removing an application does not remove copies of projects, exports, backups, or shared-folder
files you have stored elsewhere. Manage those copies with the storage tools you use.

Build-time dependency downloads are separate from application behavior: SwiftPM needs network
access to fetch GRDB for a first build. See [Building](../../BUILDING.md).

For questions or private security reports, contact
[info@zenitgroup.com.co](mailto:info@zenitgroup.com.co).
