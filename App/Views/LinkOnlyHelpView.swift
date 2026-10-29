import SwiftUI

/// Shown when only a link arrived (Instagram's usual share). RecipeReel never downloads
/// from Instagram; this explains how to get the video in.
struct LinkOnlyHelpView: View {
    let link: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Instagram only shared a link", systemImage: "link")
                .font(.headline)

            Text("RecipeReel can't download videos from Instagram. To get this recipe in:")
                .font(.subheadline)

            step(1, "Save the video. If Instagram's share menu shows **Download**, use it. Otherwise screen-record the Reel (Control Center → Screen Recording) with the Reel's sound on.")
            step(2, "Share the saved video from Photos to **RecipeReel**, or tap **Choose a video** on the main screen.")
            step(3, "Copy the Reel's caption and paste it below — creators often list ingredients and steps there.")

            if let link {
                Link(destination: link) {
                    Label("Open the Reel", systemImage: "arrow.up.right.square")
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.footnote.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(.tint.opacity(0.2)))
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    List {
        LinkOnlyHelpView(link: URL(string: "https://www.instagram.com/reel/example/"))
    }
}
