#!/usr/bin/env bash
# =============================================================================
# build-claude-desktop.sh
# Costruisce un pacchetto .deb di Claude Desktop per ZorinOS / Ubuntu / Mint
# senza dipendere da repository di terze parti.
#
# Cosa fa:
#   1. Scarica il programma di installazione Windows UFFICIALE da downloads.claude.ai
#   2. Estrae l'app Electron (app.asar) dall'installer
#   3. Sostituisce il modulo nativo Windows (claude-native) con uno stub JS
#      scritto da zero e completamente leggibile
#   4. Aggiunge due piccoli wrapper per far funzionare le decorazioni finestra
#   5. Confeziona il tutto in un .deb installabile con dpkg
#
# Dipendenze richieste (installate automaticamente dallo script):
#   p7zip-full, wget, icoutils, imagemagick, npm, nodejs
#   @electron/asar  (installato localmente via npm, non globalmente)
#
# Fonti usate:
#   - Installer ufficiale:  https://downloads.claude.ai  (Anthropic)
#   - Electron:             https://npmjs.com            (pacchetto ufficiale)
#   - Nessun altro repo di terze parti
#
# Uso:
#   chmod +x build-claude-desktop.sh
#   ./build-claude-desktop.sh
#
# Output:
#   ./claude-desktop_<versione>_amd64.deb
# =============================================================================

set -u          # errore su variabili non definite
set -o pipefail # errore se un comando in una pipe fallisce
# NON usiamo set -e per gestire gli errori esplicitamente con messaggi chiari

# ── Colori per output leggibile ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERRORE]${NC} $*" >&2; exit 1; }

# ── Sorgenti ufficiali Anthropic ─────────────────────────────────────────────
# Il file RELEASES (formato Squirrel) elenca tutte le versioni pubblicate.
# Da ogni riga ricaviamo il nome del .nupkg che scarichiamo direttamente
# (il .nupkg contiene già app.asar e risorse; saltiamo l'estrazione dell'.exe).
# URL pattern: https://downloads.claude.ai/releases/win32/x64/<nupkg-name>
RELEASES_URL="https://downloads.claude.ai/releases/win32/x64/RELEASES"
NUPKG_BASE_URL="https://downloads.claude.ai/releases/win32/x64"

# Versione del pacchetto .deb che creiamo (aggiornala se vuoi distinguere le build)
DEB_VERSION="1.0.0"
PACKAGE_NAME="claude-desktop"
ARCH="amd64"

# ── Directory di lavoro e cache permanente ───────────────────────────────────
# La cache (claude-build-cache/) persiste tra le esecuzioni e contiene:
#   - AnthropicClaude-full.nupkg  (il pacchetto NuGet scaricato)
#   - cached-version.txt          (la versione del nupkg in cache)
# Il workdir temporaneo (claude-build-tmp/) viene sempre ricreato.
WORKDIR="$(pwd)/claude-build-tmp"
CACHEDIR="$(pwd)/claude-build-cache"
DEBROOT="${WORKDIR}/debroot"

# =============================================================================
# STEP 0 — Pulizia workdir (la cache NON viene toccata)
# =============================================================================
info "Pulizia directory di lavoro..."
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
mkdir -p "${CACHEDIR}"
cd "${WORKDIR}" || die "Impossibile entrare in ${WORKDIR}"

# =============================================================================
# STEP 1 — Verifica e installazione dipendenze di sistema
# =============================================================================
info "Verifica dipendenze di sistema..."

MISSING_PKGS=()
for pkg in p7zip-full wget icoutils imagemagick nodejs npm; do
    if ! dpkg -s "${pkg}" &>/dev/null; then
        MISSING_PKGS+=("${pkg}")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    info "Installazione pacchetti mancanti: ${MISSING_PKGS[*]}"
    sudo apt-get update -qq || die "apt-get update fallito"
    sudo apt-get install -y "${MISSING_PKGS[@]}" || die "Installazione dipendenze fallita"
fi
ok "Tutte le dipendenze di sistema presenti"

# Installa @electron/asar localmente (non globalmente, per non sporcare il sistema)
info "Installazione @electron/asar locale..."
npm install --prefix "${WORKDIR}/npm-tools" @electron/asar 2>/dev/null \
    || die "Installazione @electron/asar fallita"
ASAR="${WORKDIR}/npm-tools/node_modules/.bin/asar"
[[ -x "${ASAR}" ]] || die "asar non trovato dopo installazione npm"
ok "@electron/asar installato in ${WORKDIR}/npm-tools"

# =============================================================================
# STEP 2 — Download dell'installer Windows ufficiale da Anthropic
# =============================================================================
# Rileva l'ultima versione pubblicata leggendo il file RELEASES di Squirrel.
# Formato riga: "SHA1  AnthropicClaude-VERSION-full.nupkg  size"
# Dalla riga con "-full.nupkg" più recente estraiamo nome e versione.
# Scarichiamo direttamente il .nupkg (no estrazione .exe intermedia).
info "Ricerca ultima versione Claude Desktop da RELEASES..."
CLAUDE_DOWNLOAD_URL=""
LATEST_VERSION=""
LATEST_NUPKG_NAME=""

LATEST_LINE=$(curl -sL --max-time 30 "${RELEASES_URL}" 2>/dev/null \
    | grep -i "\-full\.nupkg" | tail -1 | tr -d '\r')

if [[ -n "${LATEST_LINE}" ]]; then
    LATEST_NUPKG_NAME=$(echo "${LATEST_LINE}" | awk '{print $2}')
    LATEST_VERSION=$(echo "${LATEST_NUPKG_NAME}" \
        | grep -oP '\d+\.\d+\.\d+(?=-full)')

    if [[ -n "${LATEST_VERSION}" && -n "${LATEST_NUPKG_NAME}" ]]; then
        # URL diretto del nupkg: contiene già app.asar e resources
        CANDIDATE="${NUPKG_BASE_URL}/${LATEST_NUPKG_NAME}"
        HTTP_CODE=$(curl -sI --max-time 15 "${CANDIDATE}" 2>/dev/null \
            | grep -i "^http/" | tail -1 | awk '{print $2}')
        if [[ "${HTTP_CODE}" == "200" ]]; then
            CLAUDE_DOWNLOAD_URL="${CANDIDATE}"
            ok "Ultima versione rilevata: ${LATEST_VERSION}"
            ok "URL: ${CLAUDE_DOWNLOAD_URL}"
        fi
    fi
fi

if [[ -z "${CLAUDE_DOWNLOAD_URL}" ]]; then
    die "Rilevamento ultima versione fallito. Verifica connessione a downloads.claude.ai"
fi

# ── Download intelligente: scarica il .nupkg solo se la versione è cambiata ──
CACHED_NUPKG="${CACHEDIR}/AnthropicClaude-full.nupkg"
CACHED_VERSION_FILE="${CACHEDIR}/cached-version.txt"
CACHED_VERSION=""
[[ -f "${CACHED_VERSION_FILE}" ]] && \
    CACHED_VERSION=$(cat "${CACHED_VERSION_FILE}" | tr -d '\r\n ')

if [[ -f "${CACHED_NUPKG}" && -n "${CACHED_VERSION}" && \
      "${CACHED_VERSION}" == "${LATEST_VERSION}" ]]; then
    ok "Cache aggiornata: versione ${CACHED_VERSION} già scaricata, skip download"
    cp "${CACHED_NUPKG}" "${WORKDIR}/AnthropicClaude-full.nupkg"
else
    if [[ -n "${CACHED_VERSION}" && "${CACHED_VERSION}" != "${LATEST_VERSION}" ]]; then
        info "Nuova versione disponibile: ${CACHED_VERSION} → ${LATEST_VERSION}"
    fi
    info "Download pacchetto NuGet da downloads.claude.ai (Anthropic)..."
    info "URL: ${CLAUDE_DOWNLOAD_URL}"

    curl -L --progress-bar \
        -o "${WORKDIR}/AnthropicClaude-full.nupkg" \
        "${CLAUDE_DOWNLOAD_URL}" \
        || die "Download fallito. Controlla la connessione internet."

    NUPKG_SIZE=$(stat -c%s "${WORKDIR}/AnthropicClaude-full.nupkg")
    [[ "${NUPKG_SIZE}" -gt 10000000 ]] \
        || die "File scaricato troppo piccolo (${NUPKG_SIZE} bytes). Download fallito."

    # Verifica che sia uno zip valido (magic PK\x03\x04 = 504b0304)
    NUPKG_MAGIC=$(head -c 4 "${WORKDIR}/AnthropicClaude-full.nupkg" \
        | od -A n -t x1 | tr -d ' \n')
    [[ "${NUPKG_MAGIC}" == "504b0304" ]] \
        || die "Il file scaricato non è un NuGet package valido (magic: ${NUPKG_MAGIC})."

    ok "Download completato ($(( NUPKG_SIZE / 1024 / 1024 )) MB)"

    cp "${WORKDIR}/AnthropicClaude-full.nupkg" "${CACHED_NUPKG}"
    printf '%s\n' "${LATEST_VERSION}" > "${CACHED_VERSION_FILE}"
    ok "Versione ${LATEST_VERSION} salvata in cache"
fi

# La versione del .deb = versione Claude Desktop rilevata
DEB_VERSION="${LATEST_VERSION}"
CLAUDE_VERSION="${LATEST_VERSION}"

# =============================================================================
# STEP 3 — Estrazione del .nupkg (è un archivio zip, saltiamo l'estrazione .exe)
# =============================================================================
info "Estrazione del pacchetto NuGet..."
mkdir -p "${WORKDIR}/nupkg-contents"
7z x -y "${WORKDIR}/AnthropicClaude-full.nupkg" \
    -o"${WORKDIR}/nupkg-contents" \
    >/dev/null 2>&1 \
    || die "Estrazione .nupkg fallita"
ok "Pacchetto NuGet estratto (versione ${CLAUDE_VERSION})"

