"""Lightweight contracts; executes the real SceneKit factory without an app host."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
RENDER = ROOT / "apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift"
PROPS = ROOT / "apps/macos/Sources/GMGNRadio/MMD/PMXStageAvatarRenderer.swift"


class CabinPropRenderTests(unittest.TestCase):
    def test_independent_jukebox_uses_local_metres_without_room_geometry(self):
        source = PROPS.read_text()
        self.assertTrue("static func makeIndependentJukebox()" in source,
                        "The Marble object needs its own factory, independent of the room")
        factory = source.split("enum LivingPodScene {", 1)[1].split(
            "private final class PMXDecodedModelBox", 1)[0]
        program = "import AppKit\nimport SceneKit\nimport simd\nenum LivingPodScene {" + factory
        program += """
let prop = LivingPodScene.makeIndependentJukebox()
assert(prop.name == "jukebox")
assert(prop.simdPosition == .zero)
assert(prop.childNode(withName: "hull-floor", recursively: true) == nil)
assert(prop.childNode(withName: "sleep-pod", recursively: true) == nil)
let bounds = prop.boundingBox
assert(abs(bounds.min.y) < 0.001)
assert(abs(bounds.max.y - 1.23) < 0.01)
let plinth = prop.childNode(withName: "plinth", recursively: false)!
assert(abs(plinth.simdPosition.x) < 0.001)
assert(abs(plinth.simdPosition.z) < 0.001)
let legacy = LivingPodScene.makeRoomNode().childNode(withName: "jukebox", recursively: true)!
assert(abs(legacy.boundingBox.min.y - 0.12) < 0.001)
print("Independent jukebox geometry PASS")
"""
        result = subprocess.run(["swift", "-"], input=program, text=True,
                                capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_overlay_preserves_splat_color_and_is_selected_world_scoped(self):
        source = RENDER.read_text()
        self.assertTrue("preservesBackground ? .load : .clear" in source)
        self.assertTrue("cabin.worldID == spatialStage.selectedWorldID" in source)
        self.assertTrue("LivingPodScene.makeIndependentJukebox()" in source)
        self.assertTrue("preservesBackground: true" in source)

    def test_explicit_calibration_bypasses_auto_fit_and_auto_placement(self):
        source = RENDER.read_text()
        self.assertTrue("let framing = cabinPresentation?.sceneFraming" in source)
        self.assertTrue("let cameraHome = cabinPresentation?.camera" in source)
        self.assertTrue("cabinPresentation?.avatarPlacement" in source)
        self.assertTrue("groundedOrigin: SIMD3<Float>," in source)

    def test_calibrated_room_stays_eight_metres_wide(self):
        source = RENDER.read_text()
        self.assertTrue("groundedOrigin: SIMD3<Float>," in source)
        constructor = source.split("struct MarbleSceneFraming:", 1)[1].split(
            "    init(positions:", 1)[0]
        program = "import simd\nstruct MarbleSceneFraming:" + constructor + "}\n"
        program += """
let framing = MarbleSceneFraming(
    groundedOrigin: SIMD3<Float>(1, -2, 3), uniformScale: 1,
    minimum: SIMD3<Float>(-3, -2, -1), maximum: SIMD3<Float>(5, 1, 7)
)
assert(framing.uniformScale == 1)
assert(framing.normalizedMinimum == SIMD3<Float>(-4, 0, -4))
assert(framing.normalizedMaximum == SIMD3<Float>(4, 3, 4))
assert(framing.normalizedMaximum.x - framing.normalizedMinimum.x == 8)
print("Explicit metre calibration PASS")
"""
        result = subprocess.run(["swift", "-"], input=program, text=True,
                                capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_prop_uses_scene_depth_but_never_its_own_proxy(self):
        source = RENDER.read_text()
        self.assertTrue("depthOverride: .sceneKitReverse" in source)
        self.assertTrue("includeCabinProp: false" in source)
        self.assertTrue("preservesDepth ? .load : .clear" in source)
        self.assertTrue("if includeCabinProp," in source)

    def test_prop_proxy_has_twelve_transformed_faces(self):
        source = RENDER.read_text()
        self.assertTrue("static func boxPositions(" in source)
        mesh = source.split("enum MarbleOccluderMesh {", 1)[1].split(
            "@MainActor\nfinal class MarbleSpatialView", 1)[0]
        program = """import simd
