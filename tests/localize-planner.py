#!/usr/bin/env python3
"""Append the planner/sign-out strings to every Localizable.strings table.

One source of truth for the key set, so a key cannot land in one language and
be forgotten in another. Re-running is a no-op for keys already present.
"""
import pathlib
import re

BLOCKS = {
    "en": {
        "Choose the planner": "Choose the planner",
        "Sign in to %@…": "Sign in to %@…",
        "Set up %@…": "Set up %@…",
        "Sign out of %@": "Sign out of %@",
        "Sign out of %@?": "Sign out of %@?",
        "Couldn't sign out": "Couldn't sign out",
        "Add a model provider…": "Add a model provider…",
        "%@ (custom)": "%@ (custom)",
        "%@ (not signed in)": "%@ (not signed in)",
        "%@ (not installed)": "%@ (not installed)",
        "%@ is installed but signed out. Signing in lets it plan what can go.": "%@ is installed but signed out. Signing in lets it plan what can go.",
        "%@ forgets the account it is signed in with. The next plan needs a browser sign-in again. Nothing else on your Mac changes.": "%@ forgets the account it is signed in with. The next plan needs a browser sign-in again. Nothing else on your Mac changes.",
        "%@ is still signed in. Sign out from a terminal, then reopen AppleTree.": "%@ is still signed in. Sign out from a terminal, then reopen AppleTree.",
        "%@ is not signed in — sign in from the Clean Up panel.": "%@ is not signed in — sign in from the Clean Up panel.",
        "%@ is not installed — set it up from the Clean Up panel.": "%@ is not installed — set it up from the Clean Up panel.",
    },
    "tr": {
        "Choose the planner": "Planlayıcıyı seç",
        "Sign in to %@…": "%@ oturumunu aç…",
        "Set up %@…": "%@ uygulamasını kur…",
        "Sign out of %@": "%@ oturumunu kapat",
        "Sign out of %@?": "%@ oturumu kapatılsın mı?",
        "Couldn't sign out": "Oturum kapatılamadı",
        "Add a model provider…": "Model sağlayıcı ekle…",
        "%@ (custom)": "%@ (özel)",
        "%@ (not signed in)": "%@ (oturum açık değil)",
        "%@ (not installed)": "%@ (kurulu değil)",
        "%@ is installed but signed out. Signing in lets it plan what can go.": "%@ kurulu ama oturum açık değil. Oturum açmak, nelerin kaldırılabileceğini planlamasını sağlar.",
        "%@ forgets the account it is signed in with. The next plan needs a browser sign-in again. Nothing else on your Mac changes.": "%@, oturum açtığı hesabı unutur. Bir sonraki plan için tarayıcıdan yeniden oturum açmanız gerekir. Mac'inizde başka hiçbir şey değişmez.",
        "%@ is still signed in. Sign out from a terminal, then reopen AppleTree.": "%@ hâlâ oturum açık. Bir terminalden oturumu kapatın, sonra AppleTree'yi yeniden açın.",
        "%@ is not signed in — sign in from the Clean Up panel.": "%@ oturum açık değil — Temizleme panelinden oturum açın.",
        "%@ is not installed — set it up from the Clean Up panel.": "%@ kurulu değil — Temizleme panelinden kurun.",
    },
    "de": {
        "Choose the planner": "Planer wählen",
        "Sign in to %@…": "Bei %@ anmelden…",
        "Set up %@…": "%@ einrichten…",
        "Sign out of %@": "Von %@ abmelden",
        "Sign out of %@?": "Von %@ abmelden?",
        "Couldn't sign out": "Abmelden fehlgeschlagen",
        "Add a model provider…": "Modellanbieter hinzufügen…",
        "%@ (custom)": "%@ (eigener)",
        "%@ (not signed in)": "%@ (nicht angemeldet)",
        "%@ (not installed)": "%@ (nicht installiert)",
        "%@ is installed but signed out. Signing in lets it plan what can go.": "%@ ist installiert, aber nicht angemeldet. Nach der Anmeldung kann es planen, was entfernt werden kann.",
        "%@ forgets the account it is signed in with. The next plan needs a browser sign-in again. Nothing else on your Mac changes.": "%@ vergisst das angemeldete Konto. Der nächste Plan erfordert wieder eine Anmeldung im Browser. Sonst ändert sich nichts auf Ihrem Mac.",
        "%@ is still signed in. Sign out from a terminal, then reopen AppleTree.": "%@ ist weiterhin angemeldet. Melden Sie sich in einem Terminal ab und öffnen Sie AppleTree erneut.",
        "%@ is not signed in — sign in from the Clean Up panel.": "%@ ist nicht angemeldet — melden Sie sich im Bereinigungsfenster an.",
        "%@ is not installed — set it up from the Clean Up panel.": "%@ ist nicht installiert — richten Sie es im Bereinigungsfenster ein.",
    },
    "fr": {
        "Choose the planner": "Choisir le planificateur",
        "Sign in to %@…": "Se connecter à %@…",
        "Set up %@…": "Configurer %@…",
        "Sign out of %@": "Se déconnecter de %@",
        "Sign out of %@?": "Se déconnecter de %@ ?",
        "Couldn't sign out": "Échec de la déconnexion",
        "Add a model provider…": "Ajouter un fournisseur de modèle…",
        "%@ (custom)": "%@ (personnalisé)",
        "%@ (not signed in)": "%@ (non connecté)",
        "%@ (not installed)": "%@ (non installé)",
        "%@ is installed but signed out. Signing in lets it plan what can go.": "%@ est installé mais déconnecté. S'y connecter lui permet de planifier ce qui peut être supprimé.",
        "%@ forgets the account it is signed in with. The next plan needs a browser sign-in again. Nothing else on your Mac changes.": "%@ oublie le compte utilisé. Le prochain plan demandera à nouveau une connexion dans le navigateur. Rien d'autre ne change sur votre Mac.",
        "%@ is still signed in. Sign out from a terminal, then reopen AppleTree.": "%@ est toujours connecté. Déconnectez-vous depuis un terminal, puis rouvrez AppleTree.",
        "%@ is not signed in — sign in from the Clean Up panel.": "%@ n'est pas connecté — connectez-vous depuis le panneau Nettoyage.",
        "%@ is not installed — set it up from the Clean Up panel.": "%@ n'est pas installé — installez-le depuis le panneau Nettoyage.",
    },
    "es": {
        "Choose the planner": "Elegir el planificador",
        "Sign in to %@…": "Iniciar sesión en %@…",
        "Set up %@…": "Configurar %@…",
        "Sign out of %@": "Cerrar la sesión de %@",
        "Sign out of %@?": "¿Cerrar la sesión de %@?",
        "Couldn't sign out": "No se pudo cerrar la sesión",
        "Add a model provider…": "Añadir un proveedor de modelo…",
        "%@ (custom)": "%@ (personalizado)",
        "%@ (not signed in)": "%@ (sesión no iniciada)",
        "%@ (not installed)": "%@ (no instalado)",
        "%@ is installed but signed out. Signing in lets it plan what can go.": "%@ está instalado pero sin sesión iniciada. Al iniciarla podrá planificar qué se puede eliminar.",
        "%@ forgets the account it is signed in with. The next plan needs a browser sign-in again. Nothing else on your Mac changes.": "%@ olvida la cuenta con la que ha iniciado sesión. El próximo plan necesitará iniciar sesión en el navegador otra vez. Nada más cambia en tu Mac.",
        "%@ is still signed in. Sign out from a terminal, then reopen AppleTree.": "%@ sigue con la sesión iniciada. Cierra la sesión desde un terminal y vuelve a abrir AppleTree.",
        "%@ is not signed in — sign in from the Clean Up panel.": "%@ no tiene la sesión iniciada: inicia sesión desde el panel Limpieza.",
        "%@ is not installed — set it up from the Clean Up panel.": "%@ no está instalado: configúralo desde el panel Limpieza.",
    },
    "zh-Hans": {
        "Choose the planner": "选择规划器",
        "Sign in to %@…": "登录 %@…",
        "Set up %@…": "设置 %@…",
        "Sign out of %@": "退出 %@ 登录",
        "Sign out of %@?": "要退出 %@ 登录吗？",
        "Couldn't sign out": "无法退出登录",
        "Add a model provider…": "添加模型提供方…",
        "%@ (custom)": "%@（自定义）",
        "%@ (not signed in)": "%@（未登录）",
        "%@ (not installed)": "%@（未安装）",
        "%@ is installed but signed out. Signing in lets it plan what can go.": "%@ 已安装但未登录。登录后即可规划可删除的内容。",
        "%@ forgets the account it is signed in with. The next plan needs a browser sign-in again. Nothing else on your Mac changes.": "%@ 会忘记当前登录的账户。下次规划需要重新在浏览器中登录。Mac 上的其他内容不会改变。",
        "%@ is still signed in. Sign out from a terminal, then reopen AppleTree.": "%@ 仍处于登录状态。请在终端中退出登录，然后重新打开 AppleTree。",
        "%@ is not signed in — sign in from the Clean Up panel.": "%@ 未登录 — 请在“清理”面板中登录。",
        "%@ is not installed — set it up from the Clean Up panel.": "%@ 未安装 — 请在“清理”面板中设置。",
    },
    "ja": {
        "Choose the planner": "プランナーを選択",
        "Sign in to %@…": "%@ にサインイン…",
        "Set up %@…": "%@ をセットアップ…",
        "Sign out of %@": "%@ からサインアウト",
        "Sign out of %@?": "%@ からサインアウトしますか？",
        "Couldn't sign out": "サインアウトできませんでした",
        "Add a model provider…": "モデルプロバイダを追加…",
        "%@ (custom)": "%@（カスタム）",
        "%@ (not signed in)": "%@（未サインイン）",
        "%@ (not installed)": "%@（未インストール）",
        "%@ is installed but signed out. Signing in lets it plan what can go.": "%@ はインストール済みですが未サインインです。サインインすると削除できるものを計画できます。",
        "%@ forgets the account it is signed in with. The next plan needs a browser sign-in again. Nothing else on your Mac changes.": "%@ はサインイン中のアカウントを忘れます。次回のプランにはブラウザでの再サインインが必要です。Mac 上の他のものは変わりません。",
        "%@ is still signed in. Sign out from a terminal, then reopen AppleTree.": "%@ はまだサインインしています。ターミナルからサインアウトして、AppleTree を開き直してください。",
        "%@ is not signed in — sign in from the Clean Up panel.": "%@ は未サインインです — 「クリーンアップ」パネルからサインインしてください。",
        "%@ is not installed — set it up from the Clean Up panel.": "%@ は未インストールです — 「クリーンアップ」パネルからセットアップしてください。",
    },
}