# =============================================================================
# STEP 4 — Copia di app.asar e risorse
# =============================================================================
info "Ricerca di app.asar..."
APP_ASAR=$(find "${WORKDIR}/nupkg-contents" -name "app.asar" | head -1)
[[ -n "${APP_ASAR}" ]] || die "app.asar non trovato"
APP_ASAR_UNPACKED=$(find "${WORKDIR}/nupkg-contents" -name "app.asar.unpacked" -type d | head -1)

cp "${APP_ASAR}" "${WORKDIR}/app.asar"
if [[ -n "${APP_ASAR_UNPACKED}" ]]; then
    cp -r "${APP_ASAR_UNPACKED}" "${WORKDIR}/app.asar.unpacked"
fi

# Copia i file resources/ (i18n, icone tray, ecc.) che stanno fuori dall'asar
# L'app li cerca come resources/ relativo alla directory dell'asar
APP_RESOURCES_DIR=$(dirname "${APP_ASAR}")/resources
if [[ -d "${APP_RESOURCES_DIR}" ]]; then
    cp -r "${APP_RESOURCES_DIR}" "${WORKDIR}/resources"
    info "Directory resources/ copiata ($(find "${WORKDIR}/resources" -type f | wc -l) file)"
else
    # Cerca i file i18n ovunque nel nupkg
    info "resources/ non trovata come directory, ricerca i18n nel nupkg..."
    mkdir -p "${WORKDIR}/resources/i18n"
    find "${WORKDIR}/nupkg-contents" -name "*.json"         | grep -v "node_modules" | grep -v "package.json"         | while read -r f; do
        cp "${f}" "${WORKDIR}/resources/i18n/" 2>/dev/null || true
    done
    N_I18N=$(find "${WORKDIR}/resources/i18n" -name "*.json" | wc -l)
    info "Trovati ${N_I18N} file json i18n"
fi
ok "app.asar e resources copiati"

# =============================================================================
# STEP 5 — Estrazione delle icone
# =============================================================================
info "Estrazione icone..."
mkdir -p "${WORKDIR}/icons"

# Cerca file .exe nel nupkg (contiene l'app Windows come binario per estrarre icone)
ICO_FILE=$(find "${WORKDIR}/nupkg-contents" \
    -name "*.exe" | head -1)

if [[ -n "${ICO_FILE}" ]]; then
    # Estrai icone con wrestool + icotool
    wrestool -x --output="${WORKDIR}/icons" "${ICO_FILE}" 2>/dev/null || true
    find "${WORKDIR}/icons" -name "*.ico" | while read -r ico; do
        icotool -x -o "${WORKDIR}/icons" "${ico}" 2>/dev/null || true
    done
fi

# Se non ha trovato icone .ico, crea una icona placeholder semplice
PNG_ICONS=$(find "${WORKDIR}/icons" -name "*.png" | wc -l)
if [[ "${PNG_ICONS}" -eq 0 ]]; then
    warn "Nessuna icona estratta; creo placeholder..."
    for size in 16 24 32 48 64 128 256; do
        convert -size "${size}x${size}" xc:"#cc785c" \
            -fill white -gravity Center \
            -font DejaVu-Sans-Bold -pointsize "$(( size / 2 ))" \
            -annotate 0 "C" \
            "${WORKDIR}/icons/claude_${size}.png" 2>/dev/null || true
    done
fi
ok "Icone pronte"

# =============================================================================
# STEP 6 — Modifica di app.asar: sostituzione del modulo nativo Windows
# =============================================================================
# Il modulo @ant/claude-native (o claude-native) è una libreria nativa compilata
# per Windows. Su Linux non può girare. La sostituiamo con uno stub JavaScript
# puro che espone la stessa interfaccia ma con implementazioni no-op o Linux-native.
#
# Questo stub è scritto qui sotto, completamente trasparente e ispezionabile.
# Non fa nulla di nascosto: ritorna valori neutri o stub per ogni funzione.

info "Spacchettamento app.asar..."
mkdir -p "${WORKDIR}/app-extracted"
"${ASAR}" extract "${WORKDIR}/app.asar" "${WORKDIR}/app-extracted" \
    || die "Estrazione app.asar fallita"
ok "app.asar estratto"

# Copia i file resources/i18n DENTRO app-extracted/ in modo che finiscano
# dentro l'asar riconfezionato. L'app usa readFileSync relativo all'asar:
#   resources/i18n/en-US.json  →  deve stare in app-extracted/resources/i18n/
info "Copia file i18n dentro app-extracted..."
mkdir -p "${WORKDIR}/app-extracted/resources/i18n"

# Cerca i file json di localizzazione nel nupkg (es. en-US.json, it-IT.json...)
I18N_FOUND=0
# Prima prova: directory resources/ accanto all'app.asar originale
APP_ASAR_DIR=$(dirname "${WORKDIR}/app.asar")
if [[ -d "${APP_ASAR_DIR}/resources/i18n" ]]; then
    cp "${APP_ASAR_DIR}/resources/i18n"/*.json         "${WORKDIR}/app-extracted/resources/i18n/" 2>/dev/null && I18N_FOUND=1
fi

# Seconda prova: cerca nel nupkg estratto
if [[ "${I18N_FOUND}" -eq 0 ]]; then
    find "${WORKDIR}/nupkg-contents" -name "en-US.json" | head -1 | while read -r f; do
        I18N_DIR=$(dirname "${f}")
        cp "${I18N_DIR}"/*.json             "${WORKDIR}/app-extracted/resources/i18n/" 2>/dev/null || true
    done
    [[ $(find "${WORKDIR}/app-extracted/resources/i18n" -name "*.json" | wc -l) -gt 0 ]] \
        && I18N_FOUND=1
fi

# Terza prova: cerca ovunque nel nupkg file che assomigliano a localizzazioni
if [[ "${I18N_FOUND}" -eq 0 ]]; then
    find "${WORKDIR}/nupkg-contents" -name "*-*.json"         ! -path "*/node_modules/*" ! -name "package*.json"         | while read -r f; do
        cp "${f}" "${WORKDIR}/app-extracted/resources/i18n/" 2>/dev/null || true
    done
fi

N_I18N=$(find "${WORKDIR}/app-extracted/resources/i18n" -name "*.json" | wc -l)
if [[ "${N_I18N}" -gt 0 ]]; then
    ok "Copiati ${N_I18N} file i18n dentro app.asar"
else
    warn "Nessun file i18n trovato nel nupkg — creo en-US.json minimale"
    # Crea un file minimale per non bloccare l'avvio
    echo '{}' > "${WORKDIR}/app-extracted/resources/i18n/en-US.json"
fi

# ── Scrivi lo stub claude-native ──────────────────────────────────────────────
info "Scrittura stub claude-native per Linux..."

# Trova la directory del modulo nativo
NATIVE_MOD_DIR=$(find "${WORKDIR}/app-extracted" \
    -type d \( -name "claude-native" -o -name "@ant" \) | head -1)

if [[ -z "${NATIVE_MOD_DIR}" ]]; then
    # Crea la directory se non esiste
    NATIVE_MOD_DIR="${WORKDIR}/app-extracted/node_modules/@ant/claude-native"
    mkdir -p "${NATIVE_MOD_DIR}"
fi

# Se è la dir @ant, entra in claude-native
if [[ "$(basename "${NATIVE_MOD_DIR}")" == "@ant" ]]; then
    NATIVE_MOD_DIR="${NATIVE_MOD_DIR}/claude-native"
    mkdir -p "${NATIVE_MOD_DIR}"
fi

# Scrivi il package.json dello stub
cat > "${NATIVE_MOD_DIR}/package.json" << 'PKGJSON'
{
  "name": "@ant/claude-native",
  "version": "1.0.0",
  "description": "Linux stub for claude-native Windows module",
  "main": "index.js"
}
PKGJSON

# ── Lo stub vero e proprio ────────────────────────────────────────────────────
# Ogni funzione è documentata con cosa fa l'originale Windows e cosa fa lo stub.
cat > "${NATIVE_MOD_DIR}/index.js" << 'STUBJS'
/**
 * claude-native Linux stub
 *
 * Questo file sostituisce il modulo nativo Windows @ant/claude-native.
 * L'originale è una libreria .node compilata per Windows che fornisce:
 *   - Informazioni su monitor e finestre
 *   - Controllo mouse/tastiera a basso livello
 *   - Notifiche di sistema
 *   - KeyboardKey enum
 *
 * Questo stub:
 *   - Espone la stessa interfaccia JavaScript
 *   - Non fa nulla di nascosto
 *   - Ritorna valori neutri/sicuri
 *   - Mantiene KeyboardKey perché usato dall'app per i binding
 */

'use strict';

// KeyboardKey enum — usato dall'app per i keyboard shortcut binding.
// Valori identici all'originale Windows per compatibilità.
const KeyboardKey = {
  A: 0, B: 1, C: 2, D: 3, E: 4, F: 5, G: 6, H: 7, I: 8, J: 9,
  K: 10, L: 11, M: 12, N: 13, O: 14, P: 15, Q: 16, R: 17, S: 18,
  T: 19, U: 20, V: 21, W: 22, X: 23, Y: 24, Z: 25,
  N0: 26, N1: 27, N2: 28, N3: 29, N4: 30, N5: 31, N6: 32, N7: 33,
  N8: 34, N9: 35,
  F1: 36, F2: 37, F3: 38, F4: 39, F5: 40, F6: 41, F7: 42, F8: 43,
  F9: 44, F10: 45, F11: 46, F12: 47,
  Space: 48, Enter: 49, Tab: 50, Backspace: 51, Delete: 52,
  Escape: 53, Home: 54, End: 55, PageUp: 56, PageDown: 57,
  ArrowLeft: 58, ArrowRight: 59, ArrowUp: 60, ArrowDown: 61,
  Shift: 62, Control: 63, Alt: 64, Meta: 65,
};

// getWindowsWithSameApp — originale: lista finestre della stessa app (Win32 API)
// stub: ritorna array vuoto (nessuna finestra da aggregare)
function getWindowsWithSameApp() {
  return [];
}

// getMonitorList — originale: lista monitor con posizione e DPI (Win32 API)
// stub: ritorna array vuoto
function getMonitorList() {
  return [];
}

