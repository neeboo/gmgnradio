# Upstream provenance

- Project: [magicien/MMDSceneKit](https://github.com/magicien/MMDSceneKit)
- Commit: `53f0c043e90f6537e2519f3e7d6061028687b8bd`
- License: MIT; see `LICENSE`.

The Swift, Metal, shader, plist, and toon texture sources in this package are
vendored from the upstream `Source/Common` directory. Local changes adapt
resource lookup to SwiftPM, expose header-only file type detection, and keep
binary scalar reads inside `withUnsafeMutableBytes` pointer lifetimes.
