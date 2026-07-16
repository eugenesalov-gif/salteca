import SwiftUI
import Carbon.HIToolbox

/// Окно настроек (SwiftUI). Показывает текущий хоткей и позволяет его переназначить.
struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var isRecording = false

    var body: some View {
        Form {
            Section("Хоткей") {
                LabeledContent("Текущая комбинация") {
                    Text(controller.hotKey.displayString)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(isRecording ? .secondary : .primary)
                }
                HStack {
                    Button(isRecording ? "Нажмите комбинацию…  (Esc — отмена)" : "Изменить") {
                        isRecording.toggle()
                    }
                    .disabled(false)
                    if isRecording {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            Section("Звук переключения раскладки") {
                Picker("Звук", selection: $controller.switchSound) {
                    ForEach(SwitchSound.allCases) { sound in
                        Text(sound.displayName).tag(sound)
                    }
                }
                // Проигрываем выбранный звук сразу при смене — превью для
                // пользователя. `.none` — тихий no-op.
                .onChange(of: controller.switchSound) { _, newValue in
                    SwitchSoundPlayer.shared.play(newValue)
                }
            }

            Section("Запуск") {
                // Не $-привязка: геттер читает реальный статус из SMAppService
                // (не сохранённый флаг), поэтому тумблер отражает актуальное
                // состояние автозапуска.
                Toggle("Запускать при входе в систему", isOn: Binding(
                    get: { controller.launchAtLoginEnabled },
                    set: { controller.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        // Невидимый перехватчик клавиш активен только в режиме записи.
        .background(
            HotKeyRecorder(isRecording: $isRecording) { config in
                controller.hotKey = config
                isRecording = false
            }
        )
    }
}

/// Невидимый мост к AppKit: пока `isRecording`, ставит локальный монитор
/// `NSEvent` и перехватывает следующую комбинацию клавиш.
///
/// Локальный монитор (а не first-responder + `keyDown`) выбран намеренно: он
/// видит и комбинации с ⌘, которые иначе ушли бы в обработку key-equivalent'ов
/// меню и до `keyDown` не дошли бы. Возврат `nil` из монитора «съедает» событие,
/// чтобы записываемая комбинация не сработала как обычный шорткат.
struct HotKeyRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCapture: (HotKeyConfig) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            isRecording: isRecording,
            onCapture: onCapture,
            onCancel: { isRecording = false }
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private var monitor: Any?
        private var onCapture: ((HotKeyConfig) -> Void)?
        private var onCancel: (() -> Void)?

        func update(isRecording: Bool,
                    onCapture: @escaping (HotKeyConfig) -> Void,
                    onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
            if isRecording { startIfNeeded() } else { stop() }
        }

        private func startIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == UInt16(kVK_Escape) {
                    self.onCancel?()
                    return nil
                }
                if let config = HotKeyConfig.from(event: event) {
                    self.onCapture?(config)
                    return nil
                }
                // Комбинация без модификаторов — не хоткей: сигналим и ждём дальше.
                NSSound.beep()
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { stop() }
    }
}