// getMouseLocation — originale: posizione corrente del cursore (Win32 API)
// stub: ritorna {x:0, y:0}
function getMouseLocation() {
  return { x: 0, y: 0 };
}

// getTotalMemory — originale: RAM totale in bytes (Win32 API)
// stub: ritorna un valore fisso (4 GB)
function getTotalMemory() {
  return 4 * 1024 * 1024 * 1024;
}

// getWindowTitle — originale: titolo della finestra in foreground (Win32 API)
// stub: ritorna stringa vuota
function getWindowTitle() {
  return '';
}

// moveMouseTo — originale: sposta il cursore (Win32 SendInput)
// stub: no-op
function moveMouseTo(_x, _y) {
  // no-op su Linux (Computer Use usa xdotool)
}

// simulateKey — originale: simula pressione tasto (Win32 SendInput)
// stub: no-op
function simulateKey(_key, _down) {
  // no-op su Linux
}

// screenCapture — originale: cattura screenshot (Win32 GDI)
// stub: ritorna null (l'app gestisce il caso null)
function screenCapture() {
  return null;
}

// setGlobalShortcut — originale: registra shortcut globali (Win32)
// stub: no-op, ritorna true (successo finto)
function setGlobalShortcut(_keys, _callback) {
  return true;
}

// unsetGlobalShortcut — originale: rimuove shortcut globali
// stub: no-op
function unsetGlobalShortcut(_keys) {}

// getSystemTheme — originale: tema sistema chiaro/scuro (Win32 registry)
// stub: ritorna 'dark' come default
function getSystemTheme() {
  return 'dark';
}

// onWindowFocusChanged — originale: callback cambio focus finestra
// stub: no-op
function onWindowFocusChanged(_callback) {}

// getResourcesPath — originale: path delle risorse dell'app
// stub: ritorna /usr/lib/claude-desktop dove stanno le risorse
function getResourcesPath() {
  return '/usr/lib/claude-desktop';
}

// AuthRequest — originale: oggetto per autenticazione nativa (ASWebAuthenticationSession su macOS)
// Su Linux non esiste auth nativa: isAvailable() ritorna false così
// l'app ricade sul flusso OAuth standard via browser (che funziona su Linux)
const AuthRequest = {
  isAvailable: function() { return false; },
  start: function(_url, _callback) {
    if (typeof _callback === 'function') {
      _callback(null, new Error('AuthRequest not available on Linux'));
    }
  },
  cancel: function() {},
};

module.exports = {
  KeyboardKey,
  AuthRequest,
  getWindowsWithSameApp,
  getMonitorList,
  getMouseLocation,
  getTotalMemory,
  getWindowTitle,
  moveMouseTo,
  simulateKey,
  screenCapture,
  setGlobalShortcut,
  unsetGlobalShortcut,
  getSystemTheme,
  onWindowFocusChanged,
  getResourcesPath,
};
STUBJS

ok "Stub claude-native scritto in ${NATIVE_MOD_DIR}/index.js"

# Rimuovi il .node binario Windows se presente (non serve e non gira su Linux)
find "${WORKDIR}/app-extracted" -name "*.node" \
    -path "*/claude-native*" -delete 2>/dev/null || true
find "${WORKDIR}/app.asar.unpacked" -name "*.node" \
    -path "*/claude-native*" -delete 2>/dev/null || true

# =============================================================================
# STEP 7 — Wrapper per decorazioni finestra (frame fix)
# =============================================================================
# Su Linux, Electron di default apre finestre senza frame (bordi nativi).
# Questo wrapper intercetta require('electron') e forza frame:true.

info "Scrittura frame-fix-wrapper.js..."
cat > "${WORKDIR}/app-extracted/frame-fix-wrapper.js" << 'FRAMEWRAP'
/**
 * frame-fix-wrapper.js
 * Forza title bar nativa e menu bar visibili su Linux.
 *
 * Strategia multi-livello perché l'app upstream usa BaseWindow o simili:
 *  1. Patch costruttori BrowserWindow E BaseWindow via Proxy su require('electron')
 *  2. Listener app.on('browser-window-created') per finestre classiche
 *  3. Polling delle finestre esistenti per forzare menu bar visibility
 *
 * Log con prefisso [frame-fix] per debug da terminale.
 */
'use strict';

const Module = require('module');
const originalLoad = Module._load;

function applyVisibilityFixes(win, source) {
  if (!win) return;
  try {
    if (typeof win.setMenuBarVisibility === 'function') {
      win.setMenuBarVisibility(true);
    }
    if (typeof win.setAutoHideMenuBar === 'function') {
      win.setAutoHideMenuBar(false);
    }
    console.log('[frame-fix] fixes applicati a finestra via', source || '?',
      '- title:', win.getTitle ? win.getTitle() : '(n/a)');
  } catch (e) {
    console.log('[frame-fix] errore applyVisibilityFixes:', e.message);
  }
}

// Patcha una classe Window (BrowserWindow, BaseWindow) per forzare frame:true
function patchWindowClass(OriginalClass, className) {
  class PatchedWindow extends OriginalClass {
    constructor(opts = {}) {
      opts = Object.assign({}, opts, {
        frame: true,
        titleBarStyle: 'default',
        autoHideMenuBar: false,
      });
      // Rimuovi proprietà che potrebbero forzare frameless
      delete opts.titleBarOverlay;
      super(opts);
      applyVisibilityFixes(this, 'constructor:' + className);
    }
  }
  Object.assign(PatchedWindow, OriginalClass);
  console.log('[frame-fix] classe', className, 'patchata');
  return PatchedWindow;
}

Module._load = function(request, parent, isMain) {
  const result = originalLoad.apply(this, arguments);

  if (request === 'electron' && result) {
    // L'oggetto esportato da 'electron' ha proprietà non-configurable
    // (BrowserWindow, BaseWindow). Non possiamo ridefinirle con defineProperty
    // sull'oggetto originale. Soluzione: wrappiamo con un Proxy che restituisce
    // versioni patchate per le classi window e passa tutto il resto invariato.
    const patchCache = {};

    const patchedResult = new Proxy(result, {
      get(target, prop, receiver) {
        const original = Reflect.get(target, prop, receiver);

        // Classi finestra da patchare
        if (prop === 'BrowserWindow' || prop === 'BaseWindow') {
          if (!patchCache[prop] && typeof original === 'function') {
            patchCache[prop] = patchWindowClass(original, prop);
          }
          return patchCache[prop] || original;
        }

        return original;
      }
    });

    // Aggancia listener globali sull'oggetto originale (non sul proxy)
    if (result.app && typeof result.app.on === 'function') {
      result.app.on('browser-window-created', (event, win) => {
        applyVisibilityFixes(win, 'event:browser-window-created');
        win.on('show', () => applyVisibilityFixes(win, 'event:show'));
        win.on('ready-to-show', () => applyVisibilityFixes(win, 'event:ready-to-show'));
      });
      console.log('[frame-fix] listener browser-window-created agganciato');

      // Polling: ogni 2 secondi controlla tutte le finestre esistenti e
      // forza menu bar visibility. Dopo 30 secondi si ferma.
      let pollCount = 0;
      const pollInterval = setInterval(() => {
        try {
          const BW = result.BaseWindow || result.BrowserWindow;
          if (BW && typeof BW.getAllWindows === 'function') {
            const wins = BW.getAllWindows();
            wins.forEach((w) => applyVisibilityFixes(w, 'poll#' + pollCount));
          }
        } catch (e) {
          console.log('[frame-fix] polling error:', e.message);
        }
        if (++pollCount >= 15) clearInterval(pollInterval);
      }, 2000);
    }

    return patchedResult;
  }
  return result;
};

console.log('[frame-fix] wrapper caricato');
FRAMEWRAP

info "Scrittura frame-fix-entry.js..."
cat > "${WORKDIR}/app-extracted/frame-fix-entry.js" << 'FRAMEENTRY'
/**
 * frame-fix-entry.js
 * Entry point che carica:
 *   1. Il wrapper frame-fix (decorazioni finestra Linux)
 *   2. L'update checker (polling orario per notifiche di aggiornamento)
 *   3. L'app principale
 * Referenziato in package.json come campo "main".
 */
'use strict';
require('./frame-fix-wrapper');
// Avvia l'update checker in background; se fallisce il caricamento
// non blocchiamo l'avvio dell'app principale.
try {
    require('./update-checker');
} catch (e) {
    console.error('[update-checker] Errore caricamento:', e.message);
}
require('./.vite/build/index.js');
FRAMEENTRY

info "Scrittura update-checker.js (polling aggiornamenti in-app)..."
cat > "${WORKDIR}/app-extracted/update-checker.js" << 'UPDATER_JS'
/**
 * update-checker.js
 * Polling orario dell'endpoint RELEASES di Anthropic per rilevare
 * nuove versioni. Vive dentro il processo Electron principale:
 * parte quando l'app si avvia, muore quando l'app si chiude.
 *
 * Non usa systemd, non richiede privilegi, non modifica il sistema.
 *
 * Flusso:
 *   1. Ogni ora (+ un primo check 2 min dopo l'avvio) legge RELEASES
 *   2. Se la versione remota > versione locale → Notification Electron
 *      con click handler che apre un dialog nativo
 *   3. Click su "Aggiorna ora" → spawn di /usr/bin/claude-update --upgrade
 *   4. Se endpoint rotto o formato cambiato → notifica di errore
 *      con opzione di apertura diagnostica (claude-update --diagnose)
 */
'use strict';

const { app, Notification, dialog, shell, Menu, Tray, BrowserWindow } = require('electron');
const { spawn } = require('child_process');
const https = require('https');
const fs = require('fs');
const path = require('path');

const RELEASES_URL = 'https://downloads.claude.ai/releases/win32/x64/RELEASES';
const CHECK_INTERVAL_MS = 60 * 60 * 1000; // 1 ora
const FIRST_CHECK_DELAY_MS = 2 * 60 * 1000; // 2 minuti dopo l'avvio
const INSTALLED_VERSION_PATH = '/usr/lib/claude-desktop/.installed-version';
const LOG_PREFIX = '[update-checker]';

