// Adapted from PostHog/posthog-ios (MIT), commit a0a71796c2740a82c8a08059bff0f9d464720db0:
// PostHog/SwiftUI/PostHogMaskViewModifier.swift (postHogMask, PostHogMaskReporterView, the
// reporter registry and its first-layout check).
// Changed: the reporter is `CohorlyNoCaptureMarkerView` (WireframeBuilder.swift), also the
// wireframe recorder's cover; the registry is `ReplayNoCaptureMarkers`; no portal, cover or
// inline-mask variants, no presentation-layer geometry.
//
// Copyright (c) 2023 PostHog. Licensed under the MIT License:
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy
//   of this software and associated documentation files (the "Software"), to deal
//   in the Software without restriction, including without limitation the rights
//   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//   copies of the Software, and to permit persons to whom the Software is
//   furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all
//   copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//   SOFTWARE.

#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import UIKit

public extension View {
    /// Session replay hides this view's area. In wireframe mode it is one
    /// opaque placeholder on top of everything else of its window, and
    /// whatever lies entirely inside it is dropped; in screenshot mode the
    /// area is painted over in the image before it leaves the device. Use it
    /// on SwiftUI content that must never appear in a recording.
    ///
    /// - Parameter isEnabled: false records the view as usual. Default true.
    func cohorlyNoCapture(_ isEnabled: Bool = true) -> some View {
        overlay(
            CohorlyNoCaptureMarker(isEnabled: isEnabled)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }
}

/// One transparent view over the content, read at capture time: nothing is
/// cached, so the area cannot go stale when the content moves.
private struct CohorlyNoCaptureMarker: UIViewRepresentable {
    let isEnabled: Bool

    func makeUIView(context: Context) -> CohorlyNoCaptureMarkerView {
        let view = CohorlyNoCaptureMarkerView(frame: .zero)
        view.isMaskingEnabled = isEnabled
        return view
    }

    func updateUIView(_ uiView: CohorlyNoCaptureMarkerView, context: Context) {
        uiView.isMaskingEnabled = isEnabled
    }

    static func dismantleUIView(_ uiView: CohorlyNoCaptureMarkerView, coordinator: ()) {
        ReplayNoCaptureMarkers.unregister(uiView)
    }
}
#endif
