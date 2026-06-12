#!/usr/bin/env python3
# Sally Vanity ETH Generator — native PySide6 desktop app.
# No browser, no HTTP server: a frameless Qt window in a fixed mixed Base-blue /
# Binance-yellow design, with a built-in language switch (EN / 中文 / हिन्दी / ES).
# Drives ./vanity (GPU) or ./vanity-cpu (CPU) via QProcess.
import os, re, sys, math, shutil, shlex, time
try: import psutil
except Exception: psutil = None
from PySide6.QtCore import Qt, QProcess, QRegularExpression, QSize, QTimer
from PySide6.QtGui import (QRegularExpressionValidator, QFont, QGuiApplication, QColor, QIntValidator,
                           QIcon, QPixmap)
from PySide6.QtWidgets import (QApplication, QWidget, QFrame, QLabel, QLineEdit, QPushButton,
    QSlider, QVBoxLayout, QHBoxLayout, QGridLayout, QButtonGroup, QComboBox, QGraphicsDropShadowEffect)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
ASSETS = os.path.join(ROOT, "assets")
def asset(name): return os.path.join(ASSETS, name)
BIN_GPU = os.path.join(ROOT, "vanity")
BIN_CPU = os.path.join(ROOT, "vanity-cpu")

def gpu_build_present():
    """True if a CUDA (GPU) binary was actually built/shipped next to us. We do NOT
    assume per-OS — we detect the real artifact. nvcc only ever produces ./vanity on
    a machine with the CUDA Toolkit, so its presence is the honest capability signal.
    On macOS this is always False (Apple has no NVIDIA GPU and CUDA has no macOS
    target — the last macOS CUDA was 10.2/2019, x86-only, never on Apple Silicon)."""
    return os.path.exists(BIN_GPU) or os.path.exists(BIN_GPU + ".exe")

# label for the "enable GPU" elevation button (shown after a GPU-permission fallback)
ENABLE_GPU_TXT = {
 "en":"Enable GPU (admin)","de":"GPU aktivieren (Admin)","es":"Activar GPU (admin)",
 "fr":"Activer le GPU (admin)","pt":"Ativar GPU (admin)","ru":"Включить GPU (admin)",
 "zh":"启用 GPU（管理员）","ja":"GPUを有効化（管理者）","hi":"GPU सक्षम करें (admin)","ar":"تفعيل GPU (مسؤول)",
}

def elevate_cmd(binpath, args):
    """Return (program, arglist) that runs binpath+args with elevated privileges so
    CUDA can access the GPU. (None,None) if no GUI elevation mechanism is available."""
    binpath = os.path.abspath(binpath)
    if sys.platform.startswith("linux"):
        if shutil.which("pkexec"):
            return ("pkexec", [binpath, *args])              # native PolicyKit dialog; stdio streams back
        for term, pre in (("x-terminal-emulator",["-e"]),("gnome-terminal",["--"]),("konsole",["-e"]),
                          ("xfce4-terminal",["-x"]),("xterm",["-e"])):
            if shutil.which(term):
                inner = "sudo " + " ".join(shlex.quote(a) for a in [binpath, *args]) + "; echo; read -p '[enter]'"
                return (term, [*pre, "sh", "-c", inner])
        return (None, None)
    if sys.platform == "darwin":
        inner = " ".join(shlex.quote(a) for a in [binpath, *args])
        script = 'do shell script "%s" with administrator privileges' % inner.replace("\\","\\\\").replace('"','\\"')
        return ("osascript", ["-e", script])
    if sys.platform == "win32":
        al = ",".join("'%s'" % a.replace("'", "''") for a in args)
        ps = "Start-Process -FilePath '%s' -ArgumentList @(%s) -Verb RunAs -WorkingDirectory '%s'" % (
             binpath.replace("'","''"), al, os.path.dirname(binpath).replace("'","''"))
        return ("powershell", ["-NoProfile", "-Command", ps])
    return (None, None)
BASE_RATE = 380.0   # ~380 Maddr/s raw GPU (RTX 2060); recalibrates live

# ---- fixed mixed palette: Base blue + Binance yellow (NO theme switching) ----
BLUE   = "#3d7bff"   # accent text/borders (brighter than #0052FF for dark contrast)
YELLOW = "#f0b90b"   # Binance yellow
YELLOWB= "#ffd24a"   # bright yellow
PINK   = "#ff5572"   # stop / warnings

# ---- i18n: English default + 9 more world languages ----
LANGS = [("en","English"),("de","Deutsch"),("es","Español"),("fr","Français"),
         ("pt","Português"),("ru","Русский"),("zh","中文"),("ja","日本語"),
         ("hi","हिन्दी"),("ar","العربية")]
