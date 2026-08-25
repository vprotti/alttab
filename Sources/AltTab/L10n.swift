import Foundation

extension Notification.Name {
    static let languageDidChange = Notification.Name("br.com.nasralla.alttab.languageDidChange")
}

enum Language: String, CaseIterable {
    case en = "en"
    case ptBR = "pt-BR"
}

enum L10n {
    /// `preferredLanguages` reflects the user's real language ranking
    /// (AppleLanguages), unlike the region-biased Locale.current.
    static func detectSystemLanguage() -> Language {
        (Locale.preferredLanguages.first?.lowercased().hasPrefix("pt") ?? false) ? .ptBR : .en
    }

    static var current: Language {
        get {
            guard let raw = Prefs.appLanguage, let lang = Language(rawValue: raw) else {
                return detectSystemLanguage()
            }
            return lang
        }
        set {
            Prefs.appLanguage = newValue.rawValue
            NotificationCenter.default.post(name: .languageDidChange, object: nil)
        }
    }

    static func t(_ key: String) -> String {
        guard let pair = table[key] else { return key }
        return current == .ptBR ? pair.pt : pair.en
    }

    private static let table: [String: (en: String, pt: String)] = [
        "menu.settings": (en: "Settings…", pt: "Ajustes…"),
        "menu.quit": (en: "Quit AltTab", pt: "Sair do AltTab"),
        "menu.permissionNeeded": (en: "Permission needed", pt: "Falta permissão"),

        "welcome.title": (en: "Welcome to AltTab", pt: "Bem-vindo ao AltTab"),
        "welcome.subtitle": (en: "Choose your language", pt: "Escolha seu idioma"),
        "welcome.continue": (en: "Continue", pt: "Continuar"),
        "welcome.hint": (en: "Hold ⌥ and press Tab to switch between windows.",
                         pt: "Segure ⌥ e aperte Tab para alternar entre janelas."),

        "perm.title": (en: "Two permissions and you're done",
                       pt: "Duas permissões e está pronto"),
        "perm.accessibility": (en: "Accessibility", pt: "Acessibilidade"),
        "perm.accessibilityWhy": (
            en: "Required. Lets AltTab see the ⌥ Tab shortcut and bring the window you pick to the front.",
            pt: "Obrigatória. Permite que o AltTab veja o atalho ⌥ Tab e traga para a frente a janela que você escolher."),
        "perm.screen": (en: "Screen Recording", pt: "Gravação de Tela"),
        "perm.screenWhy": (
            en: "Optional. Draws a preview of each window and reads window titles. Without it you get app icons and names.",
            pt: "Opcional. Desenha a prévia de cada janela e lê os títulos. Sem ela, você vê o ícone e o nome do app."),
        "perm.grant": (en: "Allow", pt: "Permitir"),
        "perm.granted": (en: "Allowed", pt: "Permitido"),
        "perm.open": (en: "Open Settings", pt: "Abrir Ajustes"),
        "perm.restartNote": (
            en: "macOS usually applies this the moment you flip the switch.",
            pt: "O macOS costuma aplicar isso assim que você liga a chave."),
        // The single most confusing thing that can happen here, so it gets said
        // in full rather than hinted at.
        "perm.stale": (
            en: "Already switched on but AltTab still says no? macOS ties the permission to the exact copy of the app it saw, so a new version arrives as a stranger. In the list below, select AltTab, press the − button to remove it, then add this copy again with +.",
            pt: "Já está ligado e o AltTab continua dizendo que não? O macOS prende a permissão à cópia exata do app que ele viu, então uma versão nova chega como se fosse outro programa. Na lista, selecione o AltTab, aperte o botão − para remover, e adicione esta cópia de novo com o +."),
        "perm.relaunch": (en: "Reopen AltTab", pt: "Reabrir o AltTab"),
        "perm.done": (en: "Done", pt: "Concluir"),

        "settings.title": (en: "AltTab Settings", pt: "Ajustes do AltTab"),
        "settings.shortcut": (en: "Shortcut", pt: "Atalho"),
        "settings.shortcutHint": (
            en: "Hold the modifier and press the key. Release the modifier to switch.",
            pt: "Segure o modificador e aperte a tecla. Solte o modificador para trocar."),
        "settings.recording": (en: "Press a key…", pt: "Aperte uma tecla…"),
        "settings.change": (en: "Change", pt: "Alterar"),
        "settings.includeMinimized": (en: "Include minimized windows",
                                      pt: "Incluir janelas minimizadas"),
        "settings.launchAtLogin": (en: "Launch at login", pt: "Iniciar com o Mac"),
        "settings.loginHint": (en: "Move AltTab to the Applications folder to enable this.",
                               pt: "Mova o AltTab para a pasta Aplicativos para ativar isto."),
        "settings.autoUpdate": (en: "Update automatically", pt: "Atualizar automaticamente"),
        "settings.autoUpdateHint": (en: "Checks nasmac.app daily and installs new versions on its own.",
                                    pt: "Verifica o nasmac.app diariamente e instala as novidades sozinho."),
        "settings.language": (en: "Language", pt: "Idioma"),
        "settings.permissions": (en: "Permissions", pt: "Permissões"),
        "settings.privacy": (en: "Privacy", pt: "Privacidade"),
        "settings.privacyBody": (
            en: "Everything stays on this Mac. AltTab has no server, no account and no analytics. Window previews are drawn on screen and never leave your computer.",
            pt: "Tudo fica neste Mac. O AltTab não tem servidor, conta nem análise de uso. As prévias das janelas são desenhadas na tela e nunca saem do seu computador."),
    ]
}