// Evita notifiche ripetute per la stessa versione
let lastNotifiedVersion = null;
let isChecking = false;
// Cache dell'ultimo check (per il dialog "Info versione")
let lastKnownRemote = null;
let lastCheckTime = null;

function log(...args) {
    console.log(LOG_PREFIX, ...args);
}

// Legge la versione installata dal file creato dallo script di build,
// con fallback al campo "version" del package.json dell'asar.
function getInstalledVersion() {
    try {
        if (fs.existsSync(INSTALLED_VERSION_PATH)) {
            return fs.readFileSync(INSTALLED_VERSION_PATH, 'utf8').trim();
        }
    } catch (e) {}
    try {
        const pkg = require('./package.json');
        return pkg.version || '0.0.0';
    } catch (e) {
        return '0.0.0';
    }
}

// Scarica il file RELEASES e estrae l'ultima versione + nome nupkg
function fetchLatestVersion() {
    return new Promise((resolve, reject) => {
        const req = https.get(RELEASES_URL, { timeout: 15000 }, (res) => {
            if (res.statusCode !== 200) {
                return reject(new Error('HTTP ' + res.statusCode));
            }
            let data = '';
            res.setEncoding('utf8');
            res.on('data', (chunk) => { data += chunk; });
            res.on('end', () => {
                const lines = data.split(/\r?\n/).filter((l) => l.includes('-full.nupkg'));
                if (lines.length === 0) {
                    return reject(new Error('Nessuna riga -full.nupkg in RELEASES'));
                }
                const last = lines[lines.length - 1];
                const parts = last.trim().split(/\s+/);
                const nupkgName = parts[1];
                const match = nupkgName && nupkgName.match(/(\d+\.\d+\.\d+)-full/);
                if (!match) {
                    return reject(new Error('Formato riga non riconosciuto: ' + last));
                }
                resolve({ version: match[1], nupkgName: nupkgName });
            });
        });
        req.on('error', reject);
        req.on('timeout', () => { req.destroy(); reject(new Error('Timeout')); });
    });
}

// Confronto semver-style: ritorna true se a > b
function versionGt(a, b) {
    const pa = a.split('.').map((n) => parseInt(n, 10));
    const pb = b.split('.').map((n) => parseInt(n, 10));
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
        const x = pa[i] || 0, y = pb[i] || 0;
        if (x > y) return true;
        if (x < y) return false;
    }
    return false;
}

// Mostra notifica "aggiornamento disponibile"
// Click sulla notifica apre un dialog nativo con bottoni
function notifyUpdateAvailable(currentVer, latestVer) {
    if (lastNotifiedVersion === latestVer) return; // già notificato
    lastNotifiedVersion = latestVer;

    if (!Notification.isSupported()) {
        log('Notifiche non supportate, skip');
        return;
    }

    const n = new Notification({
        title: 'Aggiornamento Claude Desktop disponibile',
        body: `Nuova versione: ${latestVer}\nInstallata: ${currentVer}\nClicca per aggiornare.`,
        silent: false,
    });

    n.on('click', () => {
        showUpgradeDialog(currentVer, latestVer);
    });

    n.show();
    log(`Notificato aggiornamento: ${currentVer} -> ${latestVer}`);
}

// Dialog nativo per confermare l'upgrade
function showUpgradeDialog(currentVer, latestVer) {
    const choice = dialog.showMessageBoxSync({
        type: 'question',
        title: 'Aggiornamento Claude Desktop',
        message: `È disponibile la versione ${latestVer}`,
        detail: `Versione installata: ${currentVer}\n\n` +
                `L'aggiornamento scaricherà il pacchetto da Anthropic (~200 MB), ` +
                `lo patcherà per Linux e lo installerà sul sistema. ` +
                `Ti verrà chiesta la password di amministratore.\n\n` +
                `Claude verrà riavviato al termine.`,
        buttons: ['Aggiorna ora', 'Più tardi'],
        defaultId: 0,
        cancelId: 1,
    });

    if (choice === 0) {
        runUpgrade();
    }
}

// Lancia /usr/bin/claude-update con un argomento (--upgrade | --diagnose).
// Eredita l'ambiente desktop del processo Electron, necessario per:
//   - pkexec (richiede DISPLAY/XAUTHORITY/DBUS_SESSION_BUS_ADDRESS per il
//     dialog di autenticazione PolicyKit)
//   - zenity (progress bar e dialog richiedono DISPLAY)
//   - xdg-open (diagnose apre URL in browser)
// Senza queste variabili i sottoprocessi falliscono silenziosamente.
function spawnClaudeUpdate(arg) {
    log('Lancio claude-update', arg);
    const env = Object.assign({}, process.env);
    const requiredVars = ['DISPLAY', 'XAUTHORITY', 'DBUS_SESSION_BUS_ADDRESS',
        'XDG_RUNTIME_DIR', 'HOME', 'USER', 'PATH'];
    const missing = requiredVars.filter((v) => !env[v]);
    if (missing.length > 0) {
        log('ATTENZIONE: variabili ambiente mancanti:', missing.join(', '));
    }
    const child = spawn('/usr/bin/claude-update', [arg], {
        detached: true,
        stdio: 'ignore',
        env: env,
        cwd: env.HOME || '/tmp',
    });
    child.unref();
}

// Lancia /usr/bin/claude-update --upgrade come processo staccato.
function runUpgrade() {
    spawnClaudeUpdate('--upgrade');
}

// Notifica di errore quando l'endpoint è rotto o il formato è cambiato
function notifyEndpointError(errorMsg) {
    if (lastNotifiedVersion === 'ERROR') return;
    lastNotifiedVersion = 'ERROR';

    if (!Notification.isSupported()) return;

    const n = new Notification({
        title: 'Controllo aggiornamenti Claude fallito',
        body: 'Anthropic potrebbe aver cambiato il meccanismo di pubblicazione. Clicca per diagnosticare.',
        silent: true,
    });

    n.on('click', () => {
        const choice = dialog.showMessageBoxSync({
            type: 'warning',
            title: 'Controllo aggiornamenti fallito',
            message: 'Non riesco a contattare l\'endpoint di aggiornamento',
            detail: `Errore: ${errorMsg}\n\n` +
                    `Probabilmente Anthropic ha cambiato il meccanismo di pubblicazione ` +
                    `dei pacchetti Windows. Posso aprirti una chat con Claude su ` +
                    `claude.ai con il contesto necessario per diagnosticare e correggere ` +
                    `lo script.`,
            buttons: ['Apri diagnostica', 'Ignora'],
            defaultId: 0,
            cancelId: 1,
        });
        if (choice === 0) {
            spawnClaudeUpdate('--diagnose');
        }
    });
    n.show();
}

// Funzione principale di check
async function performCheck() {
    if (isChecking) {
        log('Check già in corso, skip');
        return;
    }
    isChecking = true;
    try {
        const installed = getInstalledVersion();
        log(`Check: versione installata = ${installed}`);
        const remote = await fetchLatestVersion();
        log(`Check: versione remota = ${remote.version}`);

        // Salva info per il dialog "Info versione"
        lastKnownRemote = remote;
        lastCheckTime = new Date();

        if (versionGt(remote.version, installed)) {
            notifyUpdateAvailable(installed, remote.version);
        } else {
            // Reset notifica error se ora funziona di nuovo
            if (lastNotifiedVersion === 'ERROR') lastNotifiedVersion = null;
            log('App aggiornata');
        }
    } catch (err) {
        log('Check fallito:', err.message);
        lastKnownRemote = null; // reset cache in caso di errore
        notifyEndpointError(err.message);
    } finally {
        isChecking = false;
    }
}

// Dialog "Info versione e aggiornamenti" — invocato dal menu applicazione
async function showVersionInfo() {
    const installed = getInstalledVersion();

    // Se non abbiamo un check recente (ultimo > 5 min fa) o mai fatto,
    // facciamo un check sincrono per avere info fresche nel dialog
    const needsFreshCheck = !lastCheckTime
        || (Date.now() - lastCheckTime.getTime()) > 5 * 60 * 1000;

    let remote = lastKnownRemote;
    let checkError = null;

    if (needsFreshCheck) {
        try {
            remote = await fetchLatestVersion();
            lastKnownRemote = remote;
            lastCheckTime = new Date();
        } catch (err) {
            checkError = err.message;
        }
    }

    if (checkError) {
        const choice = dialog.showMessageBoxSync({
            type: 'warning',
            title: 'Info versione Claude Desktop',
            message: `Versione installata: ${installed}`,
            detail: `Controllo versione remota fallito: ${checkError}\n\n` +
                    `L'endpoint di distribuzione di Anthropic potrebbe essere ` +
                    `cambiato. Posso aprire claude.ai con un prompt di ` +
                    `diagnostica per aiutarti a risolvere.`,
            buttons: ['Apri diagnostica', 'Chiudi'],
            defaultId: 1,
            cancelId: 1,
        });
        if (choice === 0) {
            spawnClaudeUpdate('--diagnose');
        }
        return;
    }

    if (versionGt(remote.version, installed)) {
        // C'è un aggiornamento disponibile
        const choice = dialog.showMessageBoxSync({
            type: 'info',
            title: 'Info versione Claude Desktop',
            message: `Aggiornamento disponibile`,
            detail: `Versione installata: ${installed}\n` +
                    `Versione disponibile: ${remote.version}\n\n` +
                    `L'aggiornamento scaricherà il pacchetto da Anthropic ` +
                    `(~200 MB) e lo installerà. Ti verrà chiesta la password ` +
                    `di amministratore. Claude verrà riavviato al termine.`,
            buttons: ['Aggiorna ora', 'Più tardi'],
            defaultId: 0,
            cancelId: 1,
        });
        if (choice === 0) {
            runUpgrade();
        }
    } else {
        // Già aggiornato
        dialog.showMessageBoxSync({
            type: 'info',
            title: 'Info versione Claude Desktop',
            message: `Claude Desktop è aggiornato`,
            detail: `Versione installata: ${installed}\n` +
                    `Versione disponibile: ${remote.version}\n\n` +
                    `Hai l'ultima versione disponibile.`,
            buttons: ['OK'],
            defaultId: 0,
        });
    }
}