I18N = {
"en": {
 "sub":"secp256k1 vanity generator · raw key · BIP39 seed · CREATE/CREATE2 · GPU/CPU",
 "st_idle":"idle","st_search":"searching…","st_found":"found",
 "sec_pattern":"PATTERN","prefix":"Prefix (hex)","suffix":"Suffix (hex)","sec_mode":"MODE",
 "source":"Source","target":"Target","backend":"Backend",
 "passphrase":"Passphrase (SafePal — empty = normal; set = vanity applies only with this passphrase)",
 "nonce":"Deploy nonce (CREATE; 0 = first contract)",
 "ncount":"Check nonces (count from start nonce; 1 = only this, e.g. 2 = nonce 0 or 1)",
 "salt":"Salt (CREATE2, 32-byte hex) — optional","initcode":"Init code (CREATE2, hex) — optional",
 "sec_perf":"GPU PERFORMANCE & PROTECTION","sec_cpu":"CPU THREADS","cpu_threads":"threads",
 "gpu_hint":"Caps GPU usage via duty cycle → short kernel bursts keep the desktop responsive. Recommended ≤ 80% (single GPU).",
 "start":"Start search","stop":"Stop","speed":"SPEED","tried":"TRIED","burst":"BURST","eta":"ETA",
 "gpu_max":"GPU max","difficulty":"Difficulty","avgtime":"Avg. time",
 "seed_note":"Seed mode: ~100 k/s, ≤6–7 chars recommended",
 "res_found":"✓ MATCH FOUND","res_mnemonic":"MNEMONIC (12/24 words)","res_passphrase":"PASSPHRASE (save with the mnemonic)","res_contract":"CONTRACT ADDRESS",
 "res_address":"ADDRESS","res_privkey":"PRIVATE KEY","show":"show","hide":"hide",
 "warn":"⚠ Keep the private key / mnemonic secret — whoever holds it fully controls the address.",
 "foot":"Sally Vanity ETH Generator · local & offline",
 "err_pattern":"Specify a prefix or suffix.","err_binary":"Binary missing ({name}) — run the installer / `make` first.","years":"years",
 "no_gpu_build":"No CUDA binary in this build (./vanity) — e.g. macOS has no CUDA/NVIDIA support. CPU only.",
},
"es": {
 "sub":"generador vanity secp256k1 · raw key · BIP39 seed · CREATE/CREATE2 · GPU/CPU",
 "st_idle":"inactivo","st_search":"buscando…","st_found":"encontrado",
 "sec_pattern":"PATRÓN","prefix":"Prefix (hex)","suffix":"Suffix (hex)","sec_mode":"MODO",
 "source":"Origen","target":"Destino","backend":"Backend",
 "passphrase":"Frase de contraseña (SafePal — vacío = normal; definida = vanity solo se aplica con esta frase)",
 "nonce":"Nonce de despliegue (CREATE; 0 = primer contrato)",
 "ncount":"Comprobar nonces (cuenta desde el nonce inicial; 1 = solo este, p. ej. 2 = nonce 0 o 1)",
 "salt":"Salt (CREATE2, hex de 32 bytes) — opcional","initcode":"Init code (CREATE2, hex) — opcional",
 "sec_perf":"RENDIMIENTO Y PROTECCIÓN DE GPU","res_passphrase":"FRASE DE CONTRASEÑA (guardar con el mnemónico)","sec_cpu":"HILOS DE CPU","cpu_threads":"hilos","no_gpu_build":"Sin binario CUDA en esta compilación (./vanity) — p. ej. macOS no tiene soporte CUDA/NVIDIA. Solo CPU.",
 "gpu_hint":"Limita el uso de GPU mediante ciclo de trabajo → ráfagas cortas de kernel mantienen el escritorio fluido. Recomendado ≤ 80% (GPU única).",
 "start":"Iniciar búsqueda","stop":"Detener","speed":"VELOCIDAD","tried":"PROBADOS","burst":"RÁFAGA","eta":"ETA",
 "gpu_max":"GPU máx","difficulty":"Dificultad","avgtime":"Tiempo medio",
 "seed_note":"Modo Seed: ~100 k/s, ≤6–7 caracteres recomendado",
 "res_found":"✓ COINCIDENCIA ENCONTRADA","res_mnemonic":"MNEMÓNICO (12/24 palabras)","res_contract":"DIRECCIÓN DEL CONTRATO",
 "res_address":"DIRECCIÓN","res_privkey":"CLAVE PRIVADA","show":"mostrar","hide":"ocultar",
 "warn":"⚠ Mantén en secreto la clave privada / mnemónico — quien la posea controla por completo la dirección.",
 "foot":"Sally Vanity ETH Generator · local y sin conexión",
 "err_pattern":"Especifica un prefijo o sufijo.","err_binary":"Falta el binario ({name}) — ejecuta primero el instalador / `make`.","years":"años",
},
"zh": {
 "sub":"secp256k1 靓号生成器 · raw key · BIP39 seed · CREATE/CREATE2 · GPU/CPU",
 "st_idle":"空闲","st_search":"搜索中…","st_found":"已找到",
 "sec_pattern":"匹配模式","prefix":"前缀 (hex)","suffix":"后缀 (hex)","sec_mode":"模式",
 "source":"来源","target":"目标","backend":"后端",
 "passphrase":"密码短语 (SafePal — 留空 = 普通；设置后 = 仅在使用此密码短语时靓号才生效)",
 "nonce":"部署 nonce (CREATE; 0 = 第一个合约)",
 "ncount":"检查 nonce 数量 (从起始 nonce 计数; 1 = 仅此一个，例如 2 = nonce 0 或 1)",
 "salt":"Salt (CREATE2, 32 字节 hex) — 可选","initcode":"初始化代码 (CREATE2, hex) — 可选",
 "sec_perf":"GPU 性能与保护","res_passphrase":"密码短语（与助记词一起保存）","sec_cpu":"CPU 线程","cpu_threads":"线程","no_gpu_build":"此版本无 CUDA 二进制（./vanity）— 例如 macOS 不支持 CUDA/NVIDIA。仅 CPU。",
 "gpu_hint":"通过占空比限制 GPU 占用 → 短内核突发让桌面保持响应。推荐 ≤ 80%（单 GPU）。",
 "start":"开始搜索","stop":"停止","speed":"速度","tried":"已尝试","burst":"突发","eta":"预计剩余",
 "gpu_max":"GPU 上限","difficulty":"难度","avgtime":"平均耗时",
 "seed_note":"Seed 模式：~100 k/s，推荐 ≤6–7 个字符",
 "res_found":"✓ 找到匹配","res_mnemonic":"助记词 (12/24 词)","res_contract":"合约地址",
 "res_address":"地址","res_privkey":"私钥","show":"显示","hide":"隐藏",
 "warn":"⚠ 请妥善保管私钥 / 助记词 — 持有者可完全控制该地址。",
 "foot":"Sally Vanity ETH Generator · 本地离线运行",
 "err_pattern":"请指定前缀或后缀。","err_binary":"缺少二进制文件 ({name}) — 请先运行安装程序 / `make`。","years":"年",
},
"hi": {
 "sub":"secp256k1 वैनिटी जनरेटर · raw key · BIP39 seed · CREATE/CREATE2 · GPU/CPU",
 "st_idle":"निष्क्रिय","st_search":"खोज रहे हैं…","st_found":"मिल गया",
 "sec_pattern":"पैटर्न","prefix":"Prefix (hex)","suffix":"Suffix (hex)","sec_mode":"मोड",
 "source":"स्रोत","target":"लक्ष्य","backend":"बैकएंड",
 "passphrase":"Passphrase (SafePal — खाली = सामान्य; सेट = वैनिटी केवल इसी passphrase के साथ लागू)",
 "nonce":"Deploy nonce (CREATE; 0 = पहला कॉन्ट्रैक्ट)",
 "ncount":"nonce जांचें (start nonce से गिनती; 1 = केवल यही, उदा. 2 = nonce 0 या 1)",
 "salt":"Salt (CREATE2, 32-byte hex) — वैकल्पिक","initcode":"Init code (CREATE2, hex) — वैकल्पिक",
 "sec_perf":"GPU प्रदर्शन और सुरक्षा","res_passphrase":"PASSPHRASE (mnemonic के साथ सहेजें)","sec_cpu":"CPU थ्रेड्स","cpu_threads":"थ्रेड्स","no_gpu_build":"इस build में CUDA बाइनरी (./vanity) नहीं — जैसे macOS में CUDA/NVIDIA समर्थन नहीं। केवल CPU।",
 "gpu_hint":"duty cycle के जरिए GPU उपयोग सीमित करता है → छोटे kernel बर्स्ट डेस्कटॉप को रिस्पॉन्सिव रखते हैं। अनुशंसित ≤ 80% (एकल GPU)।",
 "start":"खोज शुरू करें","stop":"रोकें","speed":"गति","tried":"आज़माए गए","burst":"बर्स्ट","eta":"ETA",
 "gpu_max":"GPU अधिकतम","difficulty":"कठिनाई","avgtime":"औसत समय",
 "seed_note":"Seed मोड: ~100 k/s, ≤6–7 अक्षर अनुशंसित",
 "res_found":"✓ मैच मिला","res_mnemonic":"mnemonic (12/24 शब्द)","res_contract":"कॉन्ट्रैक्ट पता",
 "res_address":"पता","res_privkey":"निजी कुंजी","show":"दिखाएं","hide":"छिपाएं",
 "warn":"⚠ निजी कुंजी / mnemonic गुप्त रखें — जिसके पास यह है वह पते को पूरी तरह नियंत्रित करता है।",
 "foot":"Sally Vanity ETH Generator · लोकल और ऑफलाइन",
 "err_pattern":"एक prefix या suffix निर्दिष्ट करें।","err_binary":"बाइनरी अनुपस्थित ({name}) — पहले installer / `make` चलाएं।","years":"वर्ष",
},
"de": {
 "sub":"secp256k1 Vanity-Generator · raw key · BIP39 seed · CREATE/CREATE2 · GPU/CPU",
 "st_idle":"bereit","st_search":"suche…","st_found":"gefunden",
 "sec_pattern":"MUSTER","prefix":"Prefix (hex)","suffix":"Suffix (hex)","sec_mode":"MODUS",
 "source":"Quelle","target":"Ziel","backend":"Backend",
 "passphrase":"Passphrase (SafePal — leer = normal; gesetzt = Vanity gilt nur mit dieser Passphrase)",
 "nonce":"Deploy-Nonce (CREATE; 0 = erster Contract)",
 "ncount":"Nonces prüfen (Anzahl ab Start-Nonce; 1 = nur diese, z. B. 2 = Nonce 0 oder 1)",
 "salt":"Salt (CREATE2, 32-Byte hex) — optional","initcode":"Init-Code (CREATE2, hex) — optional",
 "sec_perf":"GPU-LEISTUNG & SCHUTZ","res_passphrase":"PASSPHRASE (mit dem Mnemonic speichern)","sec_cpu":"CPU-THREADS","cpu_threads":"Threads",
 "gpu_hint":"Begrenzt die GPU-Auslastung per Duty-Cycle → kurze Kernel-Bursts halten den Desktop responsiv. Empfohlen ≤ 80% (Single-GPU).",
 "start":"Suche starten","stop":"Stoppen","speed":"SPEED","tried":"GEPRÜFT","burst":"BURST","eta":"ETA",
 "gpu_max":"GPU max","difficulty":"Schwierigkeit","avgtime":"Ø-Dauer",
 "seed_note":"Seed-Modus: ~100 k/s, ≤6–7 Zeichen empfohlen",
 "res_found":"✓ TREFFER GEFUNDEN","res_mnemonic":"MNEMONIC (12/24 Wörter)","res_contract":"CONTRACT-ADRESSE",
 "res_address":"ADRESSE","res_privkey":"PRIVATE KEY","show":"anzeigen","hide":"verbergen",
 "warn":"⚠ Private Key / Mnemonic geheim halten — wer sie besitzt, kontrolliert die Adresse vollständig.",
 "foot":"Sally Vanity ETH Generator · lokal & offline",
 "err_pattern":"Prefix oder Suffix angeben.","err_binary":"Binary fehlt ({name}) — erst Installer / `make` ausführen.","years":"Jahre",
 "no_gpu_build":"Kein CUDA-Binary in diesem Build (./vanity) — z. B. macOS hat keine CUDA/NVIDIA-Unterstützung. Nur CPU.",
},
"fr": {
 "sub":"générateur d'adresses vanity secp256k1 · raw key · BIP39 seed · CREATE/CREATE2 · GPU/CPU",
 "st_idle":"inactif","st_search":"recherche…","st_found":"trouvé",
 "sec_pattern":"MOTIF","prefix":"Préfixe (hex)","suffix":"Suffixe (hex)","sec_mode":"MODE",
 "source":"Source","target":"Cible","backend":"Backend",
 "passphrase":"Phrase secrète (SafePal — vide = normal ; définie = la vanity ne s'applique qu'avec cette phrase secrète)",
 "nonce":"Nonce de déploiement (CREATE ; 0 = premier contrat)",
 "ncount":"Vérifier les nonces (nombre à partir du nonce de départ ; 1 = celui-ci uniquement, p. ex. 2 = nonce 0 ou 1)",
 "salt":"Salt (CREATE2, hex 32 octets) — optionnel","initcode":"Code d'initialisation (CREATE2, hex) — optionnel",
 "sec_perf":"PERFORMANCE & PROTECTION GPU","res_passphrase":"PHRASE SECRÈTE (à sauvegarder avec la mnémonique)","sec_cpu":"THREADS CPU","cpu_threads":"threads","no_gpu_build":"Aucun binaire CUDA dans cette build (./vanity) — p. ex. macOS n'a pas de support CUDA/NVIDIA. CPU uniquement.",
 "gpu_hint":"Limite l'utilisation du GPU via un cycle de service → de courtes salves de kernel gardent le bureau réactif. Recommandé ≤ 80 % (GPU unique).",
 "start":"Lancer la recherche","stop":"Arrêter","speed":"VITESSE","tried":"ESSAYÉS","burst":"SALVE","eta":"ETA",
 "gpu_max":"GPU max","difficulty":"Difficulté","avgtime":"Temps moyen",
 "seed_note":"Mode Seed : ~100 k/s, ≤6–7 caractères recommandés",
 "res_found":"✓ CORRESPONDANCE TROUVÉE","res_mnemonic":"MNÉMONIQUE (12/24 mots)","res_contract":"ADRESSE DU CONTRAT",
 "res_address":"ADRESSE","res_privkey":"CLÉ PRIVÉE","show":"afficher","hide":"masquer",
 "warn":"⚠ Gardez la clé privée / mnémonique secrète — quiconque la détient contrôle entièrement l'adresse.",
 "foot":"Sally Vanity ETH Generator · local & hors ligne",
 "err_pattern":"Spécifiez un préfixe ou un suffixe.","err_binary":"Binaire manquant ({name}) — exécutez l'installateur / `make` d'abord.","years":"ans",
},
"pt": {
 "sub":"gerador de endereços personalizados secp256k1 · raw key · BIP39 seed · CREATE/CREATE2 · GPU/CPU",
 "st_idle":"ocioso","st_search":"procurando…","st_found":"encontrado",
 "sec_pattern":"PADRÃO","prefix":"Prefixo (hex)","suffix":"Sufixo (hex)","sec_mode":"MODO",
 "source":"Origem","target":"Destino","backend":"Backend",
 "passphrase":"Senha (SafePal — vazia = normal; definida = o personalizado se aplica apenas com esta senha)",
 "nonce":"Nonce de deploy (CREATE; 0 = primeiro contrato)",
 "ncount":"Verificar nonces (contagem a partir do nonce inicial; 1 = apenas este, ex.: 2 = nonce 0 ou 1)",
 "salt":"Salt (CREATE2, hex de 32 bytes) — opcional","initcode":"Init code (CREATE2, hex) — opcional",
 "sec_perf":"DESEMPENHO E PROTEÇÃO DA GPU","res_passphrase":"SENHA (salvar com a frase mnemônica)","sec_cpu":"THREADS DA CPU","cpu_threads":"threads","no_gpu_build":"Sem binário CUDA nesta build (./vanity) — ex.: macOS não tem suporte CUDA/NVIDIA. Apenas CPU.",
 "gpu_hint":"Limita o uso da GPU via ciclo de trabalho → rajadas curtas de kernel mantêm a área de trabalho responsiva. Recomendado ≤ 80% (GPU única).",
 "start":"Iniciar busca","stop":"Parar","speed":"VELOCIDADE","tried":"TENTADOS","burst":"RAJADA","eta":"ETA",
 "gpu_max":"GPU máx.","difficulty":"Dificuldade","avgtime":"Tempo médio",
 "seed_note":"Modo Seed: ~100 k/s, ≤6–7 caracteres recomendados",
 "res_found":"✓ CORRESPONDÊNCIA ENCONTRADA","res_mnemonic":"FRASE MNEMÔNICA (12/24 palavras)","res_contract":"ENDEREÇO DO CONTRATO",
 "res_address":"ENDEREÇO","res_privkey":"CHAVE PRIVADA","show":"mostrar","hide":"ocultar",
 "warn":"⚠ Mantenha a chave privada / frase mnemônica em segredo — quem a possui controla totalmente o endereço.",
 "foot":"Sally Vanity ETH Generator · local e offline",
 "err_pattern":"Especifique um prefixo ou sufixo.","err_binary":"Binário ausente ({name}) — execute o instalador / `make` primeiro.","years":"anos",
},
"ru": {
 "sub":"secp256k1 генератор красивых адресов · raw key · BIP39 seed · CREATE/CREATE2 · GPU/CPU",
 "st_idle":"ожидание","st_search":"поиск…","st_found":"найдено",
 "sec_pattern":"ШАБЛОН","prefix":"Префикс (hex)","suffix":"Суффикс (hex)","sec_mode":"РЕЖИМ",
 "source":"Источник","target":"Цель","backend":"Бэкенд",
 "passphrase":"Парольная фраза (SafePal — пусто = обычный; задана = красивый адрес действует только с этой фразой)",
 "nonce":"Nonce деплоя (CREATE; 0 = первый контракт)",
 "ncount":"Проверять nonce (количество от начального nonce; 1 = только этот, напр. 2 = nonce 0 или 1)",
 "salt":"Salt (CREATE2, 32-байтный hex) — опционально","initcode":"Init code (CREATE2, hex) — опционально",
 "sec_perf":"ПРОИЗВОДИТЕЛЬНОСТЬ И ЗАЩИТА GPU","res_passphrase":"ПАРОЛЬНАЯ ФРАЗА (хранить с мнемоникой)","sec_cpu":"ПОТОКИ CPU","cpu_threads":"потоки","no_gpu_build":"В этой сборке нет CUDA-бинарника (./vanity) — напр. macOS не поддерживает CUDA/NVIDIA. Только CPU.",
 "gpu_hint":"Ограничивает использование GPU через рабочий цикл → короткие всплески ядра сохраняют отзывчивость системы. Рекомендуется ≤ 80% (один GPU).",
 "start":"Начать поиск","stop":"Стоп","speed":"СКОРОСТЬ","tried":"ПРОВЕРЕНО","burst":"ВСПЛЕСК","eta":"ETA",
 "gpu_max":"Макс. GPU","difficulty":"Сложность","avgtime":"Ср. время",
 "seed_note":"Режим Seed: ~100 k/s, рекомендуется ≤6–7 символов",
 "res_found":"✓ СОВПАДЕНИЕ НАЙДЕНО","res_mnemonic":"МНЕМОНИКА (12/24 слова)","res_contract":"АДРЕС КОНТРАКТА",
 "res_address":"АДРЕС","res_privkey":"ПРИВАТНЫЙ КЛЮЧ","show":"показать","hide":"скрыть",
 "warn":"⚠ Храните приватный ключ / мнемонику в секрете — кто им владеет, полностью контролирует адрес.",
 "foot":"Sally Vanity ETH Generator · локально и офлайн",
 "err_pattern":"Укажите префикс или суффикс.","err_binary":"Бинарный файл отсутствует ({name}) — сначала запустите установщик / `make`.","years":"лет",
},
"ja": {
 "sub":"secp256k1 バニティジェネレーター · raw key · BIP39 seed · CREATE/CREATE2 · GPU/CPU",
 "st_idle":"待機中","st_search":"検索中…","st_found":"発見",
 "sec_pattern":"パターン","prefix":"プレフィックス (hex)","suffix":"サフィックス (hex)","sec_mode":"モード",
 "source":"ソース","target":"ターゲット","backend":"バックエンド",
 "passphrase":"パスフレーズ (SafePal — 空 = 通常; 設定 = このパスフレーズでのみバニティ適用)",
 "nonce":"デプロイ nonce (CREATE; 0 = 最初のコントラクト)",
 "ncount":"nonce 確認数 (開始 nonce からの数; 1 = これのみ、例: 2 = nonce 0 または 1)",
 "salt":"ソルト (CREATE2, 32バイト hex) — 任意","initcode":"Init コード (CREATE2, hex) — 任意",
 "sec_perf":"GPU パフォーマンス & 保護","res_passphrase":"パスフレーズ（ニーモニックと一緒に保存）","sec_cpu":"CPU スレッド","cpu_threads":"スレッド","no_gpu_build":"このビルドに CUDA バイナリ（./vanity）はありません — 例: macOS は CUDA/NVIDIA 非対応。CPU のみ。",
 "gpu_hint":"デューティサイクルで GPU 使用率を制限 → 短いカーネルバーストでデスクトップの応答性を維持。推奨 ≤ 80% (単一 GPU)。",
 "start":"検索開始","stop":"停止","speed":"速度","tried":"試行回数","burst":"バースト","eta":"ETA",
 "gpu_max":"GPU 最大","difficulty":"難易度","avgtime":"平均時間",
 "seed_note":"Seed モード: ~100 k/s, ≤6–7 文字推奨",
 "res_found":"✓ 一致を発見","res_mnemonic":"ニーモニック (12/24 語)","res_contract":"コントラクトアドレス",
 "res_address":"アドレス","res_privkey":"秘密鍵","show":"表示","hide":"非表示",
 "warn":"⚠ 秘密鍵 / ニーモニックは秘密に保ってください — 保持する者がアドレスを完全に管理できます。",
 "foot":"Sally Vanity ETH Generator · ローカル & オフライン",
 "err_pattern":"プレフィックスまたはサフィックスを指定してください。","err_binary":"バイナリがありません ({name}) — 先にインストーラー / `make` を実行してください。","years":"年",
},
"ar": {
 "sub":"مولّد عناوين secp256k1 المميّزة · Raw Key · بذرة BIP39 · CREATE/CREATE2 · GPU/CPU",
 "st_idle":"خامل","st_search":"جارٍ البحث…","st_found":"تم العثور",
 "sec_pattern":"النمط","prefix":"بادئة (hex)","suffix":"لاحقة (hex)","sec_mode":"الوضع",
 "source":"المصدر","target":"الهدف","backend":"الخلفية",
 "passphrase":"عبارة المرور (SafePal — فارغة = عادي؛ مضبوطة = يُطبَّق التميّز فقط مع عبارة المرور هذه)",
 "nonce":"nonce النشر (CREATE؛ 0 = أول عقد)",
 "ncount":"فحص قيم nonce (العدد بدءًا من nonce البداية؛ 1 = هذه فقط، مثلاً 2 = nonce 0 أو 1)",
 "salt":"Salt (CREATE2، hex بطول 32 بايت) — اختياري","initcode":"Init code (CREATE2، hex) — اختياري",
 "sec_perf":"أداء GPU والحماية","res_passphrase":"عبارة المرور (احفظها مع العبارة التذكيرية)","sec_cpu":"خيوط CPU","cpu_threads":"خيوط","no_gpu_build":"لا يوجد ثنائي CUDA في هذا الإصدار (./vanity) — مثلاً macOS لا يدعم CUDA/NVIDIA. CPU فقط.",
 "gpu_hint":"يحدّ من استخدام GPU عبر دورة التشغيل → دفعات نواة قصيرة تُبقي سطح المكتب مستجيبًا. يُوصى بـ ≤ 80% (GPU واحد).",
 "start":"بدء البحث","stop":"إيقاف","speed":"السرعة","tried":"المُجرَّبة","burst":"الدفعة","eta":"الوقت المتبقّي",
 "gpu_max":"الحد الأقصى لـ GPU","difficulty":"الصعوبة","avgtime":"متوسط الوقت",
 "seed_note":"وضع Seed: ~100 k/s، يُوصى بـ ≤6–7 أحرف",
 "res_found":"✓ تمت المطابقة","res_mnemonic":"العبارة التذكيرية (12/24 كلمة)","res_contract":"عنوان العقد",
 "res_address":"العنوان","res_privkey":"المفتاح الخاص","show":"إظهار","hide":"إخفاء",
 "warn":"⚠ احتفظ بسرّية المفتاح الخاص / العبارة التذكيرية — من يملكها يتحكّم بالعنوان بالكامل.",
 "foot":"Sally Vanity ETH Generator · محلي وغير متصل",
 "err_pattern":"حدّد بادئة أو لاحقة.","err_binary":"الملف الثنائي مفقود ({name}) — شغّل المثبّت / `make` أولاً.","years":"سنوات",
},
}

