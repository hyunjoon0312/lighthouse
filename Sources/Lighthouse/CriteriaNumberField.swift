import Foundation
import SwiftUI

enum CriteriaNumberParseResult<Value: Equatable>: Equatable {
    case empty
    case valid(Value)
    case invalid
}

enum CriteriaNumberParser {
    static func decimal(_ text: String) -> CriteriaNumberParseResult<Double> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return .invalid }
        return .valid(value)
    }

    static func iso(_ text: String) -> CriteriaNumberParseResult<Int> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if let exact = Int(trimmed) {
            return exact >= 0 ? .valid(exact) : .invalid
        }
        guard let value = Double(trimmed), value.isFinite, value >= 0,
              let rounded = Int(exactly: value.rounded()) else { return .invalid }
        return .valid(rounded)
    }

    static func isoText(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }
}

/// 조건 숫자를 편집 중인 문자열과 마지막으로 적용한 값을 분리해 불완전한 소수·지수 입력을 보존한다.
struct CriteriaNumberField: View {
    private enum Source {
        case decimal(Binding<Double?>)
        case iso(Binding<Int?>)
    }

    private enum ExternalValue: Equatable {
        case decimal(Double?)
        case iso(Int?)
    }

    private let placeholder: String
    private let accessibilityName: String
    private let source: Source
    private let resetID: Int
    @Binding private var isValid: Bool
    @State private var text: String
    @State private var lastCommitted: ExternalValue

    init(_ placeholder: String, accessibilityLabel: String, value: Binding<Double?>,
         isValid: Binding<Bool>, resetID: Int) {
        self.placeholder = placeholder
        accessibilityName = accessibilityLabel
        source = .decimal(value)
        self.resetID = resetID
        _isValid = isValid
        let initial = ExternalValue.decimal(value.wrappedValue)
        _text = State(initialValue: Self.text(for: initial))
        _lastCommitted = State(initialValue: initial)
    }

    init(_ placeholder: String, accessibilityLabel: String, value: Binding<Int?>,
         isValid: Binding<Bool>, resetID: Int) {
        self.placeholder = placeholder
        accessibilityName = accessibilityLabel
        source = .iso(value)
        self.resetID = resetID
        _isValid = isValid
        let initial = ExternalValue.iso(value.wrappedValue)
        _text = State(initialValue: Self.text(for: initial))
        _lastCommitted = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(placeholder, text: $text)
                .accessibilityLabel(accessibilityName)
                .onChange(of: text) { _, newValue in apply(newValue) }
                .onChange(of: externalValue) { _, newValue in
                    guard newValue != lastCommitted else { return }
                    synchronize(to: newValue)
                }
                .onChange(of: resetID) { _, _ in synchronize(to: externalValue) }
            if !isValid {
                Text(validationMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 70, alignment: .leading)
    }

    private var externalValue: ExternalValue {
        switch source {
        case .decimal(let binding): .decimal(binding.wrappedValue)
        case .iso(let binding): .iso(binding.wrappedValue)
        }
    }

    private var validationMessage: String {
        switch source {
        case .decimal: "0 이상의 숫자를 입력하세요."
        case .iso: "ISO 범위 안의 숫자를 입력하세요."
        }
    }

    private func apply(_ draft: String) {
        switch source {
        case .decimal(let binding):
            switch CriteriaNumberParser.decimal(draft) {
            case .empty: commit(.decimal(nil)) { binding.wrappedValue = nil }
            case .valid(let value): commit(.decimal(value)) { binding.wrappedValue = value }
            case .invalid: isValid = false
            }
        case .iso(let binding):
            switch CriteriaNumberParser.iso(draft) {
            case .empty: commit(.iso(nil)) { binding.wrappedValue = nil }
            case .valid(let value): commit(.iso(value)) { binding.wrappedValue = value }
            case .invalid: isValid = false
            }
        }
    }

    private func commit(_ value: ExternalValue, update: () -> Void) {
        lastCommitted = value
        isValid = true
        update()
    }

    private func synchronize(to value: ExternalValue) {
        lastCommitted = value
        isValid = true
        text = Self.text(for: value)
    }

    private static func text(for value: ExternalValue) -> String {
        switch value {
        case .decimal(nil), .iso(nil): ""
        case .decimal(let value?):
            value.rounded() == value && Int(exactly: value) != nil
                ? String(format: "%.0f", value) : String(value)
        case .iso(let value?): CriteriaNumberParser.isoText(value)
        }
    }
}