struct WorldTriangle { let first, second, third: SIMD3<Float> }
enum MarbleOccluderMesh {
""" + mesh
        program += """
var transform = matrix_identity_float4x4
transform.columns.3 = SIMD4<Float>(2, 0, -3, 1)
let vertices = MarbleOccluderMesh.boxPositions(
    minimum: SIMD3<Float>(-0.25, 0, -0.21),
    maximum: SIMD3<Float>(0.25, 1.23, 0.21), transform: transform
)
assert(vertices.count == 36)
assert(vertices.map(\\.x).min() == 1.75)
assert(vertices.map(\\.x).max() == 2.25)
assert(vertices.map(\\.y).min() == 0)
assert(vertices.map(\\.y).max() == 1.23)
print("Prop depth proxy PASS")
"""
        result = subprocess.run(["swift", "-"], input=program, text=True,
                                capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_scene_kit_bounds_convert_at_the_real_render_call_site(self):
        source = RENDER.read_text()
        mesh = source.split("enum MarbleOccluderMesh {", 1)[1].split(
            "@MainActor\nfinal class MarbleSpatialView", 1)[0]
        call_site = source.split("            let bounds = node.boundingBox", 1)[1].split(
            "        } else {", 1)[0]
        program = """import SceneKit
import simd
struct WorldTriangle { let first, second, third: SIMD3<Float> }
enum MarbleOccluderMesh {
""" + mesh + """
let node = SCNNode(geometry: SCNBox(width: 0.5, height: 1.2, length: 0.42, chamferRadius: 0))
node.simdPosition = SIMD3<Float>(2, 0.6, -3)
let propVertices: [SIMD3<Float>]
let bounds = node.boundingBox
""" + call_site + """
assert(propVertices.count == 36)
assert(abs(propVertices.map(\\.x).min()! - 1.75) < 0.001)
assert(abs(propVertices.map(\\.y).min()!) < 0.001)
print("SceneKit bounds render call-site PASS")
"""
        result = subprocess.run(["swift", "-"], input=program, text=True,
                                capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cabin_decode_failure_reaches_visible_library_error(self):
        source = RENDER.read_text()
        loading = source.split("    private func load(\n", 1)[1].split(
            "    private func loadAvatar(", 1)[0]
        self.assertTrue("library.reportLivingCabinFailure(error)" in loading)

    def test_debug_frame_capture_is_single_use_and_writes_real_png(self):
        source = RENDER.read_text()
        self.assertTrue("final class MarbleDebugFrameCapture" in source)
        capture = source.split("// BEGIN DEBUG FRAME CAPTURE\n", 1)[1].split(
            "// END DEBUG FRAME CAPTURE", 1)[0]
        program = """import AppKit
import MetalKit
import ImageIO
import os
""" + capture + """
MainActor.assumeIsolated {
    assert(MarbleDebugFrameCapture.outputURL(environment: [:]) == nil)
    assert(MarbleDebugFrameCapture.outputURL(environment: ["GMGN_SPACE_FRAME_OUTPUT": "relative.png"]) == nil)
    assert(MarbleDebugFrameCapture.outputURL(environment: ["GMGN_SPACE_FRAME_OUTPUT": "/tmp/test.jpg"]) == nil)
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let capture = MarbleDebugFrameCapture(outputURL: output)
    assert(!capture.claimIfReady(true))
    assert(!capture.claimIfReady(false))
    assert(!capture.claimIfReady(true))
    assert(!capture.claimIfReady(true))
    assert(capture.claimIfReady(true))
    assert(!capture.claimIfReady(true))
    var pixels = Data(repeating: 0, count: 256)
    pixels[2] = 255
    pixels[3] = 255
    pixels[4] = 255
    pixels[7] = 255
    try! MarbleDebugFrameCapture.writePNG(pixels, width: 2, height: 1, bytesPerRow: 256, outputURL: output)
    let imageSource = CGImageSourceCreateWithURL(output as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
    assert(image.width == 2 && image.height == 1)
    let bitmap = NSBitmapImageRep(cgImage: image)
    let red = bitmap.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
    let blue = bitmap.colorAt(x: 1, y: 0)!.usingColorSpace(.deviceRGB)!
    assert(red.redComponent > 0.9 && red.blueComponent < 0.1)
    assert(blue.blueComponent > 0.9 && blue.redComponent < 0.1)
    print("Single-use frame capture and PNG channels PASS")
}
"""
        with tempfile.TemporaryDirectory(prefix="gmgn-frame-test-") as directory:
            output = str(Path(directory) / "frame.png")
            result = subprocess.run(["swift", "-", output], input=program, text=True,
                                    capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_frame_capture_is_debug_only_and_requires_ready_full_stage(self):
        source = RENDER.read_text()
        self.assertTrue("#if DEBUG\n// BEGIN DEBUG FRAME CAPTURE" in source)
        self.assertTrue("MarbleDebugFrameCapture.shared != nil" in source)
        self.assertTrue("let frameCapture = MarbleDebugFrameCapture.shared" in source)
        self.assertTrue("isReady: renderer.isReadyToRender" in source)
        self.assertTrue("&& hasPreparedOccluder" in source)


if __name__ == "__main__":
    unittest.main()