# groups: 1=Gaddr 2=elapsed 3=Maddr/s 4=ETA. burst (GPU/CPU lines only) parsed separately.
PROG  = re.compile(r"([\d.]+) Gaddr\s+([\d.]+) s\s+([\d.]+) Maddr/s.*?ETA~([\d.]+)s")
BURST = re.compile(r"burst=([\d.]+)ms")
ADDR = re.compile(r"address\s*:\s*0x([0-9a-fA-FxX]{40})")
KEY  = re.compile(r"private key\s*:\s*0x([0-9a-fA-F]{64})")
MNE  = re.compile(r"mnemonic\s*:\s*(.+)")
PASS = re.compile(r"passphrase\s*:\s*(.+)")
CON  = re.compile(r"contract\s*:\s*0x([0-9a-fA-FxX]{40})")

QSS = f"""
* {{ font-family: 'JetBrains Mono','JetBrainsMono Nerd Font','Noto Sans CJK SC','Noto Sans CJK JP','Noto Sans Devanagari','Noto Sans Arabic','Noto Sans',monospace; color:#fff; }}
#card {{ background: qlineargradient(x1:0,y1:0,x2:0,y2:1,
            stop:0 rgba(24,29,40,255), stop:0.04 rgba(20,24,32,255), stop:1 rgba(6,9,15,255));
        border:1px solid rgba(255,255,255,24); border-top:1px solid rgba(61,123,255,90); border-radius:16px; }}
#brand {{ font-size:19px; font-weight:700; color:{YELLOW}; letter-spacing:1px; }}
#brand2 {{ font-size:19px; font-weight:700; color:{BLUE}; letter-spacing:1px; }}
#tag  {{ font-size:11px; color:rgba(255,255,255,90); letter-spacing:1px; }}
#sub  {{ font-size:11px; color:rgba(255,255,255,140); }}
#stext{{ font-size:11px; color:rgba(255,255,255,150); letter-spacing:.5px; }}
.label{{ font-size:10px; letter-spacing:2px; color:rgba(255,255,255,100); }}
.small{{ font-size:10px; color:rgba(255,255,255,100); }}
#hint {{ font-size:10px; color:rgba(255,255,255,95); }}
QFrame.input {{ background:rgba(255,255,255,10); border:1px solid rgba(255,255,255,22); border-radius:8px; }}
QFrame.input:focus-within {{ background:rgba(61,123,255,14); border:1px solid {BLUE}; }}
QFrame.input QLabel {{ color:rgba(255,255,255,90); font-size:13px; }}
QLineEdit.cell {{ background:transparent; border:none; font-size:15px; letter-spacing:2px; padding:9px 4px; }}
QPushButton.seg {{ background:rgba(255,255,255,8); border:1px solid rgba(255,255,255,18); color:rgba(255,255,255,150);
                  border-radius:7px; padding:8px 6px; font-size:11px; letter-spacing:.5px; }}
QPushButton.seg:hover {{ color:#fff; border:1px solid rgba(255,255,255,40); }}
QPushButton.seg:checked {{ background:rgba(0,82,255,48); border:1px solid {BLUE}; color:#cfe0ff; }}
QPushButton.go   {{ background:qlineargradient(x1:0,y1:0,x2:0,y2:1, stop:0 rgba(0,82,255,55), stop:1 rgba(0,82,255,30));
                   border:1px solid {BLUE}; color:#dbe6ff; border-radius:8px; padding:12px; font-size:13px; letter-spacing:.5px; }}
QPushButton.go:hover   {{ background:qlineargradient(x1:0,y1:0,x2:0,y2:1, stop:0 rgba(0,82,255,90), stop:1 rgba(0,82,255,55)); color:#fff; }}
QPushButton.stop {{ background:rgba(255,85,114,26); border:1px solid rgba(255,85,114,95); color:{PINK}; border-radius:6px; padding:11px; font-size:13px; }}
QPushButton.stop:hover {{ background:rgba(255,85,114,50); }}
QPushButton:disabled {{ color:rgba(255,255,255,55); border-color:rgba(255,255,255,25); background:rgba(255,255,255,8); }}
QFrame.stat {{ background:rgba(255,255,255,6); border:1px solid rgba(255,255,255,14); border-radius:8px; }}
QFrame.stat .k {{ font-size:9px; letter-spacing:1px; color:rgba(255,255,255,95); }}
QFrame.stat .v {{ font-size:16px; color:{YELLOW}; }}
#diff {{ font-size:11px; color:rgba(255,255,255,150); }}
#diff b {{ color:{YELLOW}; }}
#result {{ background:qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 rgba(0,82,255,28), stop:0.5 rgba(0,82,255,10), stop:1 rgba(240,185,11,22));
          border:1px solid {YELLOW}; border-radius:16px; }}
#rk {{ font-size:9px; letter-spacing:1.5px; color:rgba(255,255,255,95); }}
QLineEdit.mono {{ background:rgba(0,0,0,110); border:1px solid rgba(255,255,255,30); border-radius:6px; padding:9px 11px; font-size:12px; }}
QLineEdit.addr {{ color:{BLUE}; }} QLineEdit.key {{ color:{YELLOW}; }} QLineEdit.mne {{ color:{YELLOWB}; }}
QLineEdit.con {{ color:{BLUE}; }}
QPushButton.copy {{ background:rgba(255,255,255,12); border:1px solid rgba(255,255,255,30); color:rgba(255,255,255,150); border-radius:4px; padding:6px 10px; font-size:10px; }}
QPushButton.copy:hover {{ color:#fff; }}
QPushButton.reveal {{ background:transparent; border:none; color:{BLUE}; font-size:10px; text-decoration:underline; padding:0; }}
#warn {{ color:{PINK}; font-size:10px; }}
#err  {{ color:{PINK}; font-size:11px; }}
#foot {{ color:rgba(255,255,255,80); font-size:10px; }}
QSlider::groove:horizontal {{ height:3px; border-radius:2px; background:rgba(255,255,255,20); }}
QSlider::sub-page:horizontal {{ height:3px; border-radius:2px; background:qlineargradient(x1:0,y1:0,x2:1,y2:0, stop:0 {BLUE}, stop:1 {YELLOWB}); }}
QSlider::handle:horizontal {{ width:15px; height:15px; margin:-7px 0; border-radius:8px; background:{YELLOW}; border:2px solid rgba(8,16,31,200); }}
QSlider::handle:horizontal:hover {{ background:{YELLOWB}; }}
QPushButton.win {{ background:transparent; border:none; color:rgba(255,255,255,120); font-size:15px; padding:0 6px; }}
QPushButton.win:hover {{ color:#fff; }}

/* ---- popups / menus / selection: force dark, on-theme (need app-level QSS) ---- */
QMenu {{ background:rgba(16,20,28,250); color:rgba(255,255,255,230); border:1px solid rgba(255,255,255,30);
        border-radius:8px; padding:6px; font-size:12px; }}
QMenu::item {{ background:transparent; padding:7px 22px 7px 14px; border-radius:5px; margin:1px 2px; }}
QMenu::item:selected {{ background:rgba(0,82,255,60); color:{BLUE}; }}
QMenu::item:disabled {{ color:rgba(255,255,255,70); }}
QMenu::separator {{ height:1px; background:rgba(255,255,255,22); margin:5px 8px; }}
QComboBox {{ background:rgba(255,255,255,8); color:rgba(255,255,255,200); border:1px solid rgba(255,255,255,28);
            border-radius:6px; padding:4px 10px; font-size:11px; }}
QComboBox:hover, QComboBox:focus {{ border:1px solid {BLUE}; }}
QComboBox::drop-down {{ subcontrol-origin:padding; subcontrol-position:center right; width:20px; border:none;
                       border-left:1px solid rgba(255,255,255,18); margin:2px; }}
QComboBox::down-arrow {{ width:0; height:0; border-left:4px solid transparent; border-right:4px solid transparent;
                        border-top:5px solid {BLUE}; margin-right:2px; }}
QComboBox::down-arrow:on {{ border-top:none; border-bottom:5px solid {BLUE}; }}
QComboBox QAbstractItemView {{ background:rgba(16,20,28,252); color:rgba(255,255,255,220);
            border:1px solid rgba(255,255,255,30); border-radius:8px; padding:4px; outline:none;
            selection-background-color:rgba(0,82,255,90); selection-color:#ffffff; }}
QComboBox QAbstractItemView::item {{ min-height:24px; padding:5px 12px; border-radius:5px; }}
QComboBox QAbstractItemView::item:selected, QComboBox QAbstractItemView::item:hover {{ background:rgba(0,82,255,70); color:#ffffff; }}
QLineEdit {{ selection-background-color:{BLUE}; selection-color:#08101f; }}
QToolTip {{ background:rgba(16,20,28,252); color:rgba(255,255,255,220); border:1px solid {BLUE};
           border-radius:6px; padding:5px 9px; font-size:11px; }}
QScrollBar:vertical {{ background:transparent; width:8px; margin:2px; }}
QScrollBar::handle:vertical {{ background:rgba(61,123,255,120); border-radius:4px; min-height:24px; }}
QScrollBar::handle:vertical:hover {{ background:{BLUE}; }}
QScrollBar:horizontal {{ background:transparent; height:8px; margin:2px; }}
QScrollBar::handle:horizontal {{ background:rgba(61,123,255,120); border-radius:4px; min-width:24px; }}
QScrollBar::handle:horizontal:hover {{ background:{BLUE}; }}
QScrollBar::add-line, QScrollBar::sub-line {{ width:0; height:0; background:none; border:none; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background:transparent; }}
"""

