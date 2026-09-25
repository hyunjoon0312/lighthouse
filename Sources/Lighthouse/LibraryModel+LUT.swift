import AppKit
import Foundation
import LighthouseCore
import UniformTypeIdentifiers

/// LUT 보관 목록과 참조 사진 색감 맞추기.
@MainActor
extension LibraryModel {
    private func knownLUTNames() -> [String: String] {
        var names: [String: String] = [:]
        for photo in photos {
            if let lut = photo.edits.lut, names[lut.id] == nil { names[lut.id] = lut.name }
        }
        return names
    }

    func refreshLUTLibrary() {
        guard catalogLoaded, loadError == nil else { return }
        lutLibraryGeneration += 1
        let token = lutLibraryGeneration
        let names = knownLUTNames()
        isLUTLibraryLoading = true
        lutQueue.async { [lutStore] in
            let result = Result { try lutStore.library(knownNames: names) }
            DispatchQueue.main.async {
                guard token == self.lutLibraryGeneration else { return }
                self.isLUTLibraryLoading = false
                switch result {
                case .success(let items): self.savedLUTs = items; self.lutLibraryError = nil
                case .failure(let error):
                    AppLog.editing.error("LUT library load failed: \(error.localizedDescription, privacy: .private)")
                    self.lutLibraryError = error.localizedDescription
                }
            }
        }
    }

    func presentLUTImport() {
        guard catalogLoaded, loadError == nil, !isLUTImporting, !isLUTLibraryLoading else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.message = "사진용 SDR sRGB 3D .cube 파일을 추가합니다. V-Log, .vlt, 1D LUT는 지원하지 않습니다."
        panel.prompt = "LUT 추가"
        if panel.runModal() == .OK { importLUTs(from: panel.urls) }
    }

    private func importLUTs(from urls: [URL]) {
        guard !urls.isEmpty, catalogLoaded, loadError == nil, !isLUTImporting else { return }
        let photoID = selectedID
        let generation = selectionGeneration
        lutLibraryGeneration += 1
        let libraryToken = lutLibraryGeneration
        isLUTImporting = true
        isLUTLibraryLoading = true
        lutError = nil
        let names = knownLUTNames()
        lutQueue.async { [lutStore] in
            var imported: [LUTAdjustment] = []
            var failures: [String] = []
            for url in urls {
                do { imported.append(try lutStore.importCube(from: url)) }
                catch {
                    AppLog.editing.error("LUT import failed: \(url.lastPathComponent, privacy: .private): \(error.localizedDescription, privacy: .private)")
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            var combinedNames = names
            for lut in imported { combinedNames[lut.id] = lut.name }
            let library = Result { try lutStore.library(knownNames: combinedNames) }
            DispatchQueue.main.async {
                self.isLUTImporting = false
                if libraryToken == self.lutLibraryGeneration {
                    self.isLUTLibraryLoading = false
                    switch library {
                    case .success(let items):
                        self.savedLUTs = items
                        self.lutLibraryError = nil
                    case .failure(let error):
                        var byID = Dictionary(uniqueKeysWithValues: self.savedLUTs.map { ($0.id, $0) })
                        for lut in imported { byID[lut.id] = LUTLibraryItem(id: lut.id, name: lut.name) }
                        self.savedLUTs = byID.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
                        self.lutLibraryError = error.localizedDescription
                    }
                }
                var skippedApplication = false
                if urls.count == 1, imported.count == 1 {
                    if self.selectedID == photoID, self.selectionGeneration == generation,
                       let current = self.selection {
                        var edits = current.edits
                        edits.lut = imported[0]
                        self.updateEdits(edits)
                        self.isOriginal = false
                        self.actualSize = false
                        self.setMode(.edit)
                    } else {
                        skippedApplication = true
                    }
                }
                let summary = "LUT \(imported.count)개 보관 · 실패 \(failures.count)개"
                if !failures.isEmpty, self.selectedID == photoID, self.selectionGeneration == generation {
                    self.lutError = failures.joined(separator: "\n")
                }
                self.operationMessage = summary + (skippedApplication ? " · 사진 선택이 바뀌어 적용하지 않음" : "") +
                    (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
            }
        }
    }

    func selectSavedLUT(_ id: String) {
        if id.isEmpty { removeLUT(); return }
        guard let current = selection, let item = savedLUTs.first(where: { $0.id == id }) else { return }
        guard item.error == nil else { lutError = "사용할 수 없는 LUT: \(item.error ?? "파일 오류")"; return }
        var edits = current.edits
        edits.lut = LUTAdjustment(id: item.id, name: item.name,
                                  intensity: edits.lut?.intensity ?? 1, isEnabled: true)
        updateEdits(edits)
        lutError = nil
        isOriginal = false
        actualSize = false
        setMode(.edit)
    }

    func presentReferenceMatch() {
        guard catalogLoaded, loadError == nil, referenceMatchSource == nil, let source = selection else { return }
        cancelDraft()
        isLocalEditing = false
        referenceMatchSource = source
    }

    func finishReferenceMatch(_ adjustment: LUTAdjustment, apply: Bool, source: PhotoAsset) {
        refreshLUTLibrary()
        guard apply else {
            operationMessage = "색감 LUT를 보관했습니다. 현재 사진의 보정은 유지됩니다."
            return
        }
        guard let current = selection, current.id == source.id, current.edits == source.edits else {
            operationMessage = "색감 LUT를 보관했지만 사진이나 보정이 바뀌어 적용하지 않았습니다."
            return
        }
        var edits = current.edits
        edits.lut = adjustment
        updateEdits(edits)
        isOriginal = false
        actualSize = false
        setMode(.edit)
    }

    func updateLUT(continuous: Bool = false, _ change: (inout LUTAdjustment) -> Void) {
        guard let current = selection, var lut = current.edits.lut else { return }
        var edits = current.edits
        change(&lut)
        edits.lut = lut
        updateEdits(edits, continuous: continuous)
    }

    func removeLUT() {
        guard let current = selection, current.edits.lut != nil else { return }
        var edits = current.edits
        edits.lut = nil
        updateEdits(edits)
        lutError = nil
    }
}
