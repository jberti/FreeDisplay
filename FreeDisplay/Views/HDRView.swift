import SwiftUI

struct HDRRowView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isHDROn: Bool = false
    @State private var maxHz: Double = 120
    @State private var isHovered = false

    private let service = HDRService.shared
    private let hzOptions: [Double] = [60, 100, 120]

    var body: some View {
        if !display.isBuiltin && service.isAvailable {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    MenuItemIcon(systemName: "sun.max.trianglebadge.exclamationmark", color: .yellow)
                    Text("HDR")
                        .font(.body)
                    Spacer()
                    Toggle("", isOn: $isHDROn)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.mini)
                        .onChange(of: isHDROn) { _, newValue in
                            service.setHDR(enabled: newValue, for: display.displayID)
                        }
                }

                if isHDROn {
                    HStack(spacing: 4) {
                        Text("Max Hz:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("", selection: $maxHz) {
                            ForEach(hzOptions, id: \.self) { hz in
                                Text("\(Int(hz))Hz").tag(hz)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .labelsHidden()
                        .onChange(of: maxHz) { _, newValue in
                            service.setMaxHDRRefreshRate(newValue, for: display.displayID)
                        }
                    }
                    .padding(.leading, 28)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(isHovered ? 0.06 : 0))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onAppear {
                isHDROn = service.isHDREnabled(for: display.displayID)
                maxHz = service.maxHDRRefreshRate(for: display.displayID)
            }
        }
    }
}