class App(QWidget):
    def __init__(self):
        super().__init__()
        self.proc = None
        self.live_rate = 0.0
        self.lang = "en"
        self._i18n = []          # list of (setter) closures for retranslation
        self._running = False; self._found = False
        self.setWindowFlags(Qt.FramelessWindowHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setFixedWidth(600)
        self._drag = None

        root = QVBoxLayout(self); root.setContentsMargins(18,18,18,18)
        card = QFrame(); card.setObjectName("card"); root.addWidget(card)
        sh = QGraphicsDropShadowEffect(blurRadius=48, xOffset=0, yOffset=18); sh.setColor(QColor(0,0,0,170))
        card.setGraphicsEffect(sh)
        c = QVBoxLayout(card); c.setContentsMargins(24,20,24,18); c.setSpacing(0)

        # ---- title bar: brand (blue+yellow) | lang switch | status | win btns ----
        top = QHBoxLayout()
        b1 = QLabel("Sally"); b1.setObjectName("brand2")
        b2 = QLabel("Vanity"); b2.setObjectName("brand")
        self.tag = QLabel("ETH · CUDA"); self.tag.setObjectName("tag")
        top.addWidget(b1); top.addSpacing(4); top.addWidget(b2); top.addSpacing(8); top.addWidget(self.tag); top.addStretch()
        self.langbox = QComboBox(); self.langbox.setProperty("class","langbox"); self.langbox.setCursor(Qt.PointingHandCursor)
        for code,label in LANGS: self.langbox.addItem(label, code)
        self.langbox.currentIndexChanged.connect(lambda i: self.set_lang(LANGS[i][0]))
        top.addWidget(self.langbox); top.addSpacing(8)
        self.dot = QLabel("●"); self.dot.setStyleSheet("color:rgba(255,255,255,70); font-size:11px")
        self.stext = QLabel(); self.stext.setObjectName("stext")
        self.runtime = QLabel(""); self.runtime.setObjectName("stext")
        top.addWidget(self.dot); top.addSpacing(5); top.addWidget(self.stext); top.addSpacing(6); top.addWidget(self.runtime); top.addSpacing(12)
        # top-right app logo
        self.logo = QLabel(); self.logo.setFixedSize(20,20)
        _lp = QPixmap(asset("icon-64.png"))
        if not _lp.isNull():
            self.logo.setPixmap(_lp.scaled(20,20,Qt.KeepAspectRatio,Qt.SmoothTransformation))
        top.addWidget(self.logo); top.addSpacing(12)
        mn = QPushButton("–"); mn.setProperty("class","win"); mn.clicked.connect(self.showMinimized)
        cl = QPushButton("✕"); cl.setProperty("class","win"); cl.clicked.connect(self.close)
        top.addWidget(mn); top.addWidget(cl)
        c.addLayout(top)
        self.sub = QLabel(); self.sub.setObjectName("sub"); c.addWidget(self.sub); c.addSpacing(16)
        self._reg(lambda: self.sub.setText(self.T("sub")))

        # ---- 01 pattern ----
        c.addWidget(self._seclabel("01","sec_pattern")); c.addSpacing(8)
        row = QHBoxLayout(); row.setSpacing(12)
        self.prefix, pwrap = self._input("0x", None, "dead")
        self.suffix, swrap = self._input(None, "…", "")
        for key, wrap in (("prefix", pwrap), ("suffix", swrap)):
            box = QVBoxLayout(); box.setSpacing(5)
            l = QLabel(); l.setProperty("class","small"); self._reg_lbl(l, key); box.addWidget(l); box.addWidget(wrap)
            row.addLayout(box)
        c.addLayout(row); c.addSpacing(16)

        # ---- 02 mode ----
        c.addWidget(self._seclabel("02","sec_mode")); c.addSpacing(8)
        self.src = self._segment(c, "source",  ["Raw Key","Seed 12","Seed 24"], 0, self._mode_changed)
        self.tgt = self._segment(c, "target",  ["Wallet","CREATE","CREATE2"], 0, self._mode_changed)
        self.bk  = self._segment(c, "backend", ["GPU","CPU","GPU+CPU"], 0, self._mode_changed)
        if not gpu_build_present():
            # No CUDA binary present (CPU-only download, or macOS — Apple has no CUDA).
            # Detected, not assumed: if a ./vanity GPU build ever appears, these light up.
            for _i in (0, 2):
                b = self.bk.button(_i)
                b.setEnabled(False); b.setChecked(False)
                b.setToolTip(self.T("no_gpu_build"))
            self.bk.button(1).setChecked(True)
        c.addSpacing(6)
        self.passphrase, self.pp_wrap_box = self._labeled_input("passphrase", "", False)
        self.nonce, self.nonce_box = self._labeled_input("nonce", "0", True)
        self.ncount, self.ncount_box = self._labeled_input("ncount", "1", True)
        self.salt, self.salt_box = self._labeled_input("salt", "", False)
        self.init, self.init_box = self._labeled_input("initcode", "", False)
        for box in (self.pp_wrap_box, self.nonce_box, self.ncount_box, self.salt_box, self.init_box):
            c.addLayout(box)
        c.addSpacing(10)

        # ---- 03 performance ----
        self.perf_label = self._seclabel("03","sec_perf"); c.addWidget(self.perf_label); c.addSpacing(8)
        srow = QHBoxLayout()
        self.slider = QSlider(Qt.Horizontal); self.slider.setRange(10,100); self.slider.setSingleStep(5); self.slider.setValue(90)
        self.slider.valueChanged.connect(self._recalc)
        self.utilv = QLabel(); self.utilv.setObjectName("diff"); self.utilv.setMinimumWidth(120); self.utilv.setAlignment(Qt.AlignRight)
        srow.addWidget(self.slider); srow.addWidget(self.utilv); c.addLayout(srow); c.addSpacing(8)
        self.hint = QLabel(); self.hint.setObjectName("hint"); self.hint.setWordWrap(True); c.addWidget(self.hint); c.addSpacing(16)
        self._reg(lambda: self.hint.setText(self.T("gpu_hint")))
        # ---- CPU threads (shown for CPU / Hybrid backends) ----
        self._cpus = max(1, os.cpu_count() or 1)
        self.cpu_label = QLabel(); self.cpu_label.setProperty("class","label"); self.cpu_label.setTextFormat(Qt.RichText)
        self._reg(lambda: self.cpu_label.setText(f"<span style='color:{YELLOW}'>⚙</span>  "+self.T("sec_cpu")))
        c.addWidget(self.cpu_label); c.addSpacing(8)
        crow = QHBoxLayout()
        self.cpu_slider = QSlider(Qt.Horizontal); self.cpu_slider.setRange(1,self._cpus); self.cpu_slider.setValue(self._cpus)
        self.cpu_slider.valueChanged.connect(self._recalc_cpu)
        self.cpu_val = QLabel(); self.cpu_val.setObjectName("diff"); self.cpu_val.setMinimumWidth(120); self.cpu_val.setAlignment(Qt.AlignRight)
        crow.addWidget(self.cpu_slider); crow.addWidget(self.cpu_val); c.addLayout(crow); c.addSpacing(16)
        self._reg(self._recalc_cpu)

        # ---- buttons ----
        brow = QHBoxLayout(); brow.setSpacing(12)
        self.start = QPushButton(); self.start.setProperty("class","go"); self.start.clicked.connect(self.on_start)
        self.stopb = QPushButton(); self.stopb.setProperty("class","stop"); self.stopb.setEnabled(False); self.stopb.clicked.connect(self.on_stop)
        self._reg(lambda: self.start.setText("▶  "+self.T("start")))
        self._reg(lambda: self.stopb.setText("■  "+self.T("stop")))
        brow.addWidget(self.start); brow.addWidget(self.stopb); c.addLayout(brow); c.addSpacing(8)
        # elevation button — hidden until a GPU-permission fallback is detected
        self.elevate = QPushButton(); self.elevate.setProperty("class","go"); self.elevate.setVisible(False)
        self.elevate.setCursor(Qt.PointingHandCursor); self.elevate.clicked.connect(lambda: self.on_start(elevated=True))
        self._reg(lambda: self.elevate.setText("⚡  "+ENABLE_GPU_TXT.get(self.lang, ENABLE_GPU_TXT["en"])))
        c.addWidget(self.elevate); c.addSpacing(16)

        # ---- stats ----
        grid = QGridLayout(); grid.setSpacing(10)
        self.s_rate  = self._stat(grid,0,"speed","— M/s")
        self.s_tried = self._stat(grid,1,"tried","— G")
        self.s_burst = self._stat(grid,2,"burst","— ms")
        self.s_eta   = self._stat(grid,3,"eta","—")
        c.addLayout(grid); c.addSpacing(12)
        self.diff = QLabel(); self.diff.setObjectName("diff"); self.diff.setTextFormat(Qt.RichText)
        c.addWidget(self.diff)

        # ---- result ----
        self.result = QFrame(); self.result.setObjectName("result"); self.result.setVisible(False)
        r = QVBoxLayout(self.result); r.setContentsMargins(16,14,16,14); r.setSpacing(6)
        self.res_k = QLabel(); self.res_k.setObjectName("rk"); self.res_k.setStyleSheet(f"color:{YELLOW}"); r.addWidget(self.res_k)
        self._reg(lambda: self.res_k.setText(self.T("res_found")))
        self.mne_k = QLabel(); self.mne_k.setObjectName("rk"); self.mne_k.setVisible(False); r.addWidget(self.mne_k)
        self._reg(lambda: self.mne_k.setText(self.T("res_mnemonic")))
        self.mne, mwrap = self._monoline("mne"); self.mne_wrap = mwrap; mwrap.setVisible(False); r.addWidget(mwrap)
        self.pass_k = QLabel(); self.pass_k.setObjectName("rk"); self.pass_k.setVisible(False); r.addWidget(self.pass_k)
        self._reg(lambda: self.pass_k.setText(self.T("res_passphrase")))
        self.passout, pwrap2 = self._monoline("mne"); self.pass_wrap = pwrap2; pwrap2.setVisible(False); r.addWidget(pwrap2)
        self.con_k = QLabel(); self.con_k.setObjectName("rk"); self.con_k.setVisible(False); r.addWidget(self.con_k)
        self._reg(lambda: self.con_k.setText(self.T("res_contract")))
        self.con, cwrap = self._monoline("con"); self.con_wrap = cwrap; cwrap.setVisible(False); r.addWidget(cwrap)
        self.addr_k = QLabel(); self.addr_k.setObjectName("rk"); r.addSpacing(2); r.addWidget(self.addr_k)
        self._reg(lambda: self.addr_k.setText(self.T("res_address")))
        self.addr, awrap = self._monoline("addr"); r.addWidget(awrap)
        kr = QHBoxLayout(); self.key_k = QLabel(); self.key_k.setObjectName("rk")
        self._reg(lambda: self.key_k.setText(self.T("res_privkey")))
        self.revealb = QPushButton(); self.revealb.setProperty("class","reveal"); self.revealb.clicked.connect(self._toggle_key)
        kr.addWidget(self.key_k); kr.addSpacing(8); kr.addWidget(self.revealb); kr.addStretch(); r.addSpacing(4); r.addLayout(kr)
        self.key, kwrap = self._monoline("key"); self.key.setEchoMode(QLineEdit.Password); r.addWidget(kwrap)
        self.warn = QLabel(); self.warn.setObjectName("warn"); self.warn.setWordWrap(True); r.addSpacing(4); r.addWidget(self.warn)
        self._reg(lambda: self.warn.setText(self.T("warn")))
        c.addSpacing(14); c.addWidget(self.result)

        self.err = QLabel(""); self.err.setObjectName("err"); self.err.setWordWrap(True); c.addSpacing(8); c.addWidget(self.err)
        # ---- footer: GPU/CPU temp (left) · sally.tools backlink (right) ----
        frow = QHBoxLayout(); frow.setContentsMargins(2,0,2,0)
        self.temp = QLabel("—"); self.temp.setObjectName("foot")
        self.foot = QLabel(); self.foot.setObjectName("foot"); self.foot.setTextFormat(Qt.RichText)
        self.foot.setOpenExternalLinks(True); self.foot.setAlignment(Qt.AlignRight)
        self._reg(lambda: self.foot.setText(
            self.T("foot") + f"  ·  <a href='https://sally.tools' style='color:{BLUE}; text-decoration:none'>sally.tools</a>"))
        frow.addWidget(self.temp); frow.addStretch(); frow.addWidget(self.foot)
        c.addSpacing(10); c.addLayout(frow)

        self.setStyleSheet(QSS)
        self.prefix.textChanged.connect(self._recalc); self.suffix.textChanged.connect(self._recalc)
        # live elapsed-time ticker (created BEFORE retranslate, which calls _set_running)
        self._t_start = 0.0
        self._run_timer = QTimer(self); self._run_timer.timeout.connect(self._tick_elapsed)
        self.retranslate(); self._mode_changed(); self._recalc()
        # live GPU/CPU temperature poller (non-blocking)
        self._tproc = None
        self._temp_timer = QTimer(self); self._temp_timer.timeout.connect(self._poll_temps)
        self._temp_timer.start(2000); self._poll_temps()

    # ---- i18n ----
    def T(self, key):
        return I18N.get(self.lang, I18N["en"]).get(key, I18N["en"].get(key, key))
    def _reg(self, fn): fn(); self._i18n.append(fn)
    def _reg_lbl(self, widget, key): self._reg(lambda: widget.setText(self.T(key)))
    def set_lang(self, code):
        self.lang = code; self.retranslate(); self.adjustSize()
    def retranslate(self):
        for fn in self._i18n: fn()
        self.revealb.setText(f"[{self.T('hide') if self.key.echoMode()==QLineEdit.Normal else self.T('show')}]")
        self._set_running(self._running, self._found); self._recalc()

    # ---- widget helpers ----
    def _seclabel(self, num, key):
        w = QLabel(); w.setProperty("class","label"); w.setTextFormat(Qt.RichText)
        self._reg(lambda: w.setText(f"<span style='color:{YELLOW}'>{num}</span>  {self.T(key)}"))
        return w
    def _input(self, pre, post, default):
        wrap = QFrame(); wrap.setProperty("class","input"); h = QHBoxLayout(wrap); h.setContentsMargins(11,0,11,0); h.setSpacing(4)
        if pre: h.addWidget(QLabel(pre))
        e = QLineEdit(default); e.setProperty("class","cell")
        e.setValidator(QRegularExpressionValidator(QRegularExpression("[0-9a-fA-F]*")))
        e.setMaxLength(40); h.addWidget(e)
        if post: h.addWidget(QLabel(post))
        return e, wrap
    def _labeled_input(self, key, default, numeric):
        box = QVBoxLayout(); box.setSpacing(4)
        l = QLabel(); l.setProperty("class","small"); l.setWordWrap(True); self._reg_lbl(l, key); box.addWidget(l)
        wrap = QFrame(); wrap.setProperty("class","input"); h = QHBoxLayout(wrap); h.setContentsMargins(11,0,11,0)
        e = QLineEdit(default); e.setProperty("class","cell")
        if numeric: e.setValidator(QIntValidator(0, 2000000000))
        h.addWidget(e); box.addWidget(wrap)
        return e, box
    def _segment(self, parent, capkey, items, default, cb):
        rowbox = QHBoxLayout(); rowbox.setSpacing(8)
        lab = QLabel(); lab.setProperty("class","small"); lab.setMinimumWidth(64); self._reg_lbl(lab, capkey)
        rowbox.addWidget(lab)
        grp = QButtonGroup(self); grp.setExclusive(True)
        for i, it in enumerate(items):
            b = QPushButton(it); b.setProperty("class","seg"); b.setCheckable(True); b.setCursor(Qt.PointingHandCursor)
            if i==default: b.setChecked(True)
            grp.addButton(b, i); rowbox.addWidget(b)
        grp.idClicked.connect(lambda _=0: cb())
        parent.addLayout(rowbox); parent.addSpacing(8)
        return grp
    def _stat(self, grid, col, key, v):
        f = QFrame(); f.setProperty("class","stat"); l = QVBoxLayout(f); l.setContentsMargins(12,10,12,10); l.setSpacing(3)
        kl = QLabel(); kl.setProperty("class","k"); vl = QLabel(v); vl.setProperty("class","v")
        self._reg_lbl(kl, key)
        l.addWidget(kl); l.addWidget(vl); grid.addWidget(f, 0, col); return vl
    def _monoline(self, kind):
        wrap = QFrame(); h = QHBoxLayout(wrap); h.setContentsMargins(0,0,0,0); h.setSpacing(8)
        e = QLineEdit(); e.setReadOnly(True); e.setProperty("class", "mono "+kind)
        cp = QPushButton("copy"); cp.setProperty("class","copy")
        cp.clicked.connect(lambda: (QGuiApplication.clipboard().setText(e.text()), cp.setText("✓")))
        h.addWidget(e); h.addWidget(cp); return e, wrap

    def _fmt(self, s):
        if not math.isfinite(s): return "∞"
        if s < 60:        return f"{round(s)}s"
        if s < 3600:      return f"{int(s//60)}m {round(s%60)}s"
        if s < 86400:     return f"{int(s//3600)}h {int((s%3600)//60)}m"
        if s < 31536000:  return f"{int(s//86400)}d {int((s%86400)//3600)}h"
        return f"{s/31536000:.1f} {self.T('years')}"

    # ---- window drag (frameless) ----
    def mousePressEvent(self, e):
        if e.position().y() < 60: self._drag = e.globalPosition().toPoint() - self.frameGeometry().topLeft()
    def mouseMoveEvent(self, e):
        if self._drag is not None and e.buttons() & Qt.LeftButton: self.move(e.globalPosition().toPoint() - self._drag)
    def mouseReleaseEvent(self, e): self._drag = None

    # ---- logic ----
    def _is_seed(self): return self.src.checkedId() in (1,2)
    def _rate_est(self):
        if self.live_rate > 0: return self.live_rate
        if self._is_seed(): return 0.10
        return BASE_RATE * (self.slider.value()/100.0 if self.bk.checkedId() in (0,2) else 0.01)
    def _recalc_cpu(self):
        self.cpu_val.setText(f"{self.T('cpu_threads')} <b>{self.cpu_slider.value()}</b> / {self._cpus}")
    def _mode_changed(self):
        seed = self._is_seed(); tgt = self.tgt.checkedId(); bkid = self.bk.checkedId()
        gpu = bkid in (0,2); cpu = bkid in (1,2)
        self.pp_wrap_box.itemAt(0).widget().setVisible(seed); self.passphrase.parentWidget().setVisible(seed)
        self.nonce_box.itemAt(0).widget().setVisible(tgt==1); self.nonce.parentWidget().setVisible(tgt==1)
        self.ncount_box.itemAt(0).widget().setVisible(tgt==1); self.ncount.parentWidget().setVisible(tgt==1)
        for box,w in ((self.salt_box,self.salt),(self.init_box,self.init)):
            box.itemAt(0).widget().setVisible(tgt==2); w.parentWidget().setVisible(tgt==2)
        self.perf_label.setVisible(gpu); self.slider.setVisible(gpu); self.utilv.setVisible(gpu); self.hint.setVisible(gpu)
        self.cpu_label.setVisible(cpu); self.cpu_slider.setVisible(cpu); self.cpu_val.setVisible(cpu)
        self.adjustSize(); self._recalc()
    def _recalc(self):
        self.utilv.setText(f"{self.T('gpu_max')} <b>{self.slider.value()}</b>%")
        n = len(self.prefix.text()) + len(self.suffix.text())
        if n == 0:
            self.diff.setText(f"{self.T('difficulty')} <b>—</b>     {self.T('avgtime')} <b>—</b>"); return
        t = (16.0**n) / (self._rate_est()*1e6)
        note = "  ·  "+self.T("seed_note") if self._is_seed() else ""
        self.diff.setText(f"{self.T('difficulty')} <b>16^{n}</b>     {self.T('avgtime')} <b>~{self._fmt(t)}</b>{note}")
    def _tick_elapsed(self):
        if self._t_start>0:
            el=int(time.monotonic()-self._t_start); self.runtime.setText(f"· {el//60}:{el%60:02d}")
    def _set_running(self, running, found=False):
        self._running = running; self._found = found
        self.start.setEnabled(not running); self.stopb.setEnabled(running)
        if found:   self.dot.setStyleSheet(f"color:{YELLOW}; font-size:11px"); self.stext.setText(self.T("st_found"))
        elif running: self.dot.setStyleSheet(f"color:{BLUE}; font-size:11px"); self.stext.setText(self.T("st_search"))
        else:       self.dot.setStyleSheet("color:rgba(255,255,255,70); font-size:11px"); self.stext.setText(self.T("st_idle"))
        if running: self._t_start=time.monotonic(); self.runtime.setText("· 0:00"); self._run_timer.start(1000)
        else: self._run_timer.stop()
    def _toggle_key(self):
        if self.key.echoMode() == QLineEdit.Password: self.key.setEchoMode(QLineEdit.Normal); self.revealb.setText(f"[{self.T('hide')}]")
        else: self.key.setEchoMode(QLineEdit.Password); self.revealb.setText(f"[{self.T('show')}]")

    # ---- GPU/CPU temperature (footer, non-blocking) ----
    def _poll_temps(self):
        cpu = None
        if psutil is not None:
            try:
                t = psutil.sensors_temperatures()
                for key in ("coretemp","k10temp","zenpower","cpu_thermal","acpitz"):
                    if t.get(key):
                        cpu = sum(s.current for s in t[key]) / len(t[key]); break
            except Exception: cpu = None
        self._cpu_temp = cpu
        if self._tproc is None and shutil.which("nvidia-smi"):
            p = QProcess(self); self._tproc = p
            p.finished.connect(lambda *a, pp=p: self._gpu_temp_done(pp))
            p.start("nvidia-smi", ["--query-gpu=temperature.gpu","--format=csv,noheader,nounits"])
        self._render_temp()
    def _gpu_temp_done(self, p):
        try:
            out = bytes(p.readAllStandardOutput()).decode(errors="ignore").strip().splitlines()
            self._gpu_temp = float(out[0]) if out and out[0].strip() else None
        except Exception: self._gpu_temp = None
        self._tproc = None; self._render_temp()
    def _render_temp(self):
        g = getattr(self,"_gpu_temp",None); c = getattr(self,"_cpu_temp",None)
        parts = []
        if g is not None: parts.append(f"GPU {g:.0f}°C")
        if c is not None: parts.append(f"CPU {c:.0f}°C")
        self.temp.setText("  ·  ".join(parts) if parts else "—")

    def _build_args(self):
        pre, suf = self.prefix.text().strip(), self.suffix.text().strip()
        if not pre and not suf: return None, self.T("err_pattern")
        bkid = self.bk.checkedId()                    # 0 GPU · 1 CPU · 2 GPU+CPU (hybrid)
        binp = BIN_GPU if bkid in (0,2) else BIN_CPU
        if not os.path.exists(binp):
            return None, self.T("err_binary").format(name=os.path.basename(binp))
        args = []
        mode = ["raw","seed12","seed24"][self.src.checkedId()]
        tgt  = ["eoa","create","create2"][self.tgt.checkedId()]
        args += ["--mode", mode, "--target", tgt]
        if bkid==2:   args += ["--hybrid", "--gpu-util", str(self.slider.value())]
        elif bkid==0: args += ["--gpu-util", str(self.slider.value())]
        else:         args += ["--cpu"]
        if bkid in (1,2) and self.cpu_slider.value() < self._cpus:
            args += ["--threads", str(self.cpu_slider.value())]
        if pre: args += ["--prefix", pre]
        if suf: args += ["--suffix", suf]
        if self._is_seed() and self.passphrase.text(): args += ["--passphrase", self.passphrase.text()]
        if tgt=="create":
            args += ["--nonce", self.nonce.text() or "0"]
            try: nc = int(self.ncount.text() or "1")
            except ValueError: nc = 1
            if nc > 1: args += ["--nonce-count", str(nc)]
        if tgt=="create2":
            if self.salt.text().strip(): args += ["--salt", self.salt.text().strip()]
            if self.init.text().strip(): args += ["--init", self.init.text().strip()]
        return (binp, args), None

    def on_start(self, elevated=False):
        self.err.setText(""); self.result.setVisible(False); self.elevate.setVisible(False)
        for w in (self.mne_wrap,self.mne_k,self.pass_wrap,self.pass_k,self.con_wrap,self.con_k):
            w.setVisible(False)                          # reset conditional result rows
        built, errmsg = self._build_args()
        if errmsg: self.err.setText(errmsg); return
        binp, args = built
        if elevated:
            program, arglist = elevate_cmd(binp, args)
            if program is None:
                self.err.setText("sudo " + " ".join([binp, *args])); return
        else:
            program, arglist = binp, args
        self.buf = ""
        self.proc = QProcess(self); self.proc.setProcessChannelMode(QProcess.MergedChannels)
        self.proc.setWorkingDirectory(ROOT)              # pkexec resets cwd
        self.proc.readyReadStandardOutput.connect(self._read)
        self.proc.finished.connect(self._finished)
        self.proc.start(program, arglist)
        self.live_rate = 0.0
        self._set_running(True)

    def on_stop(self):
        if self.proc: self.proc.terminate()
    def _finished(self, *a):
        self._set_running(False, found=self.result.isVisible())
    def _read(self):
        self.buf += bytes(self.proc.readAllStandardOutput()).decode(errors="ignore")
        parts = re.split(r"[\r\n]", self.buf); self.buf = parts.pop()
        for line in parts:
            if not line: continue
            m = PROG.search(line)
            if m:
                self.live_rate = float(m.group(3))
                self.s_tried.setText(f"{float(m.group(1)):.3f} G")
                self.s_rate.setText(f"{float(m.group(3)):.3f} M/s" if self._is_seed() else f"{float(m.group(3)):.0f} M/s")
                b = BURST.search(line); self.s_burst.setText(f"{float(b.group(1)):.0f} ms" if b else "—")
                self.s_eta.setText(self._fmt(float(m.group(4)))); self._recalc()
            if "[gpu-fallback]" in line and sys.platform != "darwin":
                self.elevate.setVisible(True); self.adjustSize()
            mn = MNE.search(line)
            if mn:
                self.mne.setText(mn.group(1).strip()); self.mne_wrap.setVisible(True); self.mne_k.setVisible(True)
            pw = PASS.search(line)
            if pw:
                self.passout.setText(pw.group(1).strip()); self.pass_wrap.setVisible(True); self.pass_k.setVisible(True)
            con = CON.search(line)
            if con:
                self.con.setText("0x"+con.group(1)); self.con_wrap.setVisible(True); self.con_k.setVisible(True)
            a = ADDR.search(line)
            if a: self.addr.setText("0x"+a.group(1))
            kk = KEY.search(line)
            if kk:
                self.key.setText("0x"+kk.group(1)); self.result.setVisible(True)
                self.s_eta.setText("0s"); self._set_running(False, found=True); self.adjustSize()
            if ("unsupported display driver" in line) or ("CUDA " in line and "error" in line.lower()) or line.startswith("error:"):
                self.err.setText(line.strip())

def app_icon():
    ic = QIcon()
    ico = asset("icon.ico")
    if os.path.exists(ico): ic.addFile(ico)
    for s in (16,24,32,48,64,128,256,512):
        p = asset(f"icon-{s}.png")
        if os.path.exists(p): ic.addFile(p, QSize(s,s))
    if ic.isNull():
        p = asset("icon.png")
        if os.path.exists(p): ic.addFile(p)
    return ic

if __name__ == "__main__":
    if sys.platform == "win32":
        try:
            import ctypes; ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("Sally.Vanity.ETH.1")
        except Exception: pass
    app = QApplication(sys.argv)
    app.setFont(QFont("JetBrains Mono", 10))
    app.setStyleSheet(QSS)          # reaches QMenu/QComboBox-popup/QToolTip top-level windows
    icon = app_icon()
    app.setWindowIcon(icon)
    w = App(); w.setWindowIcon(icon); w.show()
    sys.exit(app.exec())
