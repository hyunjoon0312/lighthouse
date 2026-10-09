import AppKit
import Foundation
import LighthouseCore
import UniformTypeIdentifiers

struct LightroomPresetImportFailure: Identifiable, Equatable, Sendable {
    let id = UUID()
    let filename: String
    let message: String
}

struct LightroomPresetImportSummary: Identifiable, Equatable {
    let id = UUID()
    let imported: [EditPreset]
    let failures: [LightroomPresetImportFailure]
}

struct LightroomPresetSheetRequest: Identifiable {
    enum Content {
        case importResult(LightroomPresetImportSummary)
        case compatibility(EditPreset)
    }

    let id = UUID()
    let content: Content
}

private struct LightroomPresetParsingOutcome: Sendable {
    var presets: [EditPreset] = []
    var failures: [LightroomPresetImportFailure] = []
    var cancelled = false
}

@MainActor
extension LibraryModel {
    func presentLightroomPresetImport() {
        guard catalogLoaded, loadError == nil, presetLoadError == nil, !isPresetImporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xmp") ?? .data,
            UTType(filenameExtension: "lrtemplate") ?? .data,
        ]
        panel.message = "Lightroom .xmp 또는 기존 .lrtemplate 현상 프리셋을 추가합니다. 지원하지 않는 설정은 결과에서 확인할 수 있습니다."
        panel.prompt = "프리셋 가져오기"
        if panel.runModal() == .OK { importLightroomPresets(from: panel.urls) }
    }

    func importLightroomPresets(from urls: [URL]) {
        guard !urls.isEmpty, catalogLoaded, loadError == nil, presetLoadError == nil, !isPresetImporting else { return }
        presetImportGeneration += 1
        let token = presetImportGeneration
        isPresetImporting = true
        operationMessage = "Lightroom 프리셋을 확인하는 중…"

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            var outcome = LightroomPresetParsingOutcome()
            for url in urls {
                if Task.isCancelled {
                    outcome.cancelled = true
                    break
                }
                do {
                    outcome.presets.append(try LightroomPresetImporter.load(url: url))
                } catch {
                    outcome.failures.append(LightroomPresetImportFailure(
                        filename: url.lastPathComponent,
                        message: error.localizedDescription
                    ))
                }
            }
            if Task.isCancelled { outcome.cancelled = true }
            await self?.finishLightroomPresetImport(outcome, generation: token)
        }
        presetImportTask = task
    }

    func cancelPresetImport() {
        guard isPresetImporting || presetImportTask != nil else { return }
        presetImportGeneration += 1
        presetImportTask?.cancel()
        presetImportTask = nil
        isPresetImporting = false
        operationMessage = "Lightroom 프리셋 가져오기를 취소했습니다."
    }

    func presentPresetCompatibility(_ preset: EditPreset) {
        lightroomPresetSheet = LightroomPresetSheetRequest(content: .compatibility(preset))
    }

    private func finishLightroomPresetImport(_ outcome: LightroomPresetParsingOutcome, generation token: Int) {
        guard token == presetImportGeneration else { return }
        presetImportTask = nil
        isPresetImporting = false
        guard !outcome.cancelled else {
            operationMessage = "Lightroom 프리셋 가져오기를 취소했습니다."
            return
        }

        var usedNames = Set(presets.map { Self.presetNameKey($0.name) })
        let imported = outcome.presets.map { preset -> EditPreset in
            var renamed = preset
            renamed.name = Self.availablePresetName(preset.name, usedNames: &usedNames)
            return renamed
        }
        var failures = outcome.failures
        var stored: [EditPreset] = []
        if !imported.isEmpty {
            if let error = writePresets(presets + imported, message: nil) {
                failures.append(LightroomPresetImportFailure(filename: "프리셋 보관함", message: error))
            } else {
                stored = imported
            }
        }

        let summary = LightroomPresetImportSummary(imported: stored, failures: failures)
        lightroomPresetSheet = LightroomPresetSheetRequest(content: .importResult(summary))
        operationMessage = "Lightroom 프리셋 \(stored.count)개 추가 · 실패 \(failures.count)개"
    }

    private static func availablePresetName(_ original: String, usedNames: inout Set<String>) -> String {
        let base = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if usedNames.insert(presetNameKey(base)).inserted { return base }
        var number = 2
        while true {
            let suffix = " (\(number))"
            let candidate = String(base.prefix(max(0, 80 - suffix.count))) + suffix
            if usedNames.insert(presetNameKey(candidate)).inserted { return candidate }
            number += 1
        }
    }

    private static func presetNameKey(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}
