import SwiftUI

struct EditSongMetadataSheet: View {
    let song: Song
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var showTitleError = false

    init(song: Song, onSave: @escaping (String, String) -> Void) {
        self.song = song
        self.onSave = onSave
        _title = State(initialValue: song.title)
        _artist = State(initialValue: song.artist)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)
            form
        }
        .frame(width: 380)
        .background(TonoColors.surface)
    }

    private var header: some View {
        HStack {
            Text("Edit Info")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(TonoColors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var form: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Title")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(TonoColors.textSecondary)

                TextField("Song title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                                    .strokeBorder(
                                        showTitleError ? TonoColors.red.opacity(0.7) : Color.white.opacity(0.1),
                                        lineWidth: 1
                                    )
                            )
                    )
                    .onChange(of: title) { _, _ in
                        if showTitleError && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            showTitleError = false
                        }
                    }

                if showTitleError {
                    Text("Title cannot be empty.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(TonoColors.red)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Artist")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(TonoColors.textSecondary)

                TextField("Artist name", text: $artist)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    )
            }

            HStack(spacing: 10) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(TonoColors.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )

                Button("Save") {
                    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedTitle.isEmpty else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showTitleError = true
                        }
                        return
                    }
                    onSave(trimmedTitle, artist)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(TonoColors.background)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                        .fill(TonoColors.cyan)
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .animation(.easeInOut(duration: 0.15), value: showTitleError)
    }
}