// Forza una verifica aggiornamenti immediata e mostra risultato
// (stessa logica di showVersionInfo ma con feedback anche se aggiornato)
async function checkForUpdatesNow() {
    try {
        const remote = await fetchLatestVersion();
        lastKnownRemote = remote;
        lastCheckTime = new Date();
        const installed = getInstalledVersion();
        if (versionGt(remote.version, installed)) {
            notifyUpdateAvailable(installed, remote.version);
        } else {
            // Notifica transiente di conferma
            if (Notification.isSupported()) {
                new Notification({
                    title: 'Claude Desktop è aggiornato',
                    body: `Hai la versione più recente (${installed}).`,
                    silent: true,
                }).show();
            }
        }
    } catch (err) {
        notifyEndpointError(err.message);
    }
}

// Nasconde una finestra appena creata, rimuove i menu, poi la mostra
// dopo che il menu è stato sicuramente rimosso. Il polling di rimozione
// menu CONTINUA anche dopo la show, perché l'app re-imposta il menu
// in modo asincrono anche dopo l'apertura della finestra.
function handleNewWindowHideUntilMenuRemoved(win) {
    try {
        // Nascondi immediatamente
        win.hide();

        // Rimuovi menu prima di mostrare
        if (typeof win.setMenu === 'function') win.setMenu(null);
        if (typeof win.setMenuBarVisibility === 'function') {
            win.setMenuBarVisibility(false);
        }
        Menu.setApplicationMenu(null);

        // Polling PERMANENTE: ogni 200ms rimuove il menu, per tutta la
        // vita dell'app. L'app può re-impostare il menu in modo asincrono
        // a qualsiasi momento (non solo all'avvio), quindi non smettiamo mai.
        setInterval(() => {
            try {
                Menu.setApplicationMenu(null);
                BrowserWindow.getAllWindows().forEach((w) => {
                    try {
                        if (typeof w.setMenu === 'function') w.setMenu(null);
                        if (typeof w.setMenuBarVisibility === 'function') {
                            w.setMenuBarVisibility(false);
                        }
                    } catch (e) {}
                });
            } catch (e) {}
        }, 200);

        // Mostra la finestra dopo 5 secondi (lasciamo tempo al polling di
        // rimuovere il menu più volte prima del primo render visibile).
        const showWhenReady = () => {
            try {
                Menu.setApplicationMenu(null);
                if (typeof win.setMenu === 'function') win.setMenu(null);
                if (typeof win.setMenuBarVisibility === 'function') {
                    win.setMenuBarVisibility(false);
                }
                win.show();
                win.focus();
            } catch (e) {}
        };

        // Aspetta 5 secondi prima di mostrare
        setTimeout(showWhenReady, 5000);
    } catch (e) {
        log('Errore handleNewWindow:', e.message);
        try { win.show(); } catch (e2) {}
    }
}

// Configura tray icon (area di notifica) con menu contestuale.
// Sostituisce il menu applicazione classico con un'icona nell'area
// di sistema, pattern standard su Linux per app Electron/headless.
let trayInstance = null;
function setupTrayIcon() {
    try {
        // Re-rimuovi il menu periodicamente nei primi 30 secondi
        // (l'app può re-impostarlo asincronamente dopo le nostre rimozioni)
        let removeAttempts = 0;
        const removeInterval = setInterval(() => {
            try {
                Menu.setApplicationMenu(null);
                BrowserWindow.getAllWindows().forEach((w) => {
                    try {
                        if (typeof w.setMenu === 'function') w.setMenu(null);
                        if (typeof w.setMenuBarVisibility === 'function') {
                            w.setMenuBarVisibility(false);
                        }
                    } catch (e) {}
                });
            } catch (e) {}
            if (++removeAttempts >= 15) clearInterval(removeInterval);
        }, 2000);

        // Cerca l'icona Claude installata dal .deb
        const fs = require('fs');
        const iconCandidates = [
            '/usr/share/icons/hicolor/256x256/apps/claude.png',
            '/usr/share/icons/hicolor/128x128/apps/claude.png',
            '/usr/share/icons/hicolor/64x64/apps/claude.png',
            '/usr/share/icons/hicolor/48x48/apps/claude.png',
            '/usr/share/icons/hicolor/32x32/apps/claude.png',
        ];
        let iconPath = null;
        for (const c of iconCandidates) {
            if (fs.existsSync(c)) { iconPath = c; break; }
        }
        if (!iconPath) {
            log('Nessuna icona trovata, tray non creato');
            return;
        }

        trayInstance = new Tray(iconPath);
        trayInstance.setToolTip('Claude Desktop');

        const buildMenu = () => Menu.buildFromTemplate([
            {
                label: `Claude Desktop v${getInstalledVersion()}`,
                enabled: false,
            },
            { type: 'separator' },
            {
                label: 'Mostra/Nascondi finestra',
                click: toggleMainWindow,
            },
            { type: 'separator' },
            {
                label: 'Verifica aggiornamenti',
                click: () => { checkForUpdatesNow(); },
            },
            {
                label: 'Info versione e aggiornamenti…',
                click: () => { showVersionInfo(); },
            },
            { type: 'separator' },
            {
                label: 'Esci',
                click: () => { app.quit(); },
            },
        ]);

        trayInstance.setContextMenu(buildMenu());
        trayInstance.on('click', toggleMainWindow);

        log('Tray icon configurato');
    } catch (e) {
        log('Errore setup tray:', e.message);
    }
}

// Mostra/nasconde la finestra principale al click sul tray
function toggleMainWindow() {
    try {
        const windows = BrowserWindow.getAllWindows();
        if (!windows || windows.length === 0) return;
        // Trova la finestra "principale" (la prima visibile o la prima in lista)
        const main = windows.find((w) => w.isVisible()) || windows[0];
        if (main.isVisible() && main.isFocused()) {
            main.hide();
        } else {
            if (!main.isVisible()) main.show();
            main.focus();
        }
    } catch (e) {
        log('Errore toggleMainWindow:', e.message);
    }
}

// Avvio del polling: aspettiamo che l'app sia pronta
app.whenReady().then(() => {
    log(`Update checker avviato (polling ogni ${CHECK_INTERVAL_MS / 60000} min)`);

    // SUBITO: rimuoviamo il menu applicazione e agganciamo il listener
    // per le nuove finestre. Questo deve avvenire prima possibile, perché
    // se aspettiamo troppo (es. setTimeout 3000) la finestra principale
    // dell'app è già visibile col menu.
    Menu.setApplicationMenu(null);
    app.on('browser-window-created', (event, win) => {
        handleNewWindowHideUntilMenuRemoved(win);
    });

    // Eventuali finestre già create prima di questo punto: trattale ora
    BrowserWindow.getAllWindows().forEach((w) => {
        try {
            if (typeof w.setMenu === 'function') w.setMenu(null);
            if (typeof w.setMenuBarVisibility === 'function') {
                w.setMenuBarVisibility(false);
            }
        } catch (e) {}
    });

    // Setup tray icon (l'icona di sistema). Ritardiamo leggermente
    // per dare tempo alle prime finestre di stabilizzarsi.
    setTimeout(setupTrayIcon, 3000);

    // Primo check aggiornamenti dopo un breve delay
    setTimeout(performCheck, FIRST_CHECK_DELAY_MS);
    // Poi ogni ora
    setInterval(performCheck, CHECK_INTERVAL_MS);
}).catch((e) => {
    log('whenReady fallito:', e.message);
});
UPDATER_JS

# Aggiorna package.json per usare il nostro entry point
PKGJSON_PATH="${WORKDIR}/app-extracted/package.json"
if [[ -f "${PKGJSON_PATH}" ]]; then
    # Sostituisce il campo "main" con il nostro entry point
    node -e "
        const fs = require('fs');
        const pkg = JSON.parse(fs.readFileSync('${PKGJSON_PATH}', 'utf8'));
        pkg.main = './frame-fix-entry.js';
        fs.writeFileSync('${PKGJSON_PATH}', JSON.stringify(pkg, null, 2));
    " || warn "Impossibile aggiornare package.json main field"
fi
ok "Frame fix wrapper scritto"

# =============================================================================
# STEP 7b — Patch Linux per Claude Code (CCD)
# =============================================================================
# L'app upstream include un modulo CCD (Claude Code Downloader) che gestisce
# il download del binario `claude` per Chat → Code. Il suo manifest include
# già linux-x64 e linux-arm64 come target validi, ma la funzione
# getHostPlatform() non li mappa esplicitamente e lancia:
#   "Unsupported platform: linux-x64"
# Patchiamo solo quella funzione aggiungendo il ramo Linux, senza toccare
# nient'altro. Il binario `claude` per Linux esiste ufficialmente ed è
# hostato da Anthropic, quindi dopo questa patch il download funziona.
info "Patch Claude Code (CCD) per supporto Linux..."

VITE_INDEX="${WORKDIR}/app-extracted/.vite/build/index.js"
if [[ -f "${VITE_INDEX}" ]]; then
    # Scriviamo lo script di patch in un file separato per evitare i problemi
    # di escaping con node -e dentro heredoc bash (backtick, template strings,
    # quote annidate). Un file .js è molto più affidabile.
    PATCH_SCRIPT="${WORKDIR}/patch-ccd.js"
    cat > "${PATCH_SCRIPT}" << 'PATCHJS'
'use strict';
const fs = require('fs');
const path = process.argv[2];

if (!path) {
    console.error('[ERROR] Path del file index.js non fornito');
    process.exit(1);
}

let src;
try {
    src = fs.readFileSync(path, 'utf8');
} catch (e) {
    console.error('[ERROR] Impossibile leggere il file:', e.message);
    process.exit(1);
}

// Il pattern cerca la funzione getHostPlatform() nell'index.js minificato.
// Il testo è: if win32... ;throw new Error(`Unsupported platform:
// Nota: la stringa viene costruita in modo da contenere backtick letterale.
const needle =
    'if(process.platform==="win32")return A==="arm64"?"win32-arm64":"win32-x64";' +
    'throw new Error(' + String.fromCharCode(96) + 'Unsupported platform:';

