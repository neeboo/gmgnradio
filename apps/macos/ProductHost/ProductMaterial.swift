import AppKit
import SwiftUI

/// Only the original system material primitive. Text, tint, controls, stores,
/// projection and input remain owned by GPUI and its existing backdrop bridge.
@MainActor
private struct ProductPassiveMaterial: View {
    let width: CGFloat
    let height: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if width == height && radius >= width / 2 {
                Circle().fill(.ultraThinMaterial)
            } else {
                RoundedRectangle(cornerRadius: radius).fill(.ultraThinMaterial)
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}

@MainActor
private final class ProductPassiveMaterialHostingView: NSHostingView<ProductPassiveMaterial> {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Owned +1 NSView return. The main-thread caller must transfer/release it,
/// and keep the containing dylib loaded until all returned views are released.
@_cdecl("gmgn_product_material_view_create")
public func gmgnProductMaterialViewCreate(_ width: Double, _ height: Double, _ radius: Double) -> UnsafeMutableRawPointer? {
    guard Thread.isMainThread, width.isFinite, height.isFinite, radius.isFinite,
          width > 0, height > 0, radius >= 0, width <= 4096, height <= 4096 else { return nil }
    let address: UInt = MainActor.assumeIsolated {
        let view = ProductPassiveMaterialHostingView(rootView: ProductPassiveMaterial(
            width: width, height: height, radius: radius
        ))
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.wantsLayer = true
        view.layer?.isOpaque = false
        return UInt(bitPattern: Unmanaged.passRetained(view).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}
