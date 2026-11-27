import SwiftUI

struct DeviceStatusSectionView: View {
    @Bindable var vm: AppViewModel
    let isCompactSidebar: Bool
    @Binding var isWirelessMode: Bool
    @State private var showingWiFiDevices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("裝置狀態").font(.subheadline).fontWeight(.semibold).foregroundColor(ModernTheme.label)
            if let group = vm.deviceManager as? DeviceGroup {
                ForEach(Array(group.devices.enumerated()), id: \.offset) { index, device in
                    DeviceSlotView(device: device, number: index + 1) { group.disconnectDevice(at: index) }
                }
            }

            HStack {
                DeviceConnectionIndicator(state: vm.deviceManager.connectionState)
                Text(vm.deviceManager.deviceName)
                    .font(.subheadline)
                    .foregroundColor((vm.deviceManager.isConnected || vm.deviceManager.isConnecting) ? .primary : .secondary)
                Spacer()
                if let group = vm.deviceManager as? DeviceGroup {
                    Button(group.isConnecting ? "連線中…" : (group.isConnected ? "新增連線" : "開始連線")) {
                        if isWirelessMode && group.manualRsdHost.isEmpty && group.manualRsdPort.isEmpty {
                            showingWiFiDevices = true
                        } else {
                            group.connectDevice()
                        }
                    }
                        .disabled(group.isConnecting || group.devices.allSatisfy { $0.isConnected })
                    if group.isConnected || group.isConnecting {
                        Button("全部中斷") { group.disconnect() }
                    }
                } else {
                    Button(vm.deviceManager.isConnected ? "中斷連線" : "開始連線") {
                        vm.deviceManager.isConnected ? vm.deviceManager.disconnect() : vm.deviceManager.connectDevice()
                    }
                    .disabled(vm.deviceManager.isConnecting)
                }
            }
            .padding(10)
            .background(ModernTheme.panelRaised)
            .cornerRadius(10)
            .shadow(color: ModernTheme.shadow, radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 6) {
                Text("連線模式")
                    .font(.caption)
                    .foregroundColor(ModernTheme.secondaryLabel)

                Picker("連線模式", selection: $isWirelessMode) {
                    Label("USB", systemImage: "cable.connector")
                        .tag(false)
                    Label("Wi‑Fi", systemImage: "wifi")
                        .tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(vm.deviceManager.isConnecting)
            }
            .padding(10)
            .background(ModernTheme.panelRaised)
            .cornerRadius(10)
            .shadow(color: ModernTheme.shadow, radius: 8, y: 3)

            if let err = vm.deviceManager.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(3)
            } else if !vm.deviceManager.isConnected {
                Text(isWirelessMode
                     ? "確保裝置與 Mac 在同一個 Wi‑Fi 網路，並已透過信任的 USB 完成配對。"
                     : "先插上手機並解鎖，按下開始連線即可。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !vm.deviceManager.debugLog.isEmpty && !vm.isActiveSimulationRunning {
                debugLogPanel
            }

        }
        .sheet(isPresented: $showingWiFiDevices) {
            if let group = vm.deviceManager as? DeviceGroup {
                WiFiDeviceSelectionView(group: group)
            }
        }
    }

    private var debugLogPanel: some View {
        let recentLines = Array(vm.deviceManager.debugLog.suffix(isCompactSidebar ? 5 : 8))

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(recentLines.indices), id: \.self) { index in
                    Text(recentLines[index])
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: isCompactSidebar ? 64 : 90)
        .padding(6)
        .background(ModernTheme.inset)
        .cornerRadius(6)
    }

}

private struct WiFiDeviceSelectionView: View {
    @ObservedObject var group: DeviceGroup
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [DiscoveredWiFiDevice] = []
    @State private var discoveredCount = 0
    @State private var selected = Set<String>()
    @State private var scanning = true
    @State private var error: String?
    @State private var showingLimit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("選擇 Wi‑Fi 裝置").font(.headline)
            if scanning {
                ProgressView("正在掃描 Wi‑Fi 裝置…")
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                Text("找到 \(discoveredCount) 台裝置，可新增 \(devices.count) 台。")
                Text("已選取 \(selected.count) 台")
                if devices.isEmpty { Text("找不到新的裝置，請確認裝置與 Mac 位於同一個 Wi‑Fi 網路。") }
                List(devices, selection: $selected) { device in
                    VStack(alignment: .leading) {
                        Text(device.name)
                        Text(device.id).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(device.id)
                }
            }
            Text("請先透過 USB 信任並配對裝置。⌘ 可多選，⇧ 可選取範圍。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("確定連線") {
                    let available = group.devices.filter { !$0.isConnected && !$0.isConnecting }.count
                    guard selected.count <= available else { showingLimit = true; return }
                    let identifiers = devices.filter { selected.contains($0.id) }.map(\.id)
                    group.connectDevice(selected: identifiers)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(scanning || selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 400)
        .alert("最多同時連線三台裝置", isPresented: $showingLimit) {
            Button("好", role: .cancel) { }
        } message: {
            Text("目前還可新增 \(group.devices.filter { !$0.isConnected && !$0.isConnecting }.count) 台，請調整選取。")
        }
        .task {
            do {
                let found = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[DiscoveredWiFiDevice], Error>) in
                    group.devices[0].discoverWiFiDevices { continuation.resume(with: $0) }
                }
                guard !Task.isCancelled else { return }
                discoveredCount = found.count
                let occupied = Set(group.devices.filter { $0.isConnected || $0.isConnecting }.map(\.tunnelUDID))
                devices = found.filter { !occupied.contains($0.id) }
            } catch {
                self.error = "掃描失敗：\(error.localizedDescription)"
            }
            scanning = false
        }
    }
}

private struct DeviceSlotView: View {
    @ObservedObject var device: DeviceManager
    let number: Int
    let disconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("裝置 \(number)")
                DeviceConnectionIndicator(state: device.connectionState)
                Spacer()
                if device.isConnected || device.isConnecting {
                    Button("中斷", action: disconnect)
                        .accessibilityLabel("中斷裝置 \(number)")
                }
            }
            TextField("裝置 UDID", text: $device.tunnelUDID)
                .disabled(device.isConnected || device.isConnecting)
            Text(device.isConnected ? device.activeConnectionLabel : (device.isWirelessMode ? "Wi‑Fi" : "USB")).font(.caption)
            Text(device.deviceName).font(.caption)
            if let error = device.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(8)
    }
}
