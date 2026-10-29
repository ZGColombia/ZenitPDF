import ZPDFGeometryServiceCore

// GeometryService.xpc — vector extraction out of process. All behaviour lives in
// ZPDFGeometryServiceCore (Packages/ZPDFServiceClient) so the tests there run the
// code this bundle ships. `--stdio` serves wire frames for diagnosis and tests;
// otherwise this is an XPC service and serves its NSXPCListener.
GeometryServiceMain.run()
