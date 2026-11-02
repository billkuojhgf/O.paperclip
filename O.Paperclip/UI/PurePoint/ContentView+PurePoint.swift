import SwiftUI
import MapKit

// The imported models contain only immutable strings, numbers, and arrays of those values.
// Keep their transfer scoped here rather than claiming Sendable for unrelated UI model APIs.
private struct PurePointImportBatch: @unchecked Sendable {
    let overlays: [PurePointOverlay]
}

extension ContentView {
    static func makeOverlayStates(for overlays: [PurePointOverlay]) -> [String: PurePointOverlayUIState] {
        Dictionary(uniqueKeysWithValues: overlays.map { overlay in
            let isEnabled = !overlay.isBuiltIn
            return (overlay.id, PurePointOverlayUIState(overlay: overlay, isEnabled: isEnabled))
        })
    }

    func overlayState(for overlay: PurePointOverlay) -> PurePointOverlayUIState {
        purePointOverlayStates[overlay.id] ?? PurePointOverlayUIState(overlay: overlay, isEnabled: !overlay.isBuiltIn)
    }

    func categoryLookup(for overlay: PurePointOverlay) -> [String: ShuangbeiPurePointCategory] {
        Dictionary(uniqueKeysWithValues: overlay.categories.map { ($0.id, $0) })
    }

    func pointCountByCategory(for overlay: PurePointOverlay) -> [String: Int] {
        Dictionary(grouping: overlay.points, by: \.categoryID).mapValues(\.count)
    }

    func visiblePoints(for overlay: PurePointOverlay) -> [ShuangbeiPurePoint] {
        overlayState(for: overlay).visiblePoints(in: overlay)
    }

    func bindingForOverlayEnabled(_ overlay: PurePointOverlay) -> Binding<Bool> {
        Binding(
            get: { overlayState(for: overlay).isEnabled },
            set: { newValue in
                var state = overlayState(for: overlay)
                state.isEnabled = newValue
                state.isFilterExpanded = newValue ? true : state.isFilterExpanded
                purePointOverlayStates[overlay.id] = state
            }
        )
    }

    func bindingForOverlayState(_ overlay: PurePointOverlay) -> Binding<PurePointOverlayUIState> {
        Binding(
            get: { overlayState(for: overlay) },
            set: { newValue in
                purePointOverlayStates[overlay.id] = newValue
            }
        )
    }

    func bindingForOverlayFilterExpanded(_ overlay: PurePointOverlay) -> Binding<Bool> {
        Binding(
            get: { overlayState(for: overlay).isFilterExpanded },
            set: { newValue in
                var state = overlayState(for: overlay)
                state.isFilterExpanded = newValue
                purePointOverlayStates[overlay.id] = state
            }
        )
    }

    func toggleCategory(_ categoryID: String, in overlay: PurePointOverlay) {
        var state = overlayState(for: overlay)
        if state.selectedCategoryIDs.contains(categoryID) {
            state.selectedCategoryIDs.remove(categoryID)
        } else {
            state.selectedCategoryIDs.insert(categoryID)
        }
        purePointOverlayStates[overlay.id] = state
    }

    func selectAllCategories(in overlay: PurePointOverlay) {
        var state = overlayState(for: overlay)
        state.selectedCategoryIDs = Set(overlay.categories.map(\.id))
        purePointOverlayStates[overlay.id] = state
    }

    func clearAllCategories(in overlay: PurePointOverlay) {
        var state = overlayState(for: overlay)
        state.selectedCategoryIDs.removeAll()
        purePointOverlayStates[overlay.id] = state
    }

    func focusPurePoints(in overlay: PurePointOverlay) {
        let coordinates = visiblePoints(for: overlay).map(\.coordinate)
        guard !coordinates.isEmpty else { return }
        cameraPosition = .region(vm.mapRegion(fitting: coordinates))
    }

    func focusAllPurePoints() {
        let coordinates = visiblePurePoints.map(\.point.coordinate)
        guard !coordinates.isEmpty else { return }
        cameraPosition = .region(vm.mapRegion(fitting: coordinates))
    }

