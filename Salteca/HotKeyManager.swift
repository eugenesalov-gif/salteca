import Foundation
import Carbon.HIToolbox

/// Перехват одного глобального хоткея через Carbon Event Manager
/// (`RegisterEventHotKey`).
///
/// Почему Carbon, а не `NSEvent.addGlobalMonitorForEventsMatchingMask`:
/// `RegisterEventHotKey` регистрирует хоткей по ФИЗИЧЕСКОМУ коду клавиши
/// (`kVK_ANSI_X`), то есть независимо от активной раскладки — как VK_X в
/// Python-версии. При этом он не требует Accessibility только ради детекции,
/// срабатывает ровно один раз на нажатие (без шторма автоповтора), сам
/// «съедает» комбинацию (символ не попадёт в активное приложение) и работает
/// даже когда фронтовое приложение — наше. Global-монитор NSEvent ничего из
/// этого не даёт: он observe-only (не может поглотить событие), требует
/// Accessibility и повторяется при автоповторе.
nonisolated final class HotKeyManager {

    // MARK: - Конфигурация хоткея

    /// Текущий хоткей (физический keyCode + Carbon-модификаторы). По умолчанию —
    /// Cmd+Shift+X, как в прототипе; переопределяется из настроек через `init`/
    /// `update(to:)`.
    private var config: HotKeyConfig

    init(config: HotKeyConfig = .default) {
        self.config = config
    }

    // MARK: - Состояние

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Защита от повторного срабатывания при удержании клавиши (аналог
    /// `hotkey_triggered` в Python-версии). `RegisterEventHotKey` и так шлёт
    /// `kEventHotKeyPressed` один раз за нажатие, но флаг делает поведение
    /// устойчивым к автоповтору по фронту: реагируем только на переход
    /// «отпущено → нажато», сбрасываемся на отпускании.
    private var isArmed = true

    /// Что делать при срабатывании хоткея. Пока — просто печать в консоль;
    /// на следующем шаге сюда подключим LayoutDetector/LayoutMapper.
    var onHotKey: () -> Void = {
        print("🔥 Hotkey Cmd+Shift+X fired")
    }

    // Идентификатор хоткея: сигнатура 'SALT' + порядковый id.
    private let hotKeyID = EventHotKeyID(signature: fourCharCode("SALT"), id: 1)

    // MARK: - Регистрация / снятие

    func register() {
        guard hotKeyRef == nil else { return }

        // Обработчик Carbon — это C-функция без контекста, поэтому пробрасываем
        // указатель на self через userData.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            selfPtr,
            &eventHandler
        )

        let status = RegisterEventHotKey(
            config.keyCode,
            config.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            print("⚠️ RegisterEventHotKey failed with status \(status)")
        } else {
            print("✅ Registered global hotkey \(config.displayString) (keyCode 0x\(String(config.keyCode, radix: 16)))")
        }
    }

    /// Меняет хоткей на лету: снимает старую регистрацию и, если менеджер был
    /// зарегистрирован, ставит новую. Безопасно вызывать в любом состоянии.
    func update(to newConfig: HotKeyConfig) {
        let wasRegistered = hotKeyRef != nil
        if wasRegistered { unregister() }
        config = newConfig
        if wasRegistered { register() }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    deinit {
        unregister()
    }

    // MARK: - Обработка события (вызывается из C-колбэка)

    fileprivate func handlePressed() {
        // Реагируем только на фронт нажатия; удержание/автоповтор игнорируем.
        guard isArmed else { return }
        isArmed = false
        onHotKey()
        // Хоткей не шлёт kEventHotKeyReleased в нашей подписке, поэтому
        // перевзводим флаг сразу — следующий kEventHotKeyPressed это уже
        // новое нажатие. (Carbon и так не автоповторяет hot key.)
        isArmed = true
    }
}

/// Собирает FourCharCode из ASCII-строки (для сигнатуры EventHotKeyID).
private nonisolated func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + FourCharCode(scalar.value & 0xFF)
    }
    return result
}

/// C-совместимый обработчик Carbon: восстанавливает экземпляр менеджера из
/// userData и дёргает его метод.
private nonisolated func hotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.handlePressed()
    return noErr
}
