import SwiftUI
import MapKit

extension ContentView {
    @ViewBuilder
    func purePointOverlaySection(_ overlay: PurePointOverlay, isCompactSidebar: Bool) -> some View {
        PurePointOverlaySection(
            overlay: overlay,
            isCompactSidebar: isCompactSidebar,
            state: bindingForOverlayState(overlay),
            visiblePoints: visiblePoints(for: overlay),
            pointCountByCategory: pointCountByCategory(for: overlay),
            isImported: !overlay.isBuiltIn,
            onToggleEnabled: { newValue in
                var s = overlayState(for: overlay)
                s.isEnabled = newValue
                purePointOverlayStates[overlay.id] = s
            },
            onToggleFilterExpanded: { newValue in
                var s = overlayState(for: overlay)
                s.isFilterExpanded = newValue
                purePointOverlayStates[overlay.id] = s
            },
            onToggleCategory: { categoryID in
                toggleCategory(categoryID, in: overlay)
            },
            onSelectAllCategories: { selectAllCategories(in: overlay) },
            onClearAllCategories: { clearAllCategories(in: overlay) },
            onFocus: { focusPurePoints(in: overlay) },
            onRemoveImported: { removeImportedOverlay(overlay) }
        )
    }

    @ViewBuilder
    var locationInputSection: some View {
        LocationInputSectionView(vm: vm, currentRegion: cameraPosition.region)
    }

    var wirelessModeBinding: Binding<Bool> {
        Binding(
            get: { vm.deviceManager.isWirelessMode },
            set: { newValue in
                let manager = vm.deviceManager
                guard manager.isWirelessMode != newValue else { return }
                guard !manager.isConnecting else { return }

                if manager.isConnected {
                    Task {
                        await manager.disconnectAsync()
                        DispatchQueue.main.async {
                            manager.isWirelessMode = newValue
                            manager.connectDevice()
                        }
                    }
                } else {
                    manager.isWirelessMode = newValue
                }
            }
        )
    }

