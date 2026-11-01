//
//  DownloadTrackerView.swift
//  Yattee
//
//  Floating progress indicator shown anywhere in the app while downloads are running.
//  Tapping it opens the Downloads screen.
//

import SwiftUI

#if !os(tvOS)

struct DownloadTrackerView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    private var running: [Download] {
        appEnvironment?.downloadManager.activeDownloads
            .filter { $0.status == .downloading || $0.status == .queued } ?? []
    }

    /// Mean progress across running downloads; queued ones count as zero.
    private func overallProgress(of downloads: [Download]) -> Double {
        guard !downloads.isEmpty else { return 0 }
        return downloads.map(\.progress).reduce(0, +) / Double(downloads.count)
    }

    var body: some View {
        let downloads = running
        Group {
            if !downloads.isEmpty, appEnvironment?.navigationCoordinator.isPlayerExpanded != true {
                tracker(downloads)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: downloads.isEmpty)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appEnvironment?.navigationCoordinator.isPlayerExpanded)
    }

    private func tracker(_ downloads: [Download]) -> some View {
        let progress = overallProgress(of: downloads)
        let percent = Int((progress * 100).rounded())

        return Button {
            appEnvironment?.navigationCoordinator.selectedSidebarItem = .downloads
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(progress, 0.02))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .frame(width: 24, height: 24)

                Text(downloads.count > 1 ? "\(downloads.count) · \(percent)%" : "\(percent)%")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.top, topPadding)
        .padding(.trailing, 16)
        .accessibilityLabel(String(localized: "downloads.tracker.accessibilityLabel"))
        .accessibilityValue("\(percent)%")
    }

    private var topPadding: CGFloat {
        #if os(iOS)
        52
        #else
        12
        #endif
    }
}

#endif

extension View {
    /// Adds the floating download tracker at the top trailing edge.
    func downloadTrackerOverlay() -> some View {
        #if os(tvOS)
        self
        #else
        overlay(alignment: .topTrailing) {
            DownloadTrackerView()
        }
        #endif
    }
}
