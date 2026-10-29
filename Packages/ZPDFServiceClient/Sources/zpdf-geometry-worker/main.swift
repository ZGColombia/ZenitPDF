import ZPDFGeometryServiceCore

// Test worker: the geometry service core over stdio frames. `swift test` spawns
// this to prove crash isolation without an app bundle around it.
GeometryServiceMain.run()
