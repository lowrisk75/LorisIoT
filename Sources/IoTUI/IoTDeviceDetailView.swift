import SwiftUI
import IoTCore

/// Adaptive native controls, Dynamic Type, semantic status and no color-only feedback.
public struct IoTDeviceDetailView: View {
    @State private var model: IoTDeviceModel
    @Environment(\.iotTheme) private var theme
    @Environment(\.locale) private var locale

    public init(device: Device, provider: any DeviceProvider) {
        _model = State(initialValue: IoTDeviceModel(device: device, provider: provider))
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.device.name, systemImage: symbol).font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    if model.loading {
                        ProgressView { iotText("loading") }
                    } else {
                        valueView.font(.system(.largeTitle, design: .rounded, weight: .semibold))
                            .contentTransition(.numericText())
                        TimelineView(.periodic(from: .now, by: 15)) { timeline in
                            let freshness = model.state?.freshness(at: timeline.date) ?? .unknown
                            Label { iotText("freshness.\(freshness.rawValue)") }
                                icon: { Image(systemName: freshness == .current ? "checkmark.circle" : "clock.badge.exclamationmark") }
                                .font(.subheadline).foregroundStyle(.primary)
                        }
                        if let date = model.state?.observedAt, date > .distantPast {
                            HStack { iotText("last_measurement"); Text(date, style: .relative) }
                                .font(.caption).foregroundStyle(.primary.opacity(0.7))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(24)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: theme.cornerRadius))

                if model.canControl {
                    VStack(alignment: .leading, spacing: 12) {
                        iotText("control").font(.headline)
                        ViewThatFits(in: .horizontal) {
                            HStack { powerButtons }
                            VStack { powerButtons }
                        }
                        if model.phase != .idle {
                            Label { iotText("command.\(model.phase.rawValue)") }
                                icon: { Image(systemName: model.phase == .applied ? "checkmark.circle.fill" : "clock") }
                                .accessibilityIdentifier("iot.command.outcome")
                        }
                    }
                }
                if let issue = model.issue {
                    VStack(alignment: .leading, spacing: 10) {
                        Label { iotText("issue.\(issue.rawValue)") } icon: { Image(systemName: "exclamationmark.triangle") }
                        iotText("recovery.\(issue.rawValue)").font(.subheadline).foregroundStyle(.secondary)
                        Button { Task { await model.refresh() } } label: { iotText("refresh") }
                            .buttonStyle(.bordered).frame(minHeight: 44)
                    }.accessibilityElement(children: .contain)
                }
                if let state = model.state, !state.attributes.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        iotText("measurements").font(.headline)
                        ForEach(state.attributes.keys.sorted(), id: \.self) { key in
                            if let attribute = state.attributes[key] {
                                LabeledContent {
                                    Text(formatted(attribute.value, unit: attribute.unit))
                                } label: { attributeLabel(key, attribute) }
                            }
                        }
                    }
                }
                DisclosureGroup { Text(model.diagnosticSummary).font(.caption.monospaced()).textSelection(.enabled) }
                    label: { iotText("diagnostics") }
            }.padding(20).frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle(model.device.name).tint(theme.tint)
        .task { await model.observe() }
        .refreshable { await model.refresh() }
    }

    private var powerButtons: some View {
        Group {
            Button { Task { await model.setPower(true) } } label: {
                Label { iotText("turn_on") } icon: { Image(systemName: "power") }
                    .frame(maxWidth: .infinity, minHeight: 32)
            }.buttonStyle(.borderedProminent)
            Button { Task { await model.setPower(false) } } label: {
                iotText("turn_off").frame(maxWidth: .infinity, minHeight: 32)
            }.buttonStyle(.bordered)
        }.disabled(model.phase == .sending)
    }
    @ViewBuilder private var valueView: some View {
        if let value = model.state?.primaryValue {
            if case .bool(let on) = value { iotText(on ? "power.on" : "power.off") }
            else {
                Text(formatted(value, unit: model.state?.primaryUnit))
            }
        } else { iotText("value.unknown") }
    }
    private var symbol: String {
        switch model.device.kind {
        case .sensor: "thermometer.medium"
        case .light: "lightbulb"
        case .outlet, .switchDevice: "powerplug"
        default: "house"
        }
    }
    private func attributeLabel(_ key: String, _ value: StateAttribute) -> Text {
        if let name = value.displayName { return Text(name) }
        let localized = Bundle.module.localizedString(forKey: "attribute.\(key)", value: nil, table: nil)
        return localized == "attribute.\(key)" ? Text(key.replacingOccurrences(of: "_", with: " ")) : iotText("attribute.\(key)")
    }
    private func formatted(_ value: StateValue, unit: UnitSymbol?) -> String {
        let number: Double
        switch value {
        case .decimal(let value): number = value
        case .integer(let value): number = Double(value)
        case .string(let value): return value
        default: return "—"
        }
        let suffix = unit.map { $0.symbol.isEmpty ? "" : " " + $0.symbol } ?? ""
        return number.formatted(.number.precision(.fractionLength(0...2)).locale(locale)) + suffix
    }
}