const replacement =
    'if(process.platform==="win32")return A==="arm64"?"win32-arm64":"win32-x64";' +
    'if(process.platform==="linux")return A==="arm64"?"linux-arm64":"linux-x64";' +
    'throw new Error(' + String.fromCharCode(96) + 'Unsupported platform:';

// Conta occorrenze
let count = 0;
let idx = -1;
while ((idx = src.indexOf(needle, idx + 1)) !== -1) count++;

if (count === 0) {
    console.error('[WARN] Pattern getHostPlatform non trovato. Upstream potrebbe essere cambiato.');
    // Proviamo anche un pattern di fallback più tollerante (senza ";throw")
    const altNeedle =
        'if(process.platform==="win32")return A==="arm64"?"win32-arm64":"win32-x64";';
    const altReplacement =
        'if(process.platform==="win32")return A==="arm64"?"win32-arm64":"win32-x64";' +
        'if(process.platform==="linux")return A==="arm64"?"linux-arm64":"linux-x64";';

    let altCount = 0;
    let i = -1;
    while ((i = src.indexOf(altNeedle, i + 1)) !== -1) altCount++;

    if (altCount === 0) {
        console.error('[WARN] Anche il pattern di fallback non trovato. Nessuna patch applicata.');
        process.exit(0);
    }
    console.log('[INFO] Uso pattern di fallback (' + altCount + ' occorrenze)');
    src = src.split(altNeedle).join(altReplacement);
} else {
    src = src.split(needle).join(replacement);
    console.log('[OK] Patch getHostPlatform applicata (' + count + ' occorrenze)');
}

fs.writeFileSync(path, src, 'utf8');
console.log('[OK] File salvato: ' + path);
PATCHJS
    node "${PATCH_SCRIPT}" "${VITE_INDEX}" \
        || warn "Patch Code/CCD fallita (non bloccante)"

    # Verifica post-patch: cerchiamo process.platform==="linux" nel file
    if grep -q 'process\.platform==="linux")return A==="arm64"' "${VITE_INDEX}"; then
        ok "Patch Code/CCD verificata: ramo linux presente in index.js"
    else
        warn "Patch Code/CCD non verificata: ramo linux non trovato dopo la patch"
    fi
else
    warn "File .vite/build/index.js non trovato, skip patch Code/CCD"
fi

# =============================================================================
# STEP 8 — Riconfezionamento in app.asar
# =============================================================================
info "Riconfezionamento app.asar..."
"${ASAR}" pack \
    "${WORKDIR}/app-extracted" \
    "${WORKDIR}/app-patched.asar" \
    || die "Riconfezionamento app.asar fallito"
ok "app.asar riconfezionato"

# =============================================================================
# STEP 9 — Installazione di Electron locale
# =============================================================================
# Installiamo Electron localmente nel pacchetto .deb, così non dipende
# dalla versione di sistema (che potrebbe non esserci o essere incompatibile).
info "Installazione Electron locale (può richiedere qualche minuto)..."
mkdir -p "${WORKDIR}/electron-install"
npm install --prefix "${WORKDIR}/electron-install" electron 2>/dev/null \
    || die "Installazione Electron fallita"

ELECTRON_BIN=$(find "${WORKDIR}/electron-install" -name "electron" -type f | head -1)
ELECTRON_DIST=$(dirname "${ELECTRON_BIN}")
[[ -x "${ELECTRON_BIN}" ]] || die "Electron non trovato dopo installazione"
ok "Electron installato: ${ELECTRON_BIN}"

# =============================================================================
# STEP 10 — Preparazione struttura .deb
# =============================================================================
info "Preparazione struttura pacchetto .deb..."

# Struttura directory del pacchetto Debian
mkdir -p "${DEBROOT}/DEBIAN"
mkdir -p "${DEBROOT}/usr/lib/claude-desktop"
mkdir -p "${DEBROOT}/usr/bin"
mkdir -p "${DEBROOT}/usr/share/applications"

# Icone per varie dimensioni
for size in 16 24 32 48 64 128 256; do
    mkdir -p "${DEBROOT}/usr/share/icons/hicolor/${size}x${size}/apps"
done

# ── Copia i file dell'app ──────────────────────────────────────────────────
cp "${WORKDIR}/app-patched.asar" \
    "${DEBROOT}/usr/lib/claude-desktop/app.asar"

if [[ -d "${WORKDIR}/app.asar.unpacked" ]]; then
    cp -r "${WORKDIR}/app.asar.unpacked" \
        "${DEBROOT}/usr/lib/claude-desktop/app.asar.unpacked"
fi

# Scrivi la versione installata in un file letto dall'update-checker.
# Questo è l'unica fonte di verità sulla versione attualmente presente
# sul sistema; viene aggiornato anche da claude-update --upgrade.
echo "${DEB_VERSION}" > "${DEBROOT}/usr/lib/claude-desktop/.installed-version"

# Copia resources/ (i18n e altri asset): Electron li cerca nella stessa
# directory di app.asar, quindi devono stare in /usr/lib/claude-desktop/resources/
if [[ -d "${WORKDIR}/resources" ]]; then
    cp -r "${WORKDIR}/resources" \
        "${DEBROOT}/usr/lib/claude-desktop/resources"
    info "resources/ copiata nel .deb ($(find "${WORKDIR}/resources" -type f | wc -l) file)"
else
    warn "resources/ non trovata — i18n potrebbe non funzionare"
fi

# Copia Electron e le sue librerie
cp -r "${ELECTRON_DIST}/" \
    "${DEBROOT}/usr/lib/claude-desktop/electron-dist/"

# Imposta permessi SUID su chrome-sandbox (richiesto da Electron sandbox)
SANDBOX="${DEBROOT}/usr/lib/claude-desktop/electron-dist/chrome-sandbox"
if [[ -f "${SANDBOX}" ]]; then
    chmod 4755 "${SANDBOX}"
fi

# ── Copia le icone ──────────────────────────────────────────────────────────
for size in 16 24 32 48 64 128 256; do
    # Cerca un'icona della giusta dimensione
    ICON_SRC=$(find "${WORKDIR}/icons" -name "*${size}*" -name "*.png" | head -1)
    if [[ -z "${ICON_SRC}" ]]; then
        # Prendi la prima disponibile e ridimensiona
        ICON_SRC=$(find "${WORKDIR}/icons" -name "*.png" | head -1)
    fi
    if [[ -n "${ICON_SRC}" ]]; then
        convert "${ICON_SRC}" \
            -resize "${size}x${size}" \
            "${DEBROOT}/usr/share/icons/hicolor/${size}x${size}/apps/claude.png" \
            2>/dev/null || true
    fi
done

# ── Script launcher /usr/bin/claude-desktop ─────────────────────────────────
info "Scrittura script launcher..."
cat > "${DEBROOT}/usr/bin/claude-desktop" << 'LAUNCHER'
#!/usr/bin/env bash
# Launcher per Claude Desktop su Linux
# Avvia Electron con l'app Claude Desktop

INSTALL_DIR="/usr/lib/claude-desktop"
ELECTRON="${INSTALL_DIR}/electron-dist/electron"
APP_ASAR="${INSTALL_DIR}/app.asar"

if [[ ! -x "${ELECTRON}" ]]; then
    echo "Errore: Electron non trovato in ${ELECTRON}" >&2
    exit 1
fi
if [[ ! -f "${APP_ASAR}" ]]; then
    echo "Errore: app.asar non trovato in ${APP_ASAR}" >&2
    exit 1
fi

# --app-path imposta process.resourcesPath usato dall'app per trovare i18n e altri asset
exec "${ELECTRON}" "${APP_ASAR}" \
    --app-path="${INSTALL_DIR}" \
    "$@"
LAUNCHER
chmod +x "${DEBROOT}/usr/bin/claude-desktop"

# ── File .desktop per il menu applicazioni ───────────────────────────────────
info "Scrittura file .desktop..."
cat > "${DEBROOT}/usr/share/applications/claude-desktop.desktop" << DESKTOP
[Desktop Entry]
Name=Claude
Comment=Claude AI Assistant by Anthropic
Exec=/usr/bin/claude-desktop %U
Icon=claude
Terminal=false
Type=Application
Categories=Office;Utility;Network;
StartupWMClass=Claude
MimeType=x-scheme-handler/claude;
DESKTOP

# =============================================================================
# STEP 10b — Script claude-update (download + install + diagnose)
# =============================================================================
# Il polling orario è gestito dall'app Electron stessa (update-checker.js
# dentro app.asar). Questo script è solo il "worker" che fa il lavoro:
#   - /usr/bin/claude-update --upgrade   scarica e installa nuova versione
#   - /usr/bin/claude-update --diagnose  apre claude.ai con prompt di help
#   - /usr/bin/claude-update --status    stampa versione corrente/disponibile
# Viene invocato dall'app quando l'utente clicca "Aggiorna ora" sulla
# notifica, oppure manualmente da terminale.
# =============================================================================
info "Scrittura script claude-update..."

# ── Script principale /usr/bin/claude-update ────────────────────────────────
cat > "${DEBROOT}/usr/bin/claude-update" << 'UPDATER'
#!/usr/bin/env bash
# claude-update — Worker di aggiornamento per Claude Desktop su Linux
#
# NOTA: il polling orario è fatto dall'app Electron (update-checker.js).
# Questo script esegue l'azione effettiva quando richiesta.
#
# Modalità:
#   --upgrade  Esegue download + installazione della nuova versione.
#              Mostra dialog grafico di progresso (se zenity disponibile).
#   --diagnose Apre Claude con un prompt precompilato che descrive il problema
#              e chiede aiuto per risolvere il meccanismo di update.
#   --status   Stampa informazioni versione senza UI (per debug).
#
# Fonti dati (devono combaciare con quelle dello script di build):
RELEASES_URL="https://downloads.claude.ai/releases/win32/x64/RELEASES"
NUPKG_BASE_URL="https://downloads.claude.ai/releases/win32/x64"

# Directory di lavoro per l'update (nella home utente)
UPDATE_DIR="${HOME}/.cache/claude-update"
mkdir -p "${UPDATE_DIR}"

