import SwiftUI
import UIKit

struct DiagnosticsSettingsSection: View {
  @State private var enabled = false
  @State private var error: String?
  // Keep the file until onDismiss, after SwiftUI clears the presentation item.
  @State private var exportURL: URL?
  @State private var exportItem: ExportItem?
  @State private var confirmingClear = false

  var body: some View {
    Section("Diagnostics") {
      Toggle("Debug Mode", isOn: Binding(get: { enabled }, set: setEnabled))
      if enabled {
        Button("Export Diagnostics", action: export)
        Button("Clear Logs", role: .destructive) { confirmingClear = true }
      }
      if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
    }
    .sheet(item: $exportItem, onDismiss: removeExport) { item in
      DiagnosticsShareSheet(url: item.url)
    }
    .task {
      do { enabled = try store().isEnabled() } catch { self.error = error.localizedDescription }
    }
    .confirmationDialog("Delete the saved diagnostic logs?", isPresented: $confirmingClear) {
      Button("Clear Logs", role: .destructive) {
        guard enabled else { return }
        do { try store().clear(); error = nil } catch { self.error = error.localizedDescription }
      }
    }
  }

  private struct ExportItem: Identifiable {
    let url: URL
    var id: URL { url }
  }

  private func store() throws -> CompassDiagnostics {
    guard let store = CompassDiagnostics.shared else {
      throw CompassDiagnostics.Failure.unavailable
    }
    return store
  }

  private func setEnabled(_ value: Bool) {
    do {
      try store().setEnabled(value)
      enabled = value
      error = nil
      if !value {
        confirmingClear = false
        exportItem = nil
        removeExport()
      }
    } catch { self.error = error.localizedDescription }
  }

  private func export() {
    guard enabled else { return }
    do {
      removeExport()
      let data = try store().exportJSON()
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("compass-diagnostics.json")
      try data.write(to: url, options: .atomic)
      exportURL = url
      exportItem = ExportItem(url: url)
      error = nil
    } catch { self.error = error.localizedDescription }
  }

  private func removeExport() {
    if let exportURL {
      try? FileManager.default.removeItem(at: exportURL.deletingLastPathComponent())
    }
    exportURL = nil
  }
}

private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
  let url: URL
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: [url], applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
