import Foundation
import WhisperShared

extension SyncStatus {
    func label(in language: AppLanguage) -> String {
        let locale = language.locale
        switch self {
        case .disabled:
            return L10n.string( "Uitgeschakeld", locale: locale)
        case .unavailable:
            return L10n.string( "iCloud niet beschikbaar", locale: locale)
        case .requiresApproval(let localCount, let accountChanged):
            let format = accountChanged
                ? L10n.string( "Nieuw iCloud-account — %lld lokale items wachten op toestemming", locale: locale)
                : L10n.string( "%lld lokale items wachten op toestemming", locale: locale)
            return String(
                format: format,
                locale: locale,
                localCount
            )
        case .active(let lastSync):
            guard let lastSync else { return L10n.string( "Actief", locale: locale) }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return String(
                format: L10n.string( "Actief — laatst gesynchroniseerd om %@", locale: locale),
                locale: locale,
                formatter.string(from: lastSync)
            )
        case .error(let message):
            return String(
                format: L10n.string( "Fout: %@", locale: locale),
                locale: locale,
                message
            )
        }
    }
}