# ── Funzioni di utilità ───────────────────────────────────────────────────
installed_version() {
    dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null || echo "sconosciuta"
}

latest_version() {
    # Ritorna "VERSIONE NUPKG_NAME" o stringa vuota in caso di errore
    local line version nupkg
    line=$(curl -sL --max-time 15 "${RELEASES_URL}" 2>/dev/null \
        | grep -i "\-full\.nupkg" | tail -1 | tr -d '\r')
    [[ -z "${line}" ]] && return 1
    nupkg=$(echo "${line}" | awk '{print $2}')
    version=$(echo "${nupkg}" | grep -oP '\d+\.\d+\.\d+(?=-full)')
    [[ -z "${version}" || -z "${nupkg}" ]] && return 1
    echo "${version} ${nupkg}"
}

verify_nupkg_url() {
    local url="$1"
    local code
    code=$(curl -sI --max-time 10 "${url}" 2>/dev/null \
        | grep -i "^http/" | tail -1 | awk '{print $2}')
    [[ "${code}" == "200" ]]
}

version_gt() {
    # version_gt "1.2.3" "1.2.0" → true se $1 > $2
    [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" != "$1" ]]
}

# ── Modalità --status ─────────────────────────────────────────────────────
cmd_status() {
    local installed latest_info latest_ver
    installed=$(installed_version)
    echo "Versione installata: ${installed}"
    latest_info=$(latest_version) || {
        echo "Versione disponibile: impossibile determinarla (endpoint non raggiungibile)"
        return 2
    }
    latest_ver=$(echo "${latest_info}" | awk '{print $1}')
    echo "Versione disponibile: ${latest_ver}"
    if version_gt "${latest_ver}" "${installed}"; then
        echo "Stato: aggiornamento disponibile"
        return 1
    else
        echo "Stato: aggiornata"
        return 0
    fi
}

# ── Modalità --upgrade (scarica e installa nuova versione) ────────────────
cmd_upgrade() {
    local latest_ver latest_url nupkg_file tmp_deb
    # L'app ci passa versione e URL via variabili d'ambiente se disponibili,
    # altrimenti rileviamo dal RELEASES
    latest_ver="${CLAUDE_UPDATE_VERSION:-}"
    latest_url="${CLAUDE_UPDATE_URL:-}"

    # Se non abbiamo info cachate, rifacciamo il check
    if [[ -z "${latest_ver}" || -z "${latest_url}" ]]; then
        local info
        info=$(latest_version) || die_gui "Impossibile contattare downloads.claude.ai"
        latest_ver=$(echo "${info}" | awk '{print $1}')
        local nupkg_name
        nupkg_name=$(echo "${info}" | awk '{print $2}')
        latest_url="${NUPKG_BASE_URL}/${nupkg_name}"
    fi

    nupkg_file="${UPDATE_DIR}/AnthropicClaude-${latest_ver}-full.nupkg"

    # Download con progress bar grafica (zenity) o testuale
    if command -v zenity >/dev/null 2>&1; then
        ( curl -L --progress-bar -o "${nupkg_file}" "${latest_url}" 2>&1 \
            | tr '\r' '\n' \
            | sed -u 's/[^0-9]*\([0-9]*\).*/\1/' ) \
            | zenity --progress --auto-close --no-cancel \
                --title="Aggiornamento Claude Desktop" \
                --text="Download versione ${latest_ver} in corso..." 2>/dev/null \
            || curl -L --progress-bar -o "${nupkg_file}" "${latest_url}"
    else
        curl -L --progress-bar -o "${nupkg_file}" "${latest_url}"
    fi

    [[ -f "${nupkg_file}" ]] || die_gui "Download fallito"

    # Verifica magic bytes ZIP
    local magic
    magic=$(head -c 4 "${nupkg_file}" | od -A n -t x1 | tr -d ' \n')
    [[ "${magic}" == "504b0304" ]] || die_gui "File scaricato non valido"

    # Ricostruisci e installa. Usiamo lo script di build se presente.
    # In alternativa, aggiorniamo in-place i soli file modificati (app.asar + resources)
    do_inplace_upgrade "${nupkg_file}" "${latest_ver}" \
        || die_gui "Aggiornamento fallito. Esegui lo script di build manualmente."

    # Successo: notifica riavvio
    if command -v zenity >/dev/null 2>&1; then
        zenity --info --title="Claude Desktop aggiornato" \
            --text="Versione ${latest_ver} installata.\nRiavvia Claude per applicare." \
            --ok-label="Riavvia ora" --timeout=60 2>/dev/null \
            && restart_claude
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send --app-name="Claude Desktop" --icon=claude \
            "Aggiornamento completato" \
            "Versione ${latest_ver} installata. Riavvia Claude per applicare."
    fi
}

# Upgrade in-place: estrae nupkg, patcha e sostituisce app.asar + resources
# Usa pkexec per ottenere privilegi di scrittura su /usr/lib/claude-desktop
do_inplace_upgrade() {
    local nupkg_file="$1"
    local new_version="$2"
    local staging="${UPDATE_DIR}/staging"

    rm -rf "${staging}"
    mkdir -p "${staging}/extract"

    # Estrai nupkg
    7z x -y "${nupkg_file}" -o"${staging}/extract" >/dev/null 2>&1 || return 1

    # Trova app.asar
    local new_asar
    new_asar=$(find "${staging}/extract" -name "app.asar" | head -1)
    [[ -z "${new_asar}" ]] && return 1

    # Estrai asar, applica patch (stub native + frame fix + i18n) e ricompatta
    local asar_tool
    asar_tool=$(command -v asar 2>/dev/null \
        || find /usr/lib/claude-desktop -name "asar" -type f 2>/dev/null | head -1)
    if [[ -z "${asar_tool}" ]]; then
        # Installa asar temporaneamente
        npm install --prefix "${staging}/npm-tools" @electron/asar >/dev/null 2>&1 || return 1
        asar_tool="${staging}/npm-tools/node_modules/.bin/asar"
    fi

    local extracted="${staging}/app-extracted"
    "${asar_tool}" extract "${new_asar}" "${extracted}" || return 1

    # Applica le stesse patch dello script di build
    apply_patches "${extracted}" "${staging}/extract" || return 1

    # Ricompatta
    "${asar_tool}" pack "${extracted}" "${staging}/app-patched.asar" || return 1

    # Copia in /usr/lib/claude-desktop (richiede privilegi)
    local target="/usr/lib/claude-desktop"
    local resources_src="${staging}/extract"
    local resources_dir
    resources_dir=$(find "${resources_src}" -type d -name "resources" | head -1)

    if command -v pkexec >/dev/null 2>&1; then
        pkexec bash -c "
            cp '${staging}/app-patched.asar' '${target}/app.asar' && \
            if [[ -d '${resources_dir}' ]]; then
                rm -rf '${target}/resources'
                cp -r '${resources_dir}' '${target}/resources'
            fi
        " || return 1
    else
        # Fallback: chiedi sudo via zenity
        local pw
        pw=$(zenity --password --title="Autenticazione richiesta" 2>/dev/null) || return 1
        echo "${pw}" | sudo -S bash -c "
            cp '${staging}/app-patched.asar' '${target}/app.asar' && \
            if [[ -d '${resources_dir}' ]]; then
                rm -rf '${target}/resources'
                cp -r '${resources_dir}' '${target}/resources'
            fi
        " || return 1
    fi

    rm -rf "${staging}"
    return 0
}

# Applica le patch minime necessarie (stub native + frame fix + i18n)
# NOTA: mantiene coerenza con le patch dello script di build principale.
# Se l'upstream cambia struttura, queste vanno aggiornate in entrambi i posti.
apply_patches() {
    local extracted="$1"
    local nupkg_extract="$2"

    # 1. Stub @ant/claude-native
    local native_dir
    native_dir=$(find "${extracted}" -type d -name "claude-native" | head -1)
    [[ -z "${native_dir}" ]] && native_dir="${extracted}/node_modules/@ant/claude-native"
    mkdir -p "${native_dir}"
    cat > "${native_dir}/package.json" <<'PKG'
{"name":"@ant/claude-native","version":"1.0.0","main":"index.js"}
PKG
    cat > "${native_dir}/index.js" <<'STUB'
'use strict';
const KeyboardKey={A:0,B:1,C:2,D:3,E:4,F:5,G:6,H:7,I:8,J:9,K:10,L:11,M:12,N:13,O:14,P:15,Q:16,R:17,S:18,T:19,U:20,V:21,W:22,X:23,Y:24,Z:25,N0:26,N1:27,N2:28,N3:29,N4:30,N5:31,N6:32,N7:33,N8:34,N9:35,F1:36,F2:37,F3:38,F4:39,F5:40,F6:41,F7:42,F8:43,F9:44,F10:45,F11:46,F12:47,Space:48,Enter:49,Tab:50,Backspace:51,Delete:52,Escape:53,Home:54,End:55,PageUp:56,PageDown:57,ArrowLeft:58,ArrowRight:59,ArrowUp:60,ArrowDown:61,Shift:62,Control:63,Alt:64,Meta:65};
const AuthRequest={isAvailable:()=>false,start:(_u,cb)=>cb&&cb(null,new Error('N/A Linux')),cancel:()=>{}};
module.exports={KeyboardKey,AuthRequest,getWindowsWithSameApp:()=>[],getMonitorList:()=>[],getMouseLocation:()=>({x:0,y:0}),getTotalMemory:()=>4*1024*1024*1024,getWindowTitle:()=>'',moveMouseTo:()=>{},simulateKey:()=>{},screenCapture:()=>null,setGlobalShortcut:()=>true,unsetGlobalShortcut:()=>{},getSystemTheme:()=>'dark',onWindowFocusChanged:()=>{},getResourcesPath:()=>'/usr/lib/claude-desktop'};
STUB

    # 2. Frame fix
    cat > "${extracted}/frame-fix-wrapper.js" <<'WRAP'
'use strict';
const Module=require('module');const orig=Module._load;
Module._load=function(req,parent,isMain){const r=orig.apply(this,arguments);
if(req==='electron'&&r&&r.BrowserWindow){const O=r.BrowserWindow;
class P extends O{constructor(o={}){if(o.frame===undefined)o=Object.assign({},o,{frame:true});super(o);}}
Object.assign(P,O);try{Object.defineProperty(r,'BrowserWindow',{value:P,writable:true,configurable:true});}catch(e){}}
return r;};
WRAP
    cat > "${extracted}/frame-fix-entry.js" <<'ENTRY'
'use strict';require('./frame-fix-wrapper');require('./.vite/build/index.js');
ENTRY

    # Aggiorna package.json main
    local pkgjson="${extracted}/package.json"
    if [[ -f "${pkgjson}" ]]; then
        node -e "
            const fs=require('fs');
            const p=JSON.parse(fs.readFileSync('${pkgjson}','utf8'));
            p.main='./frame-fix-entry.js';
            fs.writeFileSync('${pkgjson}',JSON.stringify(p,null,2));
        " 2>/dev/null || true
    fi

    # 3. Copia i18n dentro l'asar
    mkdir -p "${extracted}/resources/i18n"
    find "${nupkg_extract}" -name "*-*.json" \
        ! -path "*/node_modules/*" ! -name "package*.json" 2>/dev/null \
        | while read -r f; do
        cp "${f}" "${extracted}/resources/i18n/" 2>/dev/null || true
    done
    [[ -f "${extracted}/resources/i18n/en-US.json" ]] \
        || echo '{}' > "${extracted}/resources/i18n/en-US.json"

    # 4. Patch Claude Code (CCD) per supporto Linux
    # La funzione getHostPlatform() upstream non ha un ramo Linux.
    # Aggiungiamolo (linux-x64 / linux-arm64 sono target validi nel manifest).
    local vite_index="${extracted}/.vite/build/index.js"
    if [[ -f "${vite_index}" ]]; then
        local patch_js="${staging}/patch-ccd.js"
        cat > "${patch_js}" << 'PATCHCCD'
'use strict';
const fs = require('fs');
const p = process.argv[2];
if (!p) process.exit(1);
let s;
try { s = fs.readFileSync(p, 'utf8'); } catch (e) { process.exit(1); }
const needle =
    'if(process.platform==="win32")return A==="arm64"?"win32-arm64":"win32-x64";';
const repl =
    'if(process.platform==="win32")return A==="arm64"?"win32-arm64":"win32-x64";' +
    'if(process.platform==="linux")return A==="arm64"?"linux-arm64":"linux-x64";';
if (s.includes(needle) && !s.includes('if(process.platform==="linux")return A==="arm64"?"linux-arm64"')) {
    s = s.split(needle).join(repl);
    fs.writeFileSync(p, s, 'utf8');
}
PATCHCCD
        node "${patch_js}" "${vite_index}" 2>/dev/null || true
    fi

    return 0
}

# ── Modalità --diagnose ───────────────────────────────────────────────────
# Apre Claude con un prompt precompilato che spiega il problema e fornisce
# il contesto per risolvere un'eventuale rottura del meccanismo di update.
cmd_diagnose() {
    local installed releases_status
    installed=$(installed_version)
    releases_status=$(curl -sI --max-time 10 "${RELEASES_URL}" 2>/dev/null \
        | head -1 | tr -d '\r')

    # Prompt precompilato URL-encoded
    local prompt
    prompt=$(cat <<EOF
Il mio sistema di auto-update di Claude Desktop su Linux non funziona più.
Versione installata: ${installed}
URL testato: ${RELEASES_URL}
Risposta HTTP: ${releases_status}

Lo script claude-update legge il file RELEASES di Squirrel da:
  ${RELEASES_URL}
E si aspetta righe con formato:
  SHA1  AnthropicClaude-VERSION-full.nupkg  SIZE
Poi scarica il nupkg da:
  ${NUPKG_BASE_URL}/AnthropicClaude-VERSION-full.nupkg

Probabilmente Anthropic ha cambiato il meccanismo di pubblicazione dei
pacchetti Windows. Aiutami a:
1. Verificare qual è il nuovo endpoint di distribuzione
2. Aggiornare lo script claude-update in /usr/bin/claude-update
3. Aggiornare lo script di build build-claude-desktop.sh
EOF
)
    # URL-encode del prompt
    local encoded
    encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read()))" <<< "${prompt}")

    # Apre Claude web (più affidabile del deep link all'app)
    xdg-open "https://claude.ai/new?q=${encoded}" 2>/dev/null \
        || firefox "https://claude.ai/new?q=${encoded}" 2>/dev/null \
        || google-chrome "https://claude.ai/new?q=${encoded}" 2>/dev/null
}