    func syncOverlayStates() {
        var nextStates: [String: PurePointOverlayUIState] = [:]
        for overlay in purePointOverlays {
            let fallback = PurePointOverlayUIState(overlay: overlay, isEnabled: !overlay.isBuiltIn)
            var existing = purePointOverlayStates[overlay.id] ?? fallback
            existing.reconcile(with: overlay)
            nextStates[overlay.id] = existing
        }
        purePointOverlayStates = nextStates
    }

    func persistImportedOverlaySettings() {
        let paths = purePointOverlays
            .filter { !$0.isBuiltIn }
            .compactMap(\.sourceFilePath)
        let titles = purePointOverlays.reduce(into: [String: String]()) { partialResult, overlay in
            guard !overlay.isBuiltIn, let path = overlay.sourceFilePath else { return }
            partialResult[path] = overlay.title
        }
        ImportedPurePointOverlayStore.savePaths(paths)
        ImportedPurePointOverlayStore.saveTitleOverrides(titles)
    }

    func beginImportedPurePointOverlaySession(with urls: [URL]) {
        guard !urls.isEmpty, !isPersistingPurePointImport else { return }
        resetPurePointImportSession()
        purePointImportError = nil
        pendingImportedOverlaySourceURLs = urls
        prepareImportedPurePointOverlays(from: urls)
    }

