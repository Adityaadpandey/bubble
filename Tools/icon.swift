import AppKit
import SwiftUI

// Draws Perch's app icon and saves every size macOS wants, then `iconutil` packs them into Resources/AppIcon.icns.
// Run with `make icon`. The idea: the notch has opened up into a little black island on a warm screen,
// with an orange ping and a couple of lines of question in it, which is what Perch does all day.

struct Icon: View {
    var body: some View {
        ZStack {
            // the screen, as a macOS-style rounded square
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.74, blue: 0.42), Color(red: 0.98, green: 0.38, blue: 0.27)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center)))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 12)

            // the notch, opened up into an island hanging from the top edge, asking something
            NotchShape(radius: 110, earSize: 44)
                .fill(.black)
                .frame(width: 700, height: 470)
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: 56) {
                        HStack(spacing: 36) {
                            Circle().fill(Color(red: 1, green: 0.55, blue: 0.2))
                                .frame(width: 84, height: 84)
                                .shadow(color: .orange.opacity(0.9), radius: 24)
                            VStack(alignment: .leading, spacing: 26) {
                                Capsule().fill(.white).frame(width: 330, height: 36)
                                Capsule().fill(.white.opacity(0.4)).frame(width: 220, height: 36)
                            }
                        }
                        HStack(spacing: 28) {
                            Capsule().fill(Color(red: 1, green: 0.55, blue: 0.2)).frame(width: 220, height: 84)
                            Capsule().fill(.white.opacity(0.18)).frame(width: 220, height: 84)
                        }
                    }
                    .padding(.top, 100)
                }
                .frame(width: 824, height: 824, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        }
        .frame(width: 1024, height: 1024)
    }
}

@main enum MakeIcon {
    @MainActor static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments[1]) // an .iconset folder
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = points * scale
                let renderer = ImageRenderer(content: Icon().scaleEffect(CGFloat(px) / 1024).frame(width: CGFloat(px), height: CGFloat(px)))
                renderer.scale = 1
                guard let image = renderer.cgImage else { fatalError("couldn't draw the icon") }
                let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                try! png.write(to: out.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
            }
        }
    }
}