    var operationModePicker: some View {
        Picker("模式", selection: $vm.operationMode) {
            ForEach(OperationMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .background(ModernTheme.panelRaised.cornerRadius(8))
    }

    func deviceStatusSection(isCompactSidebar: Bool) -> some View {
        DeviceStatusSectionView(
            vm: vm,
            isCompactSidebar: isCompactSidebar,
            isWirelessMode: wirelessModeBinding
        )
    }

    @ViewBuilder
    var pinnedCoordinateSection: some View {
        if let pinned = vm.pinnedCoordinate {
            Text(
                String(
                    format: "目前座標（維持在最後信息送出位置）：%.6f, %.6f",
                    pinned.latitude,
                    pinned.longitude
                )
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
        if let notice = vm.activityNotice {
            Text(notice)
                .font(.caption)
                .foregroundColor(.yellow)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    func sidebarPane(isCompactSidebar: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            ModernTheme.background
                .ignoresSafeArea()

            SidebarView {
                VStack(spacing: 0) {
                    ScrollView {
                        sidebarSections(isCompactSidebar: isCompactSidebar)
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    sidebarFooter(isCompactSidebar: isCompactSidebar)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    func handleDeviceConnectionChange(isConnected: Bool) {
        guard isConnected else {
            vm.handleDeviceDisconnected()
            return
        }

        vm.startIfReadyAndConnected()

        guard let current = vm.currentPosition else { return }
        vm.deviceManager.startContinuousLocationStream()
        Task {
            try? await vm.deviceManager.sendLocationToDeviceAsync(latitude: current.latitude, longitude: current.longitude)
        }
    }

    func handleOperationModeChange() {
        guard !vm.consumeProgrammaticModeResetSuppression() else { return }
        vm.switchModePreservingPinnedLocation()
    }

    func handleCameraPositionChange(_ newValue: MapCameraPosition) {
        if let region = newValue.region {
            let normalized = vm.normalizeMapRegion(region)
            visibleMapRegion = normalized
            vm.persistMapRegion(from: .region(normalized))
        } else {
            vm.persistMapRegion(from: newValue)
        }
    }

    func handlePlaceKeywordChange(_ newValue: String) {
        vm.locationSearchService.updateQuery(newValue, region: cameraPosition.region)
    }

    func clampSpeedIfNeeded(_ newValue: Double) {
        let clamped = min(max(newValue, AppConstants.Simulation.speedStep), vm.maximumSpeed)
        if abs(clamped - newValue) > 0.0001 {
            vm.speed = clamped
        }
    }

    func handleClosedLoopChange(_ isEnabled: Bool) {
        if isEnabled {
            vm.isEndlessLoop = false
        }
    }

    func handleScenePhaseUpdate(_ newPhase: ScenePhase) {
        diagnostics.noteScenePhase(newPhase)
        vm.handleScenePhaseChange(newPhase)
    }

    func handlePurePointImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            beginImportedPurePointOverlaySession(with: urls)
        case .failure(let error):
            resetPurePointImportSession()
            purePointImportError = error.localizedDescription
        }
    }

    func configureCameraRequestHandler() {
        vm.requestCameraPosition = { [weak vm] position in
            guard vm != nil else { return }
            cameraPosition = position
        }
    }

    func sidebarSections(isCompactSidebar: Bool) -> some View {
        VStack(alignment: .leading, spacing: isCompactSidebar ? 12 : 20) {
            operationModePicker
            deviceStatusSection(isCompactSidebar: isCompactSidebar)
            if let record = diagnostics.lastUnexpectedTermination {
                UnexpectedTerminationSectionView(diagnostics: diagnostics, unexpectedTermination: record)
            }
            pinnedCoordinateSection
            StatusViewSection(vm: vm, routeColors: routeColors)
            locationInputSection
            Divider()
            movementSettingsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isCompactSidebar ? 10 : 16)
        .padding(.top, isCompactSidebar ? 8 : 14)
        .padding(.bottom, isCompactSidebar ? 10 : 18)
    }

    @ViewBuilder
    func sidebarFooter(isCompactSidebar: Bool) -> some View {
        SidebarFooterView(
            vm: vm,
            isCompactSidebar: isCompactSidebar
        )
    }

    @ViewBuilder
    func purePointControlsSection(isCompactSidebar: Bool) -> some View {
        PurePointControlsSectionView(
            overlayCount: purePointOverlays.count,
            importError: purePointDropError ?? purePointImportError,
            renderNotice: purePointRenderNotice,
            hasVisiblePoints: !visiblePurePoints.isEmpty,
            onImport: {
                resetPurePointImportSession()
                purePointImportError = nil
                purePointDropError = nil
                isImportingPurePointKML = true
            },
            onDropURLs: handlePurePointDrop,
            onFocusAll: focusAllPurePoints
        ) {
            ForEach(purePointOverlays) { overlay in
                purePointOverlaySection(overlay, isCompactSidebar: isCompactSidebar)
            }
        }
    }

    var speedTextBinding: Binding<String> {
        Binding(
            get: { String(format: "%.1f", vm.speed) },
            set: { vm.setSpeedText($0) }
        )
    }

    @ViewBuilder
    var movementSettingsSection: some View {
        MovementSettingsSectionView(
            vm: vm,
            speedText: speedTextBinding
        )
    }

    var routeReplacementSheetBinding: Binding<Bool> {
        Binding(
            get: { vm.isShowingRouteReplacementConfirmation },
            set: { newValue in
                vm.isShowingRouteReplacementConfirmation = newValue
            }
        )
    }

    var routeReplacementSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("開始新路線")
                .font(.title3)
                .fontWeight(.semibold)

            Text("將以新路線取代目前藍線路線，但不會中斷裝置連線。")
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    vm.cancelRouteReplacement()
                }
                .buttonStyle(.bordered)

                Button("確認開始") {
                    vm.confirmRouteReplacement()
                }
                .buttonStyle(.borderedProminent)
                .tint(ModernTheme.accent)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    func focusImportedGPXRoute(_ route: ImportedGPXRoute) {
        guard !route.points.isEmpty else { return }
        cameraPosition = .region(vm.mapRegion(fitting: route.points))
    }

    var rightSidebarPane: some View {
        RightSidebarView(
            sortMode: $savedLocationSortMode,
            canCreateSavedItem: vm.canSaveCurrentSelection,
            onToggleVisibility: { isRightSidebarVisible = false },
            onCreateSavedItem: { vm.prepareSaveCurrentSelection() },
            noticeText: purePointRenderNotice,
            errorText: vm.savedLocationError
        ) {
            VStack(alignment: .leading, spacing: 16) {
                purePointControlsSection(isCompactSidebar: false)
                ImportedGPXRouteSectionView(
                    vm: vm,
                    importError: gpxDropError ?? vm.gpxImportError,
                    onImport: {
                        vm.resetImportedGPXRouteSession()
                        gpxDropError = nil
                        vm.gpxImportError = nil
                        isImportingGPXRoute = true
                    },
                    onDropURLs: handleGPXDrop,
                    onUse: { route in
                        vm.useImportedGPXRoute(route)
                    },
                    onFocus: { route in
                        focusImportedGPXRoute(route)
                    },
                    onRemove: { route in
                        vm.removeImportedGPXRoute(route)
                    }
                )
            }
        } savedContent: {
            SavedLocationSectionView(
                preview: vm.currentSavableItemPreview,
                items: sortedSavedLocations,
                sortMode: savedLocationSortMode,
                onSavePreview: { vm.prepareSaveCurrentSelection() },
                onApply: { item in
                    vm.applySavedLocation(item)
                },
                onFocus: { item in
                    focusSavedLocation(item)
                },
                onRename: { item in
                    vm.beginRenamingSavedLocation(item)
                },
                onDelete: { item in
                    vm.removeSavedLocation(item)
                }
            )
        }
    }

    var sortedSavedLocations: [SavedLocationItem] {
        switch savedLocationSortMode {
        case .createdAt:
            return vm.savedLocations.sorted { $0.createdAt > $1.createdAt }
        case .region:
            return vm.savedLocations.sorted {
                if $0.regionGroup.sortOrder != $1.regionGroup.sortOrder {
                    return $0.regionGroup.sortOrder < $1.regionGroup.sortOrder
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        case .kind:
            return vm.savedLocations.sorted {
                if $0.kind.sortOrder != $1.kind.sortOrder {
                    return $0.kind.sortOrder < $1.kind.sortOrder
                }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    func focusSavedLocation(_ item: SavedLocationItem) {
        guard !item.coordinates.isEmpty else { return }
        cameraPosition = .region(vm.mapRegion(fitting: item.coordinates))
    }

    func handlePurePointDrop(_ urls: [URL]) -> Bool {
        guard let validURLs = validatedDroppedFiles(
            urls,
            allowedExtension: "kml",
            errorMessage: "這裡只能匯入 KML 檔案"
        ) else {
            return false
        }

        purePointDropError = nil
        purePointImportError = nil
        beginImportedPurePointOverlaySession(with: validURLs)
        return true
    }

    func handleGPXDrop(_ urls: [URL]) -> Bool {
        guard let validURLs = validatedDroppedFiles(
            urls,
            allowedExtension: "gpx",
            errorMessage: "這裡只能匯入 GPX 檔案"
        ) else {
            return false
        }

        gpxDropError = nil
        vm.gpxImportError = nil
        vm.prepareImportedGPXRoutes(from: validURLs)
        return true
    }

    private func validatedDroppedFiles(
        _ urls: [URL],
        allowedExtension: String,
        errorMessage: String
    ) -> [URL]? {
        let localURLs = urls
            .filter(\.isFileURL)
            .map(\.standardizedFileURL)

        let allValid = !localURLs.isEmpty && localURLs.allSatisfy {
            $0.pathExtension.lowercased() == allowedExtension
        }

        guard allValid else {
            if allowedExtension == "kml" {
                purePointDropError = errorMessage
            } else {
                gpxDropError = errorMessage
            }
            return nil
        }

        return localURLs
    }

    var saveCurrentLocationSheet: some View {
        let preview = vm.pendingSavedLocationPreview ?? vm.currentSavableItemPreview
        return SavedLocationNamingSheet(
            title: "儲存\(preview.kindDisplayName)",
            subtitle: "正在儲存：\(preview.sourceLabel)的\(preview.kindDisplayName)。\(preview.summaryText)",
            confirmTitle: preview.actionTitle,
            errorText: vm.savedLocationError,
            name: Binding(
                get: { vm.pendingSavedLocationTitle },
                set: { vm.pendingSavedLocationTitle = $0 }
            ),
            onCancel: { vm.cancelSaveCurrentSelection() },
            onConfirm: { vm.confirmSaveCurrentSelection() }
        )
    }

    func renameSavedLocationSheet(_ item: SavedLocationItem) -> some View {
        SavedLocationNamingSheet(
            title: "重新命名",
            subtitle: "更新「\(item.title)」的顯示名稱。",
            confirmTitle: "儲存名稱",
            errorText: vm.savedLocationError,
            name: Binding(
                get: { vm.pendingSavedLocationTitle },
                set: { vm.pendingSavedLocationTitle = $0 }
            ),
            onCancel: { vm.cancelRenameSavedLocation() },
            onConfirm: { vm.confirmRenameSavedLocation() }
        )
    }

    var importedGPXRouteNamingSheet: some View {
        ImportedGPXRouteNamingSheet(
            routes: vm.pendingImportedGPXRoutes,
            titles: Binding(
                get: { vm.pendingImportedGPXRouteTitles },
                set: { vm.pendingImportedGPXRouteTitles = $0 }
            ),
            onCancel: vm.cancelImportedGPXRoutes,
            onImport: vm.finalizeImportedGPXRoutes
        )
    }

    func handleGPXRouteImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            gpxDropError = nil
            vm.prepareImportedGPXRoutes(from: urls)
        case .failure(let error):
            vm.resetImportedGPXRouteSession()
            vm.gpxImportError = error.localizedDescription
        }
    }

}
