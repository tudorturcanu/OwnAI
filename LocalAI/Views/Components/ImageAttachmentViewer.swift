//
//  ImageAttachmentViewer.swift
//  LocalAI
//

import SwiftUI

/// Full-screen viewer for a photo attached to a chat message: black stage,
/// pinch and double-tap to zoom, pan when zoomed, swipe down to dismiss when
/// not. Presented with `fullScreenCover` from the message bubble.
struct ImageAttachmentViewer: View {
    let image: UIImage
    let onClose: () -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dismissDrag: CGFloat = 0
    @State private var chromeVisible = true

    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .opacity(backdropOpacity)
                    .ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(scale)
                    .offset(x: offset.width, y: offset.height + dismissDrag)
                    .gesture(zoomGesture(in: proxy.size))
                    .simultaneousGesture(panGesture(in: proxy.size))
                    .onTapGesture(count: 2) { location in
                        toggleZoom(at: location, in: proxy.size)
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
                    }
                    .accessibilityLabel(Text("Attached image"))
                    .accessibilityAddTraits(.isImage)

                if chromeVisible {
                    VStack {
                        HStack {
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 40, height: 40)
                                    .background(.white.opacity(0.18), in: Circle())
                            }
                            .accessibilityLabel(Text("Close"))

                            Spacer()

                            ShareLink(item: Image(uiImage: image), preview: SharePreview(Text("Image"), image: Image(uiImage: image))) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 40, height: 40)
                                    .background(.white.opacity(0.18), in: Circle())
                            }
                            .accessibilityLabel(Text("Share"))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        Spacer()
                    }
                    .transition(.opacity)
                }
            }
        }
        .statusBarHidden(!chromeVisible)
        // The cover's default presentation background is the light chat
        // surface, which flashes before the stage draws. Paint it black up
        // front instead of overriding the colour scheme (that re-renders the
        // whole app on presentation and reads as a flicker).
        .presentationBackground(.black)
    }

    private var backdropOpacity: Double {
        // Fade the stage out as the photo is dragged away so the chat shows
        // through, signalling that letting go will dismiss.
        guard scale <= minScale else { return 1 }
        return max(0.3, 1 - Double(abs(dismissDrag)) / 400)
    }

    // MARK: - Gestures

    private func zoomGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let next = (lastScale * value.magnification).clamped(to: minScale...maxScale)
                scale = next
            }
            .onEnded { _ in
                lastScale = scale
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    if scale < minScale { scale = minScale; lastScale = minScale }
                    offset = clampedOffset(offset, in: size)
                    lastOffset = offset
                }
            }
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if scale > minScale {
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                } else {
                    dismissDrag = value.translation.height
                }
            }
            .onEnded { value in
                if scale > minScale {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        offset = clampedOffset(offset, in: size)
                    }
                    lastOffset = offset
                } else if abs(value.translation.height) > 120 || abs(value.predictedEndTranslation.height) > 300 {
                    onClose()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        dismissDrag = 0
                    }
                }
            }
    }

    private func toggleZoom(at location: CGPoint, in size: CGSize) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if scale > minScale {
                scale = minScale
                offset = .zero
            } else {
                scale = 2.5
                // Zoom toward the tapped point so the area under the finger
                // stays put rather than the centre of the image.
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                offset = clampedOffset(
                    CGSize(
                        width: (center.x - location.x) * (scale - 1),
                        height: (center.y - location.y) * (scale - 1)
                    ),
                    in: size
                )
            }
            lastScale = scale
            lastOffset = offset
        }
    }

    /// Keeps the zoomed image from being panned off-screen: the visible
    /// (fitted) image bounds grow with the scale and the offset may only move
    /// the image within that slack.
    private func clampedOffset(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let fitted = fittedImageSize(in: size)
        let maxX = max(0, (fitted.width * scale - size.width) / 2)
        let maxY = max(0, (fitted.height * scale - size.height) / 2)
        return CGSize(
            width: proposed.width.clamped(to: -maxX...maxX),
            height: proposed.height.clamped(to: -maxY...maxY)
        )
    }

    private func fittedImageSize(in size: CGSize) -> CGSize {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return size }
        let ratio = min(size.width / imageSize.width, size.height / imageSize.height)
        return CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
