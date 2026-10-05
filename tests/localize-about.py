#!/usr/bin/env python3
"""Append the About/Help-menu strings to every Localizable.strings table.

One source of truth for the key set, so a key cannot land in one language and
be forgotten in another. Re-running is a no-op for keys already present.

The Help menu's four link rows mirror the repository's issue-template chooser,
so the app and the tracker name the same four destinations the same way.
"""
import pathlib

BLOCKS = {
    "en": {
        "About AppleTree": "About AppleTree",
        "Version %@": "Version %@",
        "AppleTree on GitHub": "AppleTree on GitHub",
        "Bug Report": "Bug Report",
        "Report a bug in AppleTree": "Report a bug in AppleTree",
        "Report a security vulnerability": "Report a security vulnerability",
        "Please review our security policy for more details": "Please review our security policy for more details",
        "Feature request": "Feature request",
        "Propose a feature in Discussions": "Propose a feature in Discussions",
        "Question": "Question",
        "Ask a question in Discussions": "Ask a question in Discussions",
        "Browse the source, releases and issues": "Browse the source, releases and issues",
        "Open source on GitHub": "Open source on GitHub",
        "View license": "View license",
        "AppleTree shows you what is filling your disk, and cleans up the folders tools rebuild on demand. Nothing is removed without your say-so.": "AppleTree shows you what is filling your disk, and cleans up the folders tools rebuild on demand. Nothing is removed without your say-so.",
        "Free for non-commercial use. Dual-licensed: MIT and CC BY-NC-SA 4.0.": "Free for non-commercial use. Dual-licensed: MIT and CC BY-NC-SA 4.0.",
        "© 2026 Emircan ERKUL": "© 2026 Emircan ERKUL",
    },
    "tr": {
        "About AppleTree": "AppleTree Hakkında",
        "Version %@": "Sürüm %@",
        "AppleTree on GitHub": "GitHub'da AppleTree",
        "Bug Report": "Hata bildirimi",
        "Report a bug in AppleTree": "AppleTree'de bir hata bildirin",
        "Report a security vulnerability": "Güvenlik açığı bildirin",
        "Please review our security policy for more details": "Ayrıntılar için lütfen güvenlik politikamıza bakın",
        "Feature request": "Özellik isteği",
        "Propose a feature in Discussions": "Discussions'da bir özellik önerin",
        "Question": "Soru",
        "Ask a question in Discussions": "Discussions'da soru sorun",
        "Browse the source, releases and issues": "Kaynak koduna, sürümlere ve konulara göz atın",
        "Open source on GitHub": "GitHub'da açık kaynak",
        "View license": "Lisansı görüntüle",
        "AppleTree shows you what is filling your disk, and cleans up the folders tools rebuild on demand. Nothing is removed without your say-so.": "AppleTree diskinizi neyin doldurduğunu gösterir ve araçların gerektiğinde yeniden oluşturduğu klasörleri temizler. Siz izin vermeden hiçbir şey silinmez.",
        "Free for non-commercial use. Dual-licensed: MIT and CC BY-NC-SA 4.0.": "Ticari olmayan kullanım için ücretsiz. Çift lisanslı: MIT ve CC BY-NC-SA 4.0.",
        "© 2026 Emircan ERKUL": "© 2026 Emircan ERKUL",
    },
    "de": {
        "About AppleTree": "Über AppleTree",
        "Version %@": "Version %@",
        "AppleTree on GitHub": "AppleTree auf GitHub",
        "Bug Report": "Fehler melden",
        "Report a bug in AppleTree": "Einen Fehler in AppleTree melden",
        "Report a security vulnerability": "Sicherheitslücke melden",
        "Please review our security policy for more details": "Weitere Details finden Sie in unserer Sicherheitsrichtlinie",
        "Feature request": "Funktionswunsch",
        "Propose a feature in Discussions": "Eine Funktion in Discussions vorschlagen",
        "Question": "Frage",
        "Ask a question in Discussions": "Eine Frage in Discussions stellen",
        "Browse the source, releases and issues": "Quellcode, Releases und Issues durchsuchen",
        "Open source on GitHub": "Open Source auf GitHub",
        "View license": "Lizenz ansehen",
        "AppleTree shows you what is filling your disk, and cleans up the folders tools rebuild on demand. Nothing is removed without your say-so.": "AppleTree zeigt Ihnen, was Ihre Festplatte füllt, und räumt Ordner auf, die Tools bei Bedarf neu erstellen. Ohne Ihre Zustimmung wird nichts entfernt.",
        "Free for non-commercial use. Dual-licensed: MIT and CC BY-NC-SA 4.0.": "Kostenlos für nicht-kommerzielle Nutzung. Doppelt lizenziert: MIT und CC BY-NC-SA 4.0.",
        "© 2026 Emircan ERKUL": "© 2026 Emircan ERKUL",
    },
    "fr": {
        "About AppleTree": "À propos d'AppleTree",
        "Version %@": "Version %@",
        "AppleTree on GitHub": "AppleTree sur GitHub",
        "Bug Report": "Signaler un bug",
        "Report a bug in AppleTree": "Signaler un bug dans AppleTree",
        "Report a security vulnerability": "Signaler une vulnérabilité",
        "Please review our security policy for more details": "Consultez notre politique de sécurité pour plus de détails",
        "Feature request": "Demande de fonctionnalité",
        "Propose a feature in Discussions": "Proposer une fonctionnalité dans Discussions",
        "Question": "Question",
        "Ask a question in Discussions": "Poser une question dans Discussions",
        "Browse the source, releases and issues": "Parcourir le code source, les versions et les tickets",
        "Open source on GitHub": "Open source sur GitHub",
        "View license": "Voir la licence",
        "AppleTree shows you what is filling your disk, and cleans up the folders tools rebuild on demand. Nothing is removed without your say-so.": "AppleTree vous montre ce qui remplit votre disque et nettoie les dossiers que les outils recréent à la demande. Rien n'est supprimé sans votre accord.",
        "Free for non-commercial use. Dual-licensed: MIT and CC BY-NC-SA 4.0.": "Gratuit pour un usage non commercial. Double licence : MIT et CC BY-NC-SA 4.0.",
        "© 2026 Emircan ERKUL": "© 2026 Emircan ERKUL",
    },
    "es": {
        "About AppleTree": "Acerca de AppleTree",
        "Version %@": "Versión %@",
        "AppleTree on GitHub": "AppleTree en GitHub",
        "Bug Report": "Informar de un error",
        "Report a bug in AppleTree": "Informa de un error en AppleTree",
        "Report a security vulnerability": "Informar de una vulnerabilidad",
        "Please review our security policy for more details": "Consulta nuestra política de seguridad para más detalles",
        "Feature request": "Solicitud de función",
        "Propose a feature in Discussions": "Propón una función en Discussions",
        "Question": "Pregunta",
        "Ask a question in Discussions": "Haz una pregunta en Discussions",
        "Browse the source, releases and issues": "Explora el código, las versiones y los issues",
        "Open source on GitHub": "Código abierto en GitHub",
        "View license": "Ver la licencia",
        "AppleTree shows you what is filling your disk, and cleans up the folders tools rebuild on demand. Nothing is removed without your say-so.": "AppleTree te muestra qué está llenando tu disco y limpia las carpetas que las herramientas recrean cuando hace falta. No se elimina nada sin tu permiso.",
        "Free for non-commercial use. Dual-licensed: MIT and CC BY-NC-SA 4.0.": "Gratis para uso no comercial. Doble licencia: MIT y CC BY-NC-SA 4.0.",
        "© 2026 Emircan ERKUL": "© 2026 Emircan ERKUL",
    },
    "zh-Hans": {
        "About AppleTree": "关于 AppleTree",
        "Version %@": "版本 %@",
        "AppleTree on GitHub": "GitHub 上的 AppleTree",
        "Bug Report": "报告缺陷",
        "Report a bug in AppleTree": "报告 AppleTree 的缺陷",
        "Report a security vulnerability": "报告安全漏洞",
        "Please review our security policy for more details": "详情请参阅我们的安全政策",
        "Feature request": "功能建议",
        "Propose a feature in Discussions": "在 Discussions 中提出功能建议",
        "Question": "提问",
        "Ask a question in Discussions": "在 Discussions 中提问",
        "Browse the source, releases and issues": "浏览源码、发行版和议题",
        "Open source on GitHub": "在 GitHub 上开源",
        "View license": "查看许可证",
        "AppleTree shows you what is filling your disk, and cleans up the folders tools rebuild on demand. Nothing is removed without your say-so.": "AppleTree 显示磁盘空间被什么占用，并清理工具按需重建的文件夹。未经你同意不会删除任何内容。",
        "Free for non-commercial use. Dual-licensed: MIT and CC BY-NC-SA 4.0.": "非商业用途免费。双重许可：MIT 和 CC BY-NC-SA 4.0。",
        "© 2026 Emircan ERKUL": "© 2026 Emircan ERKUL",
    },
    "ja": {
        "About AppleTree": "AppleTree について",
        "Version %@": "バージョン %@",
        "AppleTree on GitHub": "GitHub の AppleTree",
        "Bug Report": "バグ報告",
        "Report a bug in AppleTree": "AppleTree のバグを報告",
        "Report a security vulnerability": "セキュリティ脆弱性を報告",
        "Please review our security policy for more details": "詳しくはセキュリティポリシーをご確認ください",
        "Feature request": "機能リクエスト",
        "Propose a feature in Discussions": "Discussions で機能を提案",
        "Question": "質問",
        "Ask a question in Discussions": "Discussions で質問する",
        "Browse the source, releases and issues": "ソース、リリース、Issue を見る",
        "Open source on GitHub": "GitHub でオープンソース",
        "View license": "ライセンスを表示",
        "AppleTree shows you what is filling your disk, and cleans up the folders tools rebuild on demand. Nothing is removed without your say-so.": "AppleTree はディスクを圧迫しているものを示し、ツールが再生成するフォルダーを整理します。あなたの同意なく削除されることはありません。",
        "Free for non-commercial use. Dual-licensed: MIT and CC BY-NC-SA 4.0.": "非商用利用は無料。デュアルライセンス：MIT および CC BY-NC-SA 4.0。",
        "© 2026 Emircan ERKUL": "© 2026 Emircan ERKUL",
    },
}

root = pathlib.Path(__file__).resolve().parent.parent
for code, block in BLOCKS.items():
    path = root / "app" / f"{code}.lproj" / "Localizable.strings"
    text = path.read_text(encoding="utf-8")
    missing = [k for k in block if f'"{k}" =' not in text]
    if missing:
        if not text.endswith("\n"):
            text += "\n"
        lines = ["", "/* About panel and Help menu. */"]
        lines += [f'"{k}" = "{block[k]}";' for k in missing]
        path.write_text(text + "\n".join(lines) + "\n", encoding="utf-8")
        print(f"{code}: added {len(missing)} keys")