# ── Funzioni ausiliarie ───────────────────────────────────────────────────
die_gui() {
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="Errore aggiornamento" --text="$1" 2>/dev/null
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send --urgency=critical "Errore aggiornamento Claude" "$1"
    fi
    echo "Errore: $1" >&2
    exit 1
}

restart_claude() {
    pkill -x claude-desktop 2>/dev/null
    sleep 1
    nohup /usr/bin/claude-desktop >/dev/null 2>&1 &
}

# ── Main dispatcher ───────────────────────────────────────────────────────
case "${1:---status}" in
    --upgrade)  cmd_upgrade ;;
    --diagnose) cmd_diagnose ;;
    --status)   cmd_status ;;
    *)
        echo "Uso: claude-update [--upgrade|--diagnose|--status]"
        echo ""
        echo "  --upgrade   Scarica e installa l'ultima versione di Claude Desktop."
        echo "              Normalmente invocato dall'app quando l'utente clicca"
        echo "              'Aggiorna ora' sulla notifica desktop."
        echo "  --diagnose  Apre claude.ai con un prompt di diagnostica per aiutarti"
        echo "              a risolvere problemi col meccanismo di update."
        echo "  --status    Stampa versione installata vs ultima disponibile."
        exit 1
        ;;
esac
UPDATER
chmod +x "${DEBROOT}/usr/bin/claude-update"

ok "Script claude-update scritto (polling gestito in-app)"

# =============================================================================
# STEP 11 — Metadati del pacchetto Debian (DEBIAN/control)
# =============================================================================
info "Scrittura DEBIAN/control..."

# Calcola dimensione installata in KB
INSTALLED_SIZE=$(du -sk "${DEBROOT}/usr" | cut -f1)

cat > "${DEBROOT}/DEBIAN/control" << CONTROL
Package: ${PACKAGE_NAME}
Version: ${DEB_VERSION}
Architecture: ${ARCH}
Maintainer: Build locale (nessun maintainer esterno)
Installed-Size: ${INSTALLED_SIZE}
Depends: libnss3, libatk-bridge2.0-0, libdrm2, libxkbcommon0, libgbm1,
 libasound2 | libasound2t64, libgtk-3-0, curl, p7zip-full,
 policykit-1, nodejs
Recommends: zenity, xdg-utils
Description: Claude Desktop AI Assistant (build locale)
 Claude Desktop è l'app desktop ufficiale di Anthropic per Claude AI.
 Questo pacchetto è costruito localmente dallo script build-claude-desktop.sh
 scaricando l'installer ufficiale da downloads.claude.ai (Anthropic).
 Nessun repository di terze parti è stato usato.
 .
 Include un sistema di auto-update integrato nell'app stessa: ogni ora,
 mentre Claude è in esecuzione, controlla la presenza di nuove versioni
 e notifica l'utente via notifica desktop nativa Electron.
 .
 Homepage: https://claude.ai
CONTROL

# ── Script post-installazione ────────────────────────────────────────────────
cat > "${DEBROOT}/DEBIAN/postinst" << 'POSTINST'
#!/bin/bash
set -e
# Aggiorna cache icone
if command -v update-icon-caches >/dev/null 2>&1; then
    update-icon-caches /usr/share/icons/hicolor/ 2>/dev/null || true
fi
# Aggiorna database .desktop
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications/ 2>/dev/null || true
fi
# Il polling aggiornamenti è gestito dall'app stessa: nessuna configurazione
# systemd o setup utente richiesto. Si attiva automaticamente alla prima
# apertura di Claude Desktop.
POSTINST
chmod 755 "${DEBROOT}/DEBIAN/postinst"

# ── Script pre-rimozione ─────────────────────────────────────────────────────
cat > "${DEBROOT}/DEBIAN/prerm" << 'PRERM'
#!/bin/bash
set -e
# Nessuna azione speciale richiesta prima della rimozione
exit 0
PRERM
chmod 755 "${DEBROOT}/DEBIAN/prerm"

# =============================================================================
# STEP 12 — Build del .deb
# =============================================================================
info "Costruzione pacchetto .deb..."
DEB_FILE="${WORKDIR}/../${PACKAGE_NAME}_${DEB_VERSION}_${ARCH}.deb"

dpkg-deb --build "${DEBROOT}" "${DEB_FILE}" \
    || die "dpkg-deb build fallito"

# Verifica che il .deb sia stato creato correttamente
[[ -f "${DEB_FILE}" ]] || die "File .deb non trovato dopo la build"
DEB_SIZE=$(stat -c%s "${DEB_FILE}")
[[ "${DEB_SIZE}" -gt 100000 ]] || die "File .deb troppo piccolo: ${DEB_SIZE} bytes"

# =============================================================================
# STEP 13 — Pulizia file temporanei
# =============================================================================
info "Pulizia file temporanei..."
rm -rf "${WORKDIR}"

# =============================================================================
# COMPLETATO
# =============================================================================
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Build completata con successo!${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Pacchetto:  ${BLUE}${DEB_FILE}${NC}"
echo -e "  Dimensione: $(( DEB_SIZE / 1024 / 1024 )) MB"
echo ""
echo -e "  Per installare:"
echo -e "  ${YELLOW}sudo dpkg -i ${DEB_FILE}${NC}"
echo -e "  ${YELLOW}sudo apt-get install -f${NC}  # risolve eventuali dipendenze"
echo ""
echo -e "  Per disinstallare:"
echo -e "  ${YELLOW}sudo dpkg -r claude-desktop${NC}"
echo ""
