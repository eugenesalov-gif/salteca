import Foundation

/// Потокобезопасное хранилище последней применённой замены (хоткеем или
/// авто-режимом). Общий для обоих сервисов — в Python-версии это был модульный
/// global `last_replacement`. Нужен для toggle: повторная правка слова, которое
/// само является результатом предыдущей замены, откатывает её к исходному
/// варианту напрямую, без повторного прогона через эвристику. Благодаря общему
/// store хоткеем можно откатить и авто-правку.
///
/// Хранится только последняя замена (не история), без ограничения по времени —
/// совпадение проверяется по точному тексту.
nonisolated final class ReplacementStore: @unchecked Sendable {

    private struct Replacement {
        let original: String
        let fixed: String
        let direction: LayoutDirection
    }

    private let lock = NSLock()
    private var last: Replacement?

    func record(original: String, fixed: String, direction: LayoutDirection) {
        lock.lock()
        last = Replacement(original: original, fixed: fixed, direction: direction)
        lock.unlock()
    }

    /// Если `word` совпадает с результатом последней замены, возвращает
    /// направление и текст для отката (toggle), иначе `nil`.
    func toggle(for word: String) -> (direction: LayoutDirection, fixed: String)? {
        lock.lock()
        let last = self.last
        lock.unlock()

        guard let last, word == last.fixed else { return nil }
        return (last.direction.opposite, last.original)
    }
}