# Keys retired with the branches that owned them: the panel's menu is now built
# from the planner catalog, so nothing renders these.
RETIRED = ["Choose the agent", "Use %@"]

root = pathlib.Path(__file__).resolve().parents[1]
for code, block in BLOCKS.items():
    path = root / "app" / f"{code}.lproj" / "Localizable.strings"
    text = path.read_text(encoding="utf-8")
    missing = [k for k in block if f'"{k}" =' not in text]
    for key in RETIRED:
        text = re.sub(rf'^"{re.escape(key)}" = .*?;\n', "", text, flags=re.MULTILINE)
    if not missing:
        print(f"{code}: up to date ({len(RETIRED)} retired keys checked)")
    else:
        if not text.endswith("\n"):
            text += "\n"
        lines = [f'\n/* Planner choice and agent sign-out. */']
        for key in missing:
            lines.append(f'"{key}" = "{block[key]}";')
        path.write_text(text + "\n".join(lines) + "\n", encoding="utf-8")
        print(f"{code}: added {len(missing)} keys")

# Added with the caption fix: the panel now names the planner it is about to set
# up, instead of naming whichever agent happened to be installed first.
EXTRA = {
    "en": {"Pick a planner and it plans what can go from this scan.": "Pick a planner and it plans what can go from this scan."},
    "tr": {"Pick a planner and it plans what can go from this scan.": "Bir planlayıcı seçin, bu taramadan nelerin kaldırılabileceğini planlasın."},
    "de": {"Pick a planner and it plans what can go from this scan.": "Wählen Sie einen Planer, und er plant, was entfernt werden kann."},
    "fr": {"Pick a planner and it plans what can go from this scan.": "Choisissez un planificateur et il planifiera ce qui peut être supprimé."},
    "es": {"Pick a planner and it plans what can go from this scan.": "Elige un planificador y planificará qué se puede eliminar."},
    "zh-Hans": {"Pick a planner and it plans what can go from this scan.": "选择一个规划器，它就会规划可删除的内容。"},
    "ja": {"Pick a planner and it plans what can go from this scan.": "プランナーを選ぶと、削除できるものを計画します。"},
}
for code, block in EXTRA.items():
    path = root / "app" / f"{code}.lproj" / "Localizable.strings"
    text = path.read_text(encoding="utf-8")
    missing = [k for k in block if f'"{k}" =' not in text]
    if missing:
        if not text.endswith("\n"):
            text += "\n"
        path.write_text(text + "\n".join(f'"{k}" = "{block[k]}";' for k in missing) + "\n", encoding="utf-8")
        print(f"{code}: added {len(missing)} caption keys")