    func prepareImportedPurePointOverlays(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        let generation = UUID()
        purePointImportGeneration = generation
        let approvedURLs = approvedPurePointRemoteURLs
        isPreparingPurePointImport = true
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    PurePointImportBatch(overlays: try ImportedPurePointOverlayStore.previewOverlays(
                        from: urls,
                        approvedRemoteURLs: approvedURLs
                    ))
                }
            }.value
            guard purePointImportGeneration == generation else { return }
            isPreparingPurePointImport = false
            do {
                let overlays = try result.get().overlays
                purePointImportError = nil
                pendingPurePointRemoteApprovalURLs = []
                isShowingPurePointRemoteApprovalSheet = false
                pendingImportedOverlays = overlays
                pendingImportedOverlayTitles = Dictionary(
                    uniqueKeysWithValues: overlays.map { ($0.id, $0.title) }
                )
                isShowingImportedOverlayNamingSheet = true
            } catch let error as PurePointImportError {
                switch error {
                case .remoteLinkRequiresApproval(let remoteURLs):
                    purePointImportError = nil
                    pendingPurePointRemoteApprovalURLs = remoteURLs
                    isShowingImportedOverlayNamingSheet = false
                    isShowingPurePointRemoteApprovalSheet = true
                default:
                    resetPurePointImportSession()
                    purePointImportError = error.localizedDescription
                }
            } catch {
                resetPurePointImportSession()
                purePointImportError = error.localizedDescription
            }
        }
    }

    func finalizeImportedPurePointOverlays() {
        guard !isPreparingPurePointImport, !pendingImportedOverlays.isEmpty else { return }
        let generation = UUID()
        purePointImportGeneration = generation
        let batch = PurePointImportBatch(overlays: pendingImportedOverlays.map { overlay in
            overlay.renamed(to: pendingImportedOverlayTitles[overlay.id] ?? overlay.title)
        })
        let approvedURLs = approvedPurePointRemoteURLs
        isPreparingPurePointImport = true
        isPersistingPurePointImport = true
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    PurePointImportBatch(overlays: try ImportedPurePointOverlayStore.persistImportedOverlays(
                        batch.overlays,
                        approvedRemoteURLs: approvedURLs
                    ))
                }
            }.value
            guard purePointImportGeneration == generation else { return }
            isPersistingPurePointImport = false
            isPreparingPurePointImport = false
            do {
                commitImportedPurePointOverlays(try result.get().overlays)
                purePointImportError = nil
                resetPurePointImportSession()
            } catch let error as PurePointImportError {
                switch error {
                case .remoteLinkRequiresApproval(let remoteURLs):
                    purePointImportError = nil
                    pendingPurePointRemoteApprovalURLs = remoteURLs
                    isShowingImportedOverlayNamingSheet = false
                    isShowingPurePointRemoteApprovalSheet = true
                default:
                    isShowingImportedOverlayNamingSheet = true
                    purePointImportError = error.localizedDescription
                }
            } catch {
                isShowingImportedOverlayNamingSheet = true
                purePointImportError = error.localizedDescription
            }
        }
    }

    func cancelImportedPurePointOverlays() {
        resetPurePointImportSession()
    }

    func approvePendingPurePointRemoteLinks() {
        let approved = pendingPurePointRemoteApprovalURLs.map(PurePointKMLResolver.normalizedRemoteURL)
        approvedPurePointRemoteURLs.formUnion(approved)
        pendingPurePointRemoteApprovalURLs = []
        isShowingPurePointRemoteApprovalSheet = false
        prepareImportedPurePointOverlays(from: pendingImportedOverlaySourceURLs)
    }

    func cancelPendingPurePointRemoteLinks() {
        resetPurePointImportSession()
    }

    func resetPurePointImportSession() {
        guard !isPersistingPurePointImport else { return }
        purePointImportGeneration = UUID()
        isPreparingPurePointImport = false
        pendingImportedOverlays = []
        pendingImportedOverlayTitles = [:]
        pendingImportedOverlaySourceURLs = []
        pendingPurePointRemoteApprovalURLs = []
        approvedPurePointRemoteURLs = []
        isShowingImportedOverlayNamingSheet = false
        isShowingPurePointRemoteApprovalSheet = false
    }

    func commitImportedPurePointOverlays(_ overlays: [PurePointOverlay]) {
        var overlaysByPath: [String: PurePointOverlay] = Dictionary(
            uniqueKeysWithValues: purePointOverlays
                .filter { !$0.isBuiltIn }
                .compactMap { overlay in
                    guard let path = overlay.sourceFilePath else { return nil }
                    return (path, overlay)
                }
        )
        for overlay in overlays {
            if let path = overlay.sourceFilePath {
                overlaysByPath[path] = overlay
            }
        }
        purePointOverlays = purePointOverlays.filter(\.isBuiltIn)
            + overlaysByPath.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        syncOverlayStates()
        persistImportedOverlaySettings()
    }

    func removeImportedOverlay(_ overlay: PurePointOverlay) {
        ImportedPurePointOverlayStore.deleteStoredOverlay(overlay)
        purePointOverlays.removeAll { $0.id == overlay.id }
        purePointOverlayStates.removeValue(forKey: overlay.id)
        persistImportedOverlaySettings()
    }

    @ViewBuilder
    var importedOverlayNamingSheet: some View {
        ImportedOverlayNamingSheet(
            overlays: pendingImportedOverlays,
            titles: $pendingImportedOverlayTitles,
            onCancel: cancelImportedPurePointOverlays,
            onImport: finalizeImportedPurePointOverlays
        )
        .disabled(isPersistingPurePointImport)
        .interactiveDismissDisabled(isPersistingPurePointImport)
        .overlay {
            if isPersistingPurePointImport {
                ProgressView("正在儲存 KML⋯")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    @ViewBuilder
    var remoteLinkApprovalSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("需要確認遠端 KML")
                .font(.title3)
                .fontWeight(.semibold)

            Text("這批匯入檔案包含 NetworkLink。確認後才會抓取下列網址的內容，本次只在目前匯入流程有效。")
                .foregroundColor(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(pendingPurePointRemoteApprovalURLs, id: \.absoluteString) { url in
                        Text(url.absoluteString)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .frame(minHeight: 120, maxHeight: 260)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    cancelPendingPurePointRemoteLinks()
                }
                .buttonStyle(.bordered)

                Button("確認下載") {
                    approvePendingPurePointRemoteLinks()
                }
                .buttonStyle(.borderedProminent)
                .tint(ModernTheme.accent)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
