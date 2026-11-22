import SwiftUI

/// Favorite-folder glyph in the iOS Settings style: accent-tinted symbol on
/// a soft accent wash, so it follows the user's Color setting instead of a
/// hardcoded orange.
struct FolderIconView: View {
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24)
            .fill(Color.biliAccent.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .foregroundStyle(.biliAccent)
            }
    }
}
