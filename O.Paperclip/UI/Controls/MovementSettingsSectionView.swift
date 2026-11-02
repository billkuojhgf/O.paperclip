import SwiftUI
import CoreLocation

struct MovementSettingsSectionView: View {
    @Bindable var vm: AppViewModel
    @Binding var speedText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("移動設定").font(.subheadline).fontWeight(.semibold).foregroundColor(ModernTheme.label)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("當前速度: \(String(format: "%.1f", vm.speed)) km/h")
                    if !vm.routes.isEmpty || vm.totalRouteDistance > 0 {
                        Text("單趟: \(vm.estimatedTime)")
                            .foregroundColor(ModernTheme.info)
                    }
                }
                .font(.callout)
                Slider(
                    value: $vm.speed,
                    in: AppConstants.Simulation.speedStep...vm.maximumSpeed,
                    step: AppConstants.Simulation.speedStep
                )
                HStack(spacing: 8) {
                    TextField("速度", text: $speedText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 88)

                    Stepper(
                        "微調 0.1",
                        value: $vm.speed,
                        in: AppConstants.Simulation.speedStep...vm.maximumSpeed,
                        step: AppConstants.Simulation.speedStep
                    )
                    .fixedSize()
                }
            }

            Toggle("來回巡邏", isOn: $vm.isEndlessLoop)
                .tint(ModernTheme.accent)
                .disabled(vm.operationMode == .multiPoint && vm.isClosedLoop)

            if vm.operationMode == .multiPoint {
                Text(
                    vm.isClosedLoop
                        ? "閉圈啟用時會持續繞圈，來回巡邏會自動關閉。"
                        : "來回巡邏會在非閉圈路線下於終點原路返回。"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            if vm.operationMode == .multiPoint {
                multiPointWaypointControls
                ForEach(Array(vm.waypoints.enumerated()), id: \.offset) { index, coordinate in
                    HStack {
                        Text("P\(index + 1): \(coordinate.latitude, specifier: "%.4f"), \(coordinate.longitude, specifier: "%.4f")")
                            .font(.caption)
                        Spacer()
                        Button { vm.moveWaypoint(from: index, to: index - 1) } label: {
                            Image(systemName: "arrow.up")
                        }
                        .accessibilityLabel("將 P\(index + 1) 上移")
                        .disabled(index == 0 || vm.appState != .selectingA)
                        Button { vm.moveWaypoint(from: index, to: index + 1) } label: {
                            Image(systemName: "arrow.down")
                        }
                        .accessibilityLabel("將 P\(index + 1) 下移")
                        .disabled(index == vm.waypoints.count - 1 || vm.appState != .selectingA)
                    }
                }
                Toggle("閉圈（最後連回 P1）", isOn: $vm.isClosedLoop)
                    .tint(ModernTheme.accent)
                    .disabled(vm.appState != .selectingA && vm.appState != .readyToMove)
            }

        }
    }

    private var multiPointWaypointControls: some View {
        HStack {
            Text("多點數量：\(vm.waypoints.count)")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("移除最後點") {
                vm.removeLastWaypoint()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(vm.waypoints.isEmpty || vm.appState != .selectingA)
        }
    }

}
