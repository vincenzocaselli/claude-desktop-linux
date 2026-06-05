#!/usr/bin/env bash
# =============================================================================
# build-claude-desktop-arch.sh
#
# Costruisce un pacchetto Arch Linux (.pkg.tar.zst) di Claude Desktop
# scaricando il pacchetto NuGet ufficiale di Anthropic e ripatchandolo per
# Linux. Niente repository di terze parti.
#
# Output: ./claude-desktop-<versione>-1-x86_64.pkg.tar.zst
# Install: sudo pacman -U claude-desktop-*.pkg.tar.zst
#
# Differenze principali vs versione Debian:
# - Nomi dipendenze Arch (nss, gtk3, ...) anziché Debian (libnss3, libgtk-3-0)
# - PKGBUILD anziché DEBIAN/control
# - Struttura output dentro pkgdir/ anziché debroot/
# - Build via makepkg anziché dpkg-deb
#
# Pre-requisiti: base-devel, nodejs, npm, p7zip, curl, icoutils
#
# Autore originale: progetto pubblico generato via Claude
# =============================================================================
set -euo pipefail

# ── Helper di logging ────────────────────────────────────────────────────────
info() { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
die()  { printf '\033[1;31m[ERR]\033[0m   %s\n' "$*" >&2; exit 1; }

# ── Verifica prerequisiti Arch ───────────────────────────────────────────────
[[ "$(uname -s)" == "Linux" ]] || die "Questo script gira solo su Linux"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ "${ID:-}" != "arch" && "${ID_LIKE:-}" != *"arch"* ]]; then
        warn "Sistema rilevato: ${PRETTY_NAME:-sconosciuto}"
        warn "Questo script è pensato per Arch Linux. Procedo comunque."
    fi
fi

REQUIRED_CMDS=(curl 7z npm node makepkg fakeroot)
for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "${cmd}" >/dev/null 2>&1 \
        || die "Comando '${cmd}' non trovato. Installa con: sudo pacman -S base-devel nodejs npm p7zip"
done

# Comandi opzionali (non bloccanti)
command -v wrestool >/dev/null 2>&1 || warn "wrestool non installato (icoutils): icone potrebbero non venire estratte"
command -v icotool  >/dev/null 2>&1 || warn "icotool non installato (icoutils): icone potrebbero non venire estratte"

# ── Sorgenti ufficiali Anthropic ─────────────────────────────────────────────
RELEASES_URL="https://downloads.claude.ai/releases/win32/x64/RELEASES"
NUPKG_BASE_URL="https://downloads.claude.ai/releases/win32/x64"

PACKAGE_NAME="claude-desktop"
ARCH="x86_64"
PKGREL="1"  # release del pacchetto, va incrementato se rifai per stessa versione

# ── Directory di lavoro ──────────────────────────────────────────────────────
WORKDIR="$(pwd)/claude-arch-build"
CACHEDIR="$(pwd)/claude-build-cache"
PKGDIR="${WORKDIR}/pkg"

info "Pulizia directory di lavoro..."
rm -rf "${WORKDIR}"
mkdir -p "${WORKDIR}"
mkdir -p "${CACHEDIR}"

# =============================================================================
# STEP 1 — Rilevamento ultima versione
# =============================================================================
info "Ricerca ultima versione Claude Desktop da RELEASES..."
CLAUDE_DOWNLOAD_URL=""
LATEST_VERSION=""

LATEST_LINE=$(curl -sL --max-time 30 "${RELEASES_URL}" 2>/dev/null \
    | grep -i "\-full\.nupkg" | tail -1 | tr -d '\r')

if [[ -n "${LATEST_LINE}" ]]; then
    LATEST_NUPKG_NAME=$(echo "${LATEST_LINE}" | awk '{print $2}')
    LATEST_VERSION=$(echo "${LATEST_NUPKG_NAME}" | grep -oP '\d+\.\d+\.\d+(?=-full)')

    if [[ -n "${LATEST_VERSION}" && -n "${LATEST_NUPKG_NAME}" ]]; then
        CANDIDATE="${NUPKG_BASE_URL}/${LATEST_NUPKG_NAME}"
        HTTP_CODE=$(curl -sI --max-time 15 "${CANDIDATE}" 2>/dev/null \
            | grep -i "^http/" | tail -1 | awk '{print $2}')
        if [[ "${HTTP_CODE}" == "200" ]]; then
            CLAUDE_DOWNLOAD_URL="${CANDIDATE}"
            ok "Ultima versione: ${LATEST_VERSION}"
        fi
    fi
fi

[[ -z "${CLAUDE_DOWNLOAD_URL}" ]] && die "Rilevamento versione fallito"

PKG_VERSION="${LATEST_VERSION}"
CLAUDE_VERSION="${LATEST_VERSION}"

# =============================================================================
# STEP 2 — Download nupkg con cache
# =============================================================================
CACHED_NUPKG="${CACHEDIR}/AnthropicClaude-full.nupkg"
CACHED_VERSION_FILE="${CACHEDIR}/cached-version.txt"
CACHED_VERSION=""
[[ -f "${CACHED_VERSION_FILE}" ]] && \
    CACHED_VERSION=$(cat "${CACHED_VERSION_FILE}" | tr -d '\r\n ')

if [[ -f "${CACHED_NUPKG}" && -n "${CACHED_VERSION}" && \
      "${CACHED_VERSION}" == "${LATEST_VERSION}" ]]; then
    ok "Cache aggiornata: versione ${CACHED_VERSION} già scaricata"
    cp "${CACHED_NUPKG}" "${WORKDIR}/AnthropicClaude-full.nupkg"
else
    info "Download nupkg da ${CLAUDE_DOWNLOAD_URL}..."
    curl -L --progress-bar \
        -o "${WORKDIR}/AnthropicClaude-full.nupkg" \
        "${CLAUDE_DOWNLOAD_URL}" \
        || die "Download fallito"

    NUPKG_SIZE=$(stat -c%s "${WORKDIR}/AnthropicClaude-full.nupkg")
    [[ "${NUPKG_SIZE}" -gt 10000000 ]] || die "File troppo piccolo (${NUPKG_SIZE} bytes)"

    NUPKG_MAGIC=$(head -c 4 "${WORKDIR}/AnthropicClaude-full.nupkg" \
        | od -A n -t x1 | tr -d ' \n')
    [[ "${NUPKG_MAGIC}" == "504b0304" ]] || die "Non è un NuGet valido (magic: ${NUPKG_MAGIC})"

    ok "Download completato ($(( NUPKG_SIZE / 1024 / 1024 )) MB)"

    cp "${WORKDIR}/AnthropicClaude-full.nupkg" "${CACHED_NUPKG}"
    printf '%s\n' "${LATEST_VERSION}" > "${CACHED_VERSION_FILE}"
fi

# =============================================================================
# STEP 3 — Estrazione del nupkg
# =============================================================================
info "Estrazione nupkg..."
mkdir -p "${WORKDIR}/nupkg-contents"
7z x -y "${WORKDIR}/AnthropicClaude-full.nupkg" \
    -o"${WORKDIR}/nupkg-contents" >/dev/null 2>&1 \
    || die "Estrazione nupkg fallita"

APP_ASAR=$(find "${WORKDIR}/nupkg-contents" -name "app.asar" -type f | head -1)
[[ -z "${APP_ASAR}" ]] && die "app.asar non trovato nel nupkg"

cp "${APP_ASAR}" "${WORKDIR}/app.asar"

APP_ASAR_UNPACKED=$(find "${WORKDIR}/nupkg-contents" -name "app.asar.unpacked" -type d | head -1)
if [[ -n "${APP_ASAR_UNPACKED}" ]]; then
    cp -r "${APP_ASAR_UNPACKED}" "${WORKDIR}/app.asar.unpacked"
fi

RESOURCES_SRC=$(find "${WORKDIR}/nupkg-contents" -type d -name "resources" | head -1)
[[ -n "${RESOURCES_SRC}" ]] && cp -r "${RESOURCES_SRC}" "${WORKDIR}/resources"

ok "Estrazione completata"

# =============================================================================
# STEP 4 — Estrazione asar e patching
# =============================================================================
info "Setup tooling locale (@electron/asar)..."
mkdir -p "${WORKDIR}/npm-tools"
# Pin a versione compatibile con Node 18 (la latest richiede Node 22+ e usa
# "import with {type:'json'}" non supportato). @electron/asar@3.2.x è
# l'ultima serie compatibile con Node 18+. Fallback su 'asar' deprecato.
npm install --prefix "${WORKDIR}/npm-tools" '@electron/asar@~3.2.0' >/dev/null 2>&1 \
    || npm install --prefix "${WORKDIR}/npm-tools" 'asar@~3.2.0' >/dev/null 2>&1 \
    || die "Installazione asar fallita"
ASAR="${WORKDIR}/npm-tools/node_modules/.bin/asar"

info "Estrazione app.asar..."
"${ASAR}" extract "${WORKDIR}/app.asar" "${WORKDIR}/app-extracted" \
    || die "Estrazione asar fallita"

# ── Stub @ant/claude-native ───────────────────────────────────────────────
info "Scrittura stub claude-native per Linux..."
NATIVE_DIR="${WORKDIR}/app-extracted/node_modules/@ant/claude-native"
mkdir -p "${NATIVE_DIR}"
cat > "${NATIVE_DIR}/package.json" << 'PKG'
{"name":"@ant/claude-native","version":"1.0.0","main":"index.js"}
PKG
cat > "${NATIVE_DIR}/index.js" << 'STUB'
'use strict';
const KeyboardKey={A:0,B:1,C:2,D:3,E:4,F:5,G:6,H:7,I:8,J:9,K:10,L:11,M:12,N:13,O:14,P:15,Q:16,R:17,S:18,T:19,U:20,V:21,W:22,X:23,Y:24,Z:25,N0:26,N1:27,N2:28,N3:29,N4:30,N5:31,N6:32,N7:33,N8:34,N9:35,F1:36,F2:37,F3:38,F4:39,F5:40,F6:41,F7:42,F8:43,F9:44,F10:45,F11:46,F12:47,Space:48,Enter:49,Tab:50,Backspace:51,Delete:52,Escape:53,Home:54,End:55,PageUp:56,PageDown:57,ArrowLeft:58,ArrowRight:59,ArrowUp:60,ArrowDown:61,Shift:62,Control:63,Alt:64,Meta:65};
const AuthRequest={isAvailable:()=>false,start:(_u,cb)=>cb&&cb(null,new Error('N/A Linux')),cancel:()=>{}};
module.exports={KeyboardKey,AuthRequest,getWindowsWithSameApp:()=>[],getMonitorList:()=>[],getMouseLocation:()=>({x:0,y:0}),getTotalMemory:()=>4*1024*1024*1024,getWindowTitle:()=>'',moveMouseTo:()=>{},simulateKey:()=>{},screenCapture:()=>null,setGlobalShortcut:()=>true,unsetGlobalShortcut:()=>{},getSystemTheme:()=>'dark',onWindowFocusChanged:()=>{},getResourcesPath:()=>'/usr/lib/claude-desktop'};
STUB

# ── Frame fix wrapper ──────────────────────────────────────────────────────
info "Scrittura frame-fix-wrapper.js..."
# =============================================================================
# REFACTORING: i 3 file JS (wrapper, entry, update-checker) vengono scritti
# UNA SOLA VOLTA in ${WORKDIR}/patches/. Poi:
#   - Vengono copiati in app-extracted/ per il primo packaging
#   - Vengono inclusi nel pacchetto come /usr/lib/claude-desktop/patches/
#     così claude-update --upgrade può ri-applicarli identici dopo
#     aver estratto il nuovo asar di una versione futura.
# Questo evita drift tra "versione build" e "versione upgrade" dei file.
# =============================================================================
mkdir -p "${WORKDIR}/patches"
cat > "${WORKDIR}/patches/frame-fix-wrapper.js" << 'FRAMEWRAP'
'use strict';
const Module = require('module');
const originalLoad = Module._load;

let _appVersion = null;
function getAppVersion() {
  if (_appVersion !== null) return _appVersion;
  try { _appVersion = require('./package.json').version || ''; }
  catch (e) { _appVersion = ''; }
  return _appVersion;
}

function applyVersionToTitle(win) {
  if (!win || typeof win.getTitle !== 'function') return;
  const version = getAppVersion();
  if (!version) return;
  const suffix = ' — v' + version;
  const updateTitle = () => {
    try {
      const current = win.getTitle();
      if (current && !current.endsWith(suffix)) {
        const cleaned = current.replace(/ — v\d+\.\d+\.\d+$/, '');
        win.setTitle(cleaned + suffix);
      }
    } catch (e) {}
  };
  updateTitle();
  try { win.on('page-title-updated', () => setTimeout(updateTitle, 0)); } catch (e) {}
  let attempts = 0;
  const interval = setInterval(() => {
    updateTitle();
    if (++attempts >= 30) clearInterval(interval);
  }, 1000);
}

function applyVisibilityFixes(win) {
  if (!win) return;
  try {
    if (typeof win.setMenuBarVisibility === 'function') win.setMenuBarVisibility(true);
    if (typeof win.setAutoHideMenuBar === 'function') win.setAutoHideMenuBar(false);
    applyVersionToTitle(win);
  } catch (e) {}
}

function makePatchedClass(Original) {
  class Patched extends Original {
    constructor(opts = {}) {
      const patchedOpts = Object.assign({}, opts, {
        frame: true,
        titleBarStyle: 'default',
        autoHideMenuBar: false,
      });
      delete patchedOpts.titleBarOverlay;
      super(patchedOpts);
      applyVisibilityFixes(this);
    }
  }
  Object.getOwnPropertyNames(Original).forEach((p) => {
    if (!['length', 'name', 'prototype'].includes(p)) {
      try { Patched[p] = Original[p]; } catch (e) {}
    }
  });
  return Patched;
}

Module._load = function(request, parent, isMain) {
  const result = originalLoad.apply(this, arguments);
  if (request === 'electron' && result && !result.__framefix_patched) {
    ['BrowserWindow', 'BaseWindow'].forEach((cls) => {
      if (result[cls]) {
        const Patched = makePatchedClass(result[cls]);
        try {
          Object.defineProperty(result, cls, {
            value: Patched, writable: true, configurable: true,
          });
        } catch (e) {
          // Proxy fallback se defineProperty fallisce
          try {
            const handler = {
              get(target, prop) {
                if (prop === cls) return Patched;
                return Reflect.get(target, prop);
              },
            };
            // Non possiamo proxare result direttamente, ma il listener sotto basta
          } catch (e2) {}
        }
      }
    });
    if (result.app && typeof result.app.on === 'function') {
      result.app.on('browser-window-created', (event, win) => {
        applyVisibilityFixes(win);
        win.on('show', () => applyVisibilityFixes(win));
        win.on('ready-to-show', () => applyVisibilityFixes(win));
      });
    }
    try {
      Object.defineProperty(result, '__framefix_patched', {
        value: true, writable: false, configurable: false, enumerable: false,
      });
    } catch (e) {}
  }
  return result;
};
FRAMEWRAP

# ── Patch Claude Code (CCD) per supporto Linux ──────────────────────────────
info "Patch Claude Code (CCD) per supporto Linux..."
VITE_INDEX="${WORKDIR}/app-extracted/.vite/build/index.js"
if [[ -f "${VITE_INDEX}" ]]; then
    PATCH_SCRIPT="${WORKDIR}/patch-ccd.js"
    cat > "${PATCH_SCRIPT}" << 'PATCHJS'
'use strict';
const fs = require('fs');
const path = process.argv[2];
if (!path) process.exit(1);
let src;
try { src = fs.readFileSync(path, 'utf8'); } catch (e) { process.exit(1); }
// Pattern regex-based: resiste a rename di variabili minificate.
// Cattura la lettera della variabile via backreference e la riusa.
const winRegex = /if\(process\.platform==="win32"\)return\s+([A-Za-z_])==="arm64"\?"win32-arm64":"win32-x64";/g;

// Check idempotenza
const winCount = (src.match(/if\(process\.platform==="win32"\)return\s+[A-Za-z_]==="arm64"\?"win32-arm64":"win32-x64";/g) || []).length;
const linuxCount = (src.match(/if\(process\.platform==="linux"\)return\s+[A-Za-z_]==="arm64"\?"linux-arm64":"linux-x64";/g) || []).length;
if (winCount > 0 && linuxCount >= winCount) {
    console.log('[OK] Già patchato');
    process.exit(0);
}

let count = 0;
let lastVar = null;
const newSrc = src.replace(winRegex, (match, varName) => {
    count++;
    lastVar = varName;
    return match +
        'if(process.platform==="linux")return ' + varName +
        '==="arm64"?"linux-arm64":"linux-x64";';
});
if (count === 0) {
    console.error('[WARN] Pattern getHostPlatform win32 non trovato.');
    process.exit(0);
}
fs.writeFileSync(path, newSrc, 'utf8');
console.log('[OK] Patch CCD applicata (' + count + ' occorrenze, var=' + lastVar + ')');
PATCHJS
    node "${PATCH_SCRIPT}" "${VITE_INDEX}" || warn "Patch CCD fallita"
fi

# ── update-checker.js (polling in-app + tray icon) ──────────────────────────
info "Scrittura update-checker.js..."
cat > "${WORKDIR}/patches/update-checker.js" << 'UPDATER_JS'
'use strict';
const { app, Notification, dialog, shell, Menu, Tray, BrowserWindow } = require('electron');
const { spawn } = require('child_process');
const https = require('https');
const fs = require('fs');

const RELEASES_URL = 'https://downloads.claude.ai/releases/win32/x64/RELEASES';
const CHECK_INTERVAL_MS = 60 * 60 * 1000;
const FIRST_CHECK_DELAY_MS = 5 * 1000;
const INSTALLED_VERSION_PATH = '/usr/lib/claude-desktop/.installed-version';

let lastNotifiedVersion = null;
let lastKnownRemote = null;
let lastCheckTime = null;
let isChecking = false;
let trayInstance = null;

function log(...args) { console.log('[update-checker]', ...args); }

function getInstalledVersion() {
    try {
        if (fs.existsSync(INSTALLED_VERSION_PATH)) {
            return fs.readFileSync(INSTALLED_VERSION_PATH, 'utf8').trim();
        }
    } catch (e) {}
    try { return require('./package.json').version || '0.0.0'; }
    catch (e) { return '0.0.0'; }
}

function fetchLatestVersion() {
    return new Promise((resolve, reject) => {
        const req = https.get(RELEASES_URL, { timeout: 15000 }, (res) => {
            if (res.statusCode !== 200) return reject(new Error('HTTP ' + res.statusCode));
            let data = '';
            res.setEncoding('utf8');
            res.on('data', (c) => data += c);
            res.on('end', () => {
                const lines = data.split(/\r?\n/).filter((l) => l.includes('-full.nupkg'));
                if (lines.length === 0) return reject(new Error('Nessuna riga -full.nupkg'));
                const last = lines[lines.length - 1].trim().split(/\s+/);
                const nupkgName = last[1];
                const m = nupkgName && nupkgName.match(/(\d+\.\d+\.\d+)-full/);
                if (!m) return reject(new Error('Formato non valido'));
                resolve({ version: m[1], nupkgName });
            });
        });
        req.on('error', reject);
        req.on('timeout', () => { req.destroy(); reject(new Error('Timeout')); });
    });
}

function versionGt(a, b) {
    const pa = a.split('.').map(Number);
    const pb = b.split('.').map(Number);
    for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
        const x = pa[i] || 0, y = pb[i] || 0;
        if (x > y) return true;
        if (x < y) return false;
    }
    return false;
}

function spawnClaudeUpdate(arg) {
    const env = Object.assign({}, process.env);
    const child = spawn('/usr/bin/claude-update', [arg], {
        detached: true, stdio: 'ignore', env: env, cwd: env.HOME || '/tmp',
    });
    child.unref();
}

function notifyUpdateAvailable(currentVer, latestVer) {
    if (lastNotifiedVersion === latestVer) return;
    lastNotifiedVersion = latestVer;
    if (!Notification.isSupported()) return;
    const n = new Notification({
        title: 'Aggiornamento Claude Desktop disponibile',
        body: `Nuova versione: ${latestVer}\nInstallata: ${currentVer}\nClicca per aggiornare.`,
    });
    n.on('click', () => showUpgradeDialog(currentVer, latestVer));
    n.show();
}

function showUpgradeDialog(currentVer, latestVer) {
    const choice = dialog.showMessageBoxSync({
        type: 'question',
        title: 'Aggiornamento Claude Desktop',
        message: `È disponibile la versione ${latestVer}`,
        detail: `Versione installata: ${currentVer}\n\nL'aggiornamento scaricherà il pacchetto ` +
                `da Anthropic (~200 MB), lo patcherà per Linux e lo installerà sul sistema. ` +
                `Ti verrà chiesta la password di amministratore.\n\nClaude verrà riavviato al termine.`,
        buttons: ['Aggiorna ora', 'Più tardi'],
        defaultId: 0, cancelId: 1,
    });
    if (choice === 0) spawnClaudeUpdate('--upgrade');
}

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
            type: 'warning', title: 'Controllo aggiornamenti fallito',
            message: 'Non riesco a contattare l\'endpoint di aggiornamento',
            detail: `Errore: ${errorMsg}\n\nPosso aprirti una chat con Claude su claude.ai con il contesto necessario.`,
            buttons: ['Apri diagnostica', 'Ignora'], defaultId: 0, cancelId: 1,
        });
        if (choice === 0) spawnClaudeUpdate('--diagnose');
    });
    n.show();
}

async function performCheck() {
    if (isChecking) return;
    isChecking = true;
    try {
        const installed = getInstalledVersion();
        const remote = await fetchLatestVersion();
        lastKnownRemote = remote;
        lastCheckTime = new Date();
        if (versionGt(remote.version, installed)) {
            notifyUpdateAvailable(installed, remote.version);
        } else {
            if (lastNotifiedVersion === 'ERROR') lastNotifiedVersion = null;
        }
    } catch (err) {
        log('Check fallito:', err.message);
        notifyEndpointError(err.message);
    } finally { isChecking = false; }
}

async function checkForUpdatesNow() {
    try {
        const remote = await fetchLatestVersion();
        lastKnownRemote = remote;
        lastCheckTime = new Date();
        const installed = getInstalledVersion();
        if (versionGt(remote.version, installed)) {
            notifyUpdateAvailable(installed, remote.version);
        } else if (Notification.isSupported()) {
            new Notification({
                title: 'Claude Desktop è aggiornato',
                body: `Hai la versione più recente (${installed}).`, silent: true,
            }).show();
        }
    } catch (err) { notifyEndpointError(err.message); }
}

async function showVersionInfo() {
    const installed = getInstalledVersion();
    const needsFresh = !lastCheckTime || (Date.now() - lastCheckTime.getTime()) > 5 * 60 * 1000;
    let remote = lastKnownRemote;
    let checkError = null;
    if (needsFresh) {
        try {
            remote = await fetchLatestVersion();
            lastKnownRemote = remote;
            lastCheckTime = new Date();
        } catch (err) { checkError = err.message; }
    }
    if (checkError) {
        const choice = dialog.showMessageBoxSync({
            type: 'warning', title: 'Info versione Claude Desktop',
            message: `Versione installata: ${installed}`,
            detail: `Impossibile verificare aggiornamenti: ${checkError}`,
            buttons: ['Apri diagnostica', 'OK'], defaultId: 1, cancelId: 1,
        });
        if (choice === 0) spawnClaudeUpdate('--diagnose');
        return;
    }
    if (versionGt(remote.version, installed)) {
        showUpgradeDialog(installed, remote.version);
    } else {
        dialog.showMessageBoxSync({
            type: 'info', title: 'Info versione Claude Desktop',
            message: 'Claude Desktop è aggiornato',
            detail: `Versione installata: ${installed}\nUltima disponibile: ${remote.version}`,
            buttons: ['OK'],
        });
    }
}

function toggleMainWindow() {
    try {
        const ws = BrowserWindow.getAllWindows();
        if (!ws || ws.length === 0) return;
        const main = ws.find((w) => w.isVisible()) || ws[0];
        if (main.isVisible() && main.isFocused()) main.hide();
        else { if (!main.isVisible()) main.show(); main.focus(); }
    } catch (e) {}
}

function handleNewWindowHideUntilMenuRemoved(win) {
    try {
        win.hide();
        if (typeof win.setMenu === 'function') win.setMenu(null);
        if (typeof win.setMenuBarVisibility === 'function') win.setMenuBarVisibility(false);
        Menu.setApplicationMenu(null);
        // Polling permanente per rimuovere il menu se l'app lo re-imposta
        setInterval(() => {
            try {
                Menu.setApplicationMenu(null);
                BrowserWindow.getAllWindows().forEach((w) => {
                    try {
                        if (typeof w.setMenu === 'function') w.setMenu(null);
                        if (typeof w.setMenuBarVisibility === 'function') w.setMenuBarVisibility(false);
                    } catch (e) {}
                });
            } catch (e) {}
        }, 200);
        const showWhenReady = () => {
            try {
                Menu.setApplicationMenu(null);
                if (typeof win.setMenu === 'function') win.setMenu(null);
                if (typeof win.setMenuBarVisibility === 'function') win.setMenuBarVisibility(false);
                win.show();
                win.focus();
            } catch (e) {}
        };
        setTimeout(showWhenReady, 5000);
    } catch (e) {
        try { win.show(); } catch (e2) {}
    }
}

function setupTrayIcon() {
    try {
        const iconCandidates = [
            '/usr/share/icons/hicolor/256x256/apps/claude.png',
            '/usr/share/icons/hicolor/128x128/apps/claude.png',
            '/usr/share/icons/hicolor/64x64/apps/claude.png',
            '/usr/share/icons/hicolor/48x48/apps/claude.png',
            '/usr/share/icons/hicolor/32x32/apps/claude.png',
        ];
        let iconPath = null;
        for (const c of iconCandidates) if (fs.existsSync(c)) { iconPath = c; break; }
        if (!iconPath) return;

        trayInstance = new Tray(iconPath);
        trayInstance.setToolTip('Claude Desktop');

        const buildMenu = () => Menu.buildFromTemplate([
            { label: `Claude Desktop v${getInstalledVersion()}`, enabled: false },
            { type: 'separator' },
            { label: 'Mostra/Nascondi finestra', click: toggleMainWindow },
            { type: 'separator' },
            { label: 'Verifica aggiornamenti', click: () => checkForUpdatesNow() },
            { label: 'Info versione e aggiornamenti…', click: () => showVersionInfo() },
            { type: 'separator' },
            { label: 'Esci', click: () => app.quit() },
        ]);
        trayInstance.setContextMenu(buildMenu());
        trayInstance.on('click', toggleMainWindow);
    } catch (e) { log('Tray error:', e.message); }
}

app.whenReady().then(() => {
    Menu.setApplicationMenu(null);
    app.on('browser-window-created', (event, win) => {
        handleNewWindowHideUntilMenuRemoved(win);
    });
    BrowserWindow.getAllWindows().forEach((w) => {
        try {
            if (typeof w.setMenu === 'function') w.setMenu(null);
            if (typeof w.setMenuBarVisibility === 'function') w.setMenuBarVisibility(false);
        } catch (e) {}
    });
    setTimeout(setupTrayIcon, 3000);
    setTimeout(performCheck, FIRST_CHECK_DELAY_MS);
    setInterval(performCheck, CHECK_INTERVAL_MS);
});
UPDATER_JS

# ── frame-fix-entry.js (entry point principale) ─────────────────────────────
info "Scrittura frame-fix-entry.js..."
cat > "${WORKDIR}/patches/frame-fix-entry.js" << 'ENTRY'
'use strict';
require('./frame-fix-wrapper');
try { require('./update-checker'); }
catch (e) { console.error('[update-checker] errore:', e.message); }
require('./.vite/build/index.js');
ENTRY

# ── Verifica e copia i 3 file patch in app-extracted/ ───────────────────────
# Verifica esistenza e non-vuotezza
for f in frame-fix-wrapper.js frame-fix-entry.js update-checker.js; do
    [[ -s "${WORKDIR}/patches/${f}" ]] \
        || die "File patch mancante o vuoto: ${WORKDIR}/patches/${f}"
done
# Verifica sintassi JavaScript (fail-fast)
for f in frame-fix-wrapper.js frame-fix-entry.js update-checker.js; do
    node -c "${WORKDIR}/patches/${f}" 2>/dev/null \
        || die "Errore di sintassi in ${f}"
done
# Copia i file nell'asar estratto per il primo packaging
cp "${WORKDIR}/patches/frame-fix-wrapper.js" "${WORKDIR}/app-extracted/"
cp "${WORKDIR}/patches/frame-fix-entry.js"   "${WORKDIR}/app-extracted/"
cp "${WORKDIR}/patches/update-checker.js"    "${WORKDIR}/app-extracted/"
ok "File patch scritti e copiati in app-extracted (sintassi verificata)"

# ── Modifica package.json: main → frame-fix-entry.js ────────────────────────
PKGJSON="${WORKDIR}/app-extracted/package.json"
node -e "
    const fs=require('fs');
    const p=JSON.parse(fs.readFileSync('${PKGJSON}','utf8'));
    p.main='./frame-fix-entry.js';
    fs.writeFileSync('${PKGJSON}',JSON.stringify(p,null,2));
"

# ── Copia i18n DENTRO l'asar ────────────────────────────────────────────────
info "Copia file i18n dentro asar..."
mkdir -p "${WORKDIR}/app-extracted/resources/i18n"
find "${WORKDIR}/nupkg-contents" -name "*.json" \
    \( -name "*-*.json" -o -name "en-US.json" \) \
    ! -path "*/node_modules/*" ! -name "package*.json" 2>/dev/null \
    | while read -r f; do
    cp "${f}" "${WORKDIR}/app-extracted/resources/i18n/" 2>/dev/null || true
done
[[ -f "${WORKDIR}/app-extracted/resources/i18n/en-US.json" ]] \
    || echo '{}' > "${WORKDIR}/app-extracted/resources/i18n/en-US.json"

# =============================================================================
# STEP 5 — Repack asar
# =============================================================================
info "Repack app.asar..."
"${ASAR}" pack "${WORKDIR}/app-extracted" "${WORKDIR}/app-patched.asar" \
    || die "Repack asar fallito"

# =============================================================================
# STEP 6 — Electron locale
# =============================================================================
info "Installazione Electron locale..."
mkdir -p "${WORKDIR}/electron-install"
npm install --prefix "${WORKDIR}/electron-install" electron@latest >/dev/null 2>&1 \
    || die "Installazione Electron fallita"

ELECTRON_DIST=$(find "${WORKDIR}/electron-install/node_modules/electron" -name "dist" -type d | head -1)
[[ -z "${ELECTRON_DIST}" ]] && die "Electron dist non trovato"

# =============================================================================
# STEP 7 — Estrazione icone
# =============================================================================
info "Estrazione icone..."
mkdir -p "${WORKDIR}/icons-tmp"
ICO_FILE=$(find "${WORKDIR}/nupkg-contents" -name "*.exe" | head -1)
if [[ -n "${ICO_FILE}" ]] && command -v wrestool >/dev/null 2>&1; then
    wrestool -x --output="${WORKDIR}/icons-tmp" "${ICO_FILE}" 2>/dev/null || true
    find "${WORKDIR}/icons-tmp" -name "*.ico" | while read -r ico; do
        icotool -x -o "${WORKDIR}/icons-tmp" "${ico}" 2>/dev/null || true
    done
fi

# =============================================================================
# STEP 8 — Costruzione albero pkg/
# =============================================================================
info "Costruzione albero pacchetto..."
rm -rf "${PKGDIR}"
mkdir -p "${PKGDIR}/usr/lib/claude-desktop"
mkdir -p "${PKGDIR}/usr/bin"
mkdir -p "${PKGDIR}/usr/share/applications"

cp "${WORKDIR}/app-patched.asar" "${PKGDIR}/usr/lib/claude-desktop/app.asar"
[[ -d "${WORKDIR}/app.asar.unpacked" ]] && \
    cp -r "${WORKDIR}/app.asar.unpacked" "${PKGDIR}/usr/lib/claude-desktop/app.asar.unpacked"
[[ -d "${WORKDIR}/resources" ]] && \
    cp -r "${WORKDIR}/resources" "${PKGDIR}/usr/lib/claude-desktop/resources"

# Versione installata (letta da claude-update e dall'app)
echo "${PKG_VERSION}" > "${PKGDIR}/usr/lib/claude-desktop/.installed-version"

# Copia i 3 file patch in /usr/lib/claude-desktop/patches/ così claude-update
# --upgrade può riapplicarli identici quando aggiorna l'asar a versione nuova.
# Single source of truth: evita drift tra build e apply_patches.
mkdir -p "${PKGDIR}/usr/lib/claude-desktop/patches"
cp "${WORKDIR}/patches/frame-fix-wrapper.js" \
   "${PKGDIR}/usr/lib/claude-desktop/patches/"
cp "${WORKDIR}/patches/frame-fix-entry.js"   \
   "${PKGDIR}/usr/lib/claude-desktop/patches/"
cp "${WORKDIR}/patches/update-checker.js"    \
   "${PKGDIR}/usr/lib/claude-desktop/patches/"
ok "Patch files installati in /usr/lib/claude-desktop/patches/"

# Electron dist
mkdir -p "${PKGDIR}/usr/lib/claude-desktop/electron-dist"
cp -r "${ELECTRON_DIST}"/* "${PKGDIR}/usr/lib/claude-desktop/electron-dist/"

# chrome-sandbox setuid (richiesto da Electron come root)
SANDBOX="${PKGDIR}/usr/lib/claude-desktop/electron-dist/chrome-sandbox"
[[ -f "${SANDBOX}" ]] && chmod 4755 "${SANDBOX}"

# Launcher
cat > "${PKGDIR}/usr/bin/claude-desktop" << 'LAUNCHER'
#!/bin/sh
exec /usr/lib/claude-desktop/electron-dist/electron \
    /usr/lib/claude-desktop/app.asar \
    --app-path=/usr/lib/claude-desktop "$@"
LAUNCHER
chmod 755 "${PKGDIR}/usr/bin/claude-desktop"

# .desktop file
cat > "${PKGDIR}/usr/share/applications/claude-desktop.desktop" << DESKTOP
[Desktop Entry]
Name=Claude
Comment=Claude AI Assistant by Anthropic
Exec=/usr/bin/claude-desktop %U
Icon=claude
Terminal=false
Type=Application
Categories=Office;Utility;Network;
StartupWMClass=claude
MimeType=x-scheme-handler/claude;
DESKTOP

# Icone
if compgen -G "${WORKDIR}/icons-tmp/*.png" > /dev/null; then
    for size in 16 24 32 48 64 128 256; do
        ICONFILE=$(find "${WORKDIR}/icons-tmp" -name "*${size}x${size}*.png" | head -1)
        if [[ -n "${ICONFILE}" ]]; then
            DEST="${PKGDIR}/usr/share/icons/hicolor/${size}x${size}/apps"
            mkdir -p "${DEST}"
            cp "${ICONFILE}" "${DEST}/claude.png"
        fi
    done
fi

# =============================================================================
# STEP 9 — Script claude-update (worker per upgrade/diagnose/status)
# =============================================================================
info "Scrittura claude-update..."
cat > "${PKGDIR}/usr/bin/claude-update" << 'UPDATER'
#!/usr/bin/env bash
# claude-update — Worker di aggiornamento per Claude Desktop su Arch Linux
RELEASES_URL="https://downloads.claude.ai/releases/win32/x64/RELEASES"
NUPKG_BASE_URL="https://downloads.claude.ai/releases/win32/x64"
UPDATE_DIR="${HOME}/.cache/claude-update"
mkdir -p "${UPDATE_DIR}"

installed_version() {
    if [[ -f /usr/lib/claude-desktop/.installed-version ]]; then
        cat /usr/lib/claude-desktop/.installed-version | tr -d '\r\n '
    else
        pacman -Q claude-desktop 2>/dev/null | awk '{print $2}' | sed 's/-[0-9]*$//' || echo "sconosciuta"
    fi
}

latest_version() {
    local line nupkg ver
    line=$(curl -sL --max-time 15 "${RELEASES_URL}" 2>/dev/null \
        | grep -i "\-full\.nupkg" | tail -1 | tr -d '\r')
    [[ -z "${line}" ]] && return 1
    nupkg=$(echo "${line}" | awk '{print $2}')
    ver=$(echo "${nupkg}" | grep -oP '\d+\.\d+\.\d+(?=-full)')
    [[ -z "${ver}" || -z "${nupkg}" ]] && return 1
    echo "${ver} ${nupkg}"
}

version_gt() {
    [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" != "$1" ]]
}

cmd_status() {
    local installed latest_info latest_ver
    installed=$(installed_version)
    echo "Versione installata: ${installed}"
    latest_info=$(latest_version) || { echo "Versione disponibile: errore"; return 2; }
    latest_ver=$(echo "${latest_info}" | awk '{print $1}')
    echo "Versione disponibile: ${latest_ver}"
    if version_gt "${latest_ver}" "${installed}"; then
        echo "Stato: aggiornamento disponibile"; return 1
    else
        echo "Stato: aggiornata"; return 0
    fi
}

die_gui() {
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="Errore aggiornamento" --text="$1" 2>/dev/null
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send --urgency=critical "Errore aggiornamento Claude" "$1"
    fi
    echo "Errore: $1" >&2; exit 1
}

cmd_upgrade() {
    local latest_ver latest_url nupkg_file
    latest_ver="${CLAUDE_UPDATE_VERSION:-}"
    latest_url="${CLAUDE_UPDATE_URL:-}"

    if [[ -z "${latest_ver}" || -z "${latest_url}" ]]; then
        local info
        info=$(latest_version) || die_gui "Impossibile contattare downloads.claude.ai"
        latest_ver=$(echo "${info}" | awk '{print $1}')
        local nupkg_name
        nupkg_name=$(echo "${info}" | awk '{print $2}')
        latest_url="${NUPKG_BASE_URL}/${nupkg_name}"
    fi

    nupkg_file="${UPDATE_DIR}/AnthropicClaude-${latest_ver}-full.nupkg"
    rm -f "${nupkg_file}"

    if command -v zenity >/dev/null 2>&1; then
        (
            curl -L --silent --show-error --max-time 600 \
                -o "${nupkg_file}" "${latest_url}" 2>/tmp/claude-upgrade-curl.err
            echo "100"
        ) | zenity --progress --pulsate --auto-close --no-cancel \
            --title="Aggiornamento Claude Desktop" \
            --text="Download versione ${latest_ver} in corso..." 2>/dev/null || true
    else
        curl -L --progress-bar --max-time 600 \
            -o "${nupkg_file}" "${latest_url}" \
            || die_gui "Download fallito (curl)"
    fi

    [[ -f "${nupkg_file}" ]] || die_gui "Download fallito: file non creato"

    local nupkg_size
    nupkg_size=$(stat -c%s "${nupkg_file}" 2>/dev/null || echo 0)
    if [[ "${nupkg_size}" -lt 10000000 ]]; then
        local errmsg=""
        [[ -s /tmp/claude-upgrade-curl.err ]] && errmsg=" $(cat /tmp/claude-upgrade-curl.err)"
        rm -f "${nupkg_file}"
        die_gui "Download incompleto (${nupkg_size} bytes).${errmsg}"
    fi

    local magic
    magic=$(head -c 4 "${nupkg_file}" | od -A n -t x1 | tr -d ' \n')
    if [[ "${magic}" != "504b0304" ]]; then
        rm -f "${nupkg_file}"
        die_gui "File scaricato non valido (magic: ${magic})"
    fi

    do_inplace_upgrade "${nupkg_file}" "${latest_ver}" \
        || die_gui "Patch e install fallita. Esegui: bash -x /usr/bin/claude-update --upgrade"

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

do_inplace_upgrade() {
    local nupkg_file="$1"
    local new_version="$2"
    local staging="${UPDATE_DIR}/staging"

    rm -rf "${staging}"
    mkdir -p "${staging}/extract"

    7z x -y "${nupkg_file}" -o"${staging}/extract" >/dev/null 2>&1 || return 1

    local new_asar
    new_asar=$(find "${staging}/extract" -name "app.asar" | head -1)
    [[ -z "${new_asar}" ]] && return 1

    local asar_tool
    asar_tool=$(command -v asar 2>/dev/null \
        || find /usr/lib/claude-desktop -name "asar" -type f 2>/dev/null | head -1)
    if [[ -z "${asar_tool}" ]]; then
        # Pin a versione compatibile con Node 18 (latest richiede Node 22+).
        npm install --prefix "${staging}/npm-tools" '@electron/asar@~3.2.0' >/dev/null 2>&1 \
            || npm install --prefix "${staging}/npm-tools" 'asar@~3.2.0' >/dev/null 2>&1 \
            || return 1
        asar_tool="${staging}/npm-tools/node_modules/.bin/asar"
    fi

    local extracted="${staging}/app-extracted"
    "${asar_tool}" extract "${new_asar}" "${extracted}" || return 1

    apply_patches "${extracted}" "${staging}/extract" || return 1

    "${asar_tool}" pack "${extracted}" "${staging}/app-patched.asar" || return 1

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
            fi && \
            printf '%s\n' '${new_version}' > '${target}/.installed-version'
        " || return 1
    else
        local pw
        pw=$(zenity --password --title="Autenticazione richiesta" 2>/dev/null) || return 1
        echo "${pw}" | sudo -S bash -c "
            cp '${staging}/app-patched.asar' '${target}/app.asar' && \
            if [[ -d '${resources_dir}' ]]; then
                rm -rf '${target}/resources'
                cp -r '${resources_dir}' '${target}/resources'
            fi && \
            printf '%s\n' '${new_version}' > '${target}/.installed-version'
        " || return 1
    fi

    rm -rf "${staging}"
    return 0
}

# Applica le patch necessarie all'asar estratto:
#   - Stub @ant/claude-native (modulo nativo Windows non disponibile su Linux)
#   - I 3 file JS presi da /usr/lib/claude-desktop/patches/ (single source of truth)
#   - File i18n copiati dentro l'asar
#   - Aggiornamento package.json: main = ./frame-fix-entry.js
#   - Patch CCD inline (getHostPlatform) per supporto Linux di Claude Code
apply_patches() {
    local extracted="$1"
    local nupkg_extract="$2"
    local patches_dir="/usr/lib/claude-desktop/patches"

    # 1. Stub @ant/claude-native (modulo nativo Windows)
    local native_dir
    native_dir=$(find "${extracted}" -type d -name "claude-native" | head -1)
    [[ -z "${native_dir}" ]] && native_dir="${extracted}/node_modules/@ant/claude-native"
    mkdir -p "${native_dir}"
    cat > "${native_dir}/package.json" <<'PKG'
{"name":"@ant/claude-native","version":"1.0.0","main":"index.js"}
PKG
    cat > "${native_dir}/index.js" <<'STUB'
'use strict';
const KeyboardKey={A:0,B:1,C:2,D:3,E:4,F:5,G:6,H:7,I:8,J:9,K:10,L:11,M:12,N:13,O:14,P:15,Q:16,R:17,S:18,T:19,U:20,V:21,W:22,X:23,Y:24,Z:25};
const AuthRequest={isAvailable:()=>false,start:(_u,cb)=>cb&&cb(null,new Error('N/A')),cancel:()=>{}};
module.exports={KeyboardKey,AuthRequest,getWindowsWithSameApp:()=>[],getMonitorList:()=>[],getMouseLocation:()=>({x:0,y:0}),getTotalMemory:()=>4*1024*1024*1024,getWindowTitle:()=>'',moveMouseTo:()=>{},simulateKey:()=>{},screenCapture:()=>null,setGlobalShortcut:()=>true,unsetGlobalShortcut:()=>{},getSystemTheme:()=>'dark',onWindowFocusChanged:()=>{},getResourcesPath:()=>'/usr/lib/claude-desktop'};
STUB

    # 2. File patch da /usr/lib/claude-desktop/patches (installati dal pacchetto)
    if [[ -d "${patches_dir}" ]]; then
        cp "${patches_dir}/frame-fix-wrapper.js" "${extracted}/" || return 1
        cp "${patches_dir}/frame-fix-entry.js"   "${extracted}/" || return 1
        cp "${patches_dir}/update-checker.js"    "${extracted}/" || return 1
    else
        # Fallback per pacchetti vecchi (pre-refactoring): entry minimo
        echo "[WARN] /usr/lib/claude-desktop/patches/ non trovata." >&2
        echo "[WARN] Reinstalla il pacchetto: ./build-claude-desktop-arch.sh && sudo pacman -U claude-desktop-*.pkg.tar.zst" >&2
        cat > "${extracted}/frame-fix-entry.js" <<'ENTRY'
'use strict';
try { require('./frame-fix-wrapper'); } catch (e) {}
try { require('./update-checker'); } catch (e) {}
require('./.vite/build/index.js');
ENTRY
    fi

    # 3. Aggiorna package.json: main → frame-fix-entry.js
    local pkgjson="${extracted}/package.json"
    if [[ -f "${pkgjson}" ]]; then
        node -e "
            const fs=require('fs');
            const p=JSON.parse(fs.readFileSync('${pkgjson}','utf8'));
            p.main='./frame-fix-entry.js';
            fs.writeFileSync('${pkgjson}',JSON.stringify(p,null,2));
        " 2>/dev/null || true
    fi

    # 4. Copia i file i18n dentro l'asar
    mkdir -p "${extracted}/resources/i18n"
    find "${nupkg_extract}" -name "*-*.json" \
        ! -path "*/node_modules/*" ! -name "package*.json" 2>/dev/null \
        | while read -r f; do
        cp "${f}" "${extracted}/resources/i18n/" 2>/dev/null || true
    done
    [[ -f "${extracted}/resources/i18n/en-US.json" ]] \
        || echo '{}' > "${extracted}/resources/i18n/en-US.json"

    # 5. Patch Claude Code (CCD) per supporto Linux.
    # Pattern regex-based per resistere a rename di variabili minificate.
    local vite_index="${extracted}/.vite/build/index.js"
    if [[ -f "${vite_index}" ]]; then
        local staging_dir="$(dirname "${extracted}")"
        local patch_js="${staging_dir}/patch-ccd.js"
        cat > "${patch_js}" << 'PATCHCCD'
'use strict';
const fs = require('fs');
const p = process.argv[2];
if (!p) process.exit(1);
let s;
try { s = fs.readFileSync(p, 'utf8'); } catch (e) { process.exit(1); }
const winRegex = /if\(process\.platform==="win32"\)return\s+([A-Za-z_])==="arm64"\?"win32-arm64":"win32-x64";/g;
let count = 0;
let lastVar = null;
const out = s.replace(winRegex, (match, varName) => {
    count++;
    lastVar = varName;
    return match +
        'if(process.platform==="linux")return ' + varName +
        '==="arm64"?"linux-arm64":"linux-x64";';
});
if (count > 0) {
    const winCount = (s.match(/if\(process\.platform==="win32"\)return\s+[A-Za-z_]==="arm64"\?"win32-arm64":"win32-x64";/g) || []).length;
    const linuxAlreadyCount = (s.match(/if\(process\.platform==="linux"\)return\s+[A-Za-z_]==="arm64"\?"linux-arm64":"linux-x64";/g) || []).length;
    if (linuxAlreadyCount >= winCount) process.exit(0);
    fs.writeFileSync(p, out, 'utf8');
}
PATCHCCD
        node "${patch_js}" "${vite_index}" 2>/dev/null || true
    fi

    # 6. Verifica sintassi dei 3 file JS prima del repack (fail-fast)
    for jsf in frame-fix-wrapper.js frame-fix-entry.js update-checker.js; do
        if [[ -f "${extracted}/${jsf}" ]]; then
            node -c "${extracted}/${jsf}" 2>/dev/null \
                || { echo "[ERROR] Sintassi non valida: ${jsf}" >&2; return 1; }
        fi
    done

    return 0
}

cmd_diagnose() {
    local installed releases_status
    installed=$(installed_version)
    releases_status=$(curl -sI --max-time 10 "${RELEASES_URL}" 2>/dev/null | head -1 | tr -d '\r')

    local prompt
    prompt=$(cat <<EOF
Il mio sistema di auto-update di Claude Desktop su Arch Linux non funziona più.
Versione installata: ${installed}
URL testato: ${RELEASES_URL}
Risposta HTTP: ${releases_status}

Lo script claude-update legge il file RELEASES Squirrel da:
  ${RELEASES_URL}
e scarica nupkg da:
  ${NUPKG_BASE_URL}/AnthropicClaude-VERSION-full.nupkg

Probabilmente Anthropic ha cambiato il meccanismo. Aiutami a:
1. Verificare nuovo endpoint
2. Aggiornare /usr/bin/claude-update
3. Aggiornare build-claude-desktop-arch.sh
EOF
)
    local encoded
    encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.stdin.read()))" <<< "${prompt}")
    xdg-open "https://claude.ai/new?q=${encoded}" 2>/dev/null \
        || firefox "https://claude.ai/new?q=${encoded}" 2>/dev/null \
        || google-chrome-stable "https://claude.ai/new?q=${encoded}" 2>/dev/null
}

restart_claude() {
    local pids
    pids=$(pgrep -f "electron.*claude-desktop" 2>/dev/null)
    if [[ -n "${pids}" ]]; then
        kill ${pids} 2>/dev/null || true
        for i in 1 2 3 4 5; do
            sleep 1
            pids=$(pgrep -f "electron.*claude-desktop" 2>/dev/null)
            [[ -z "${pids}" ]] && break
        done
        if [[ -n "${pids}" ]]; then
            kill -9 ${pids} 2>/dev/null || true
            sleep 1
        fi
    fi
    if command -v setsid >/dev/null 2>&1; then
        setsid /usr/bin/claude-desktop >/dev/null 2>&1 < /dev/null &
    else
        nohup /usr/bin/claude-desktop >/dev/null 2>&1 < /dev/null &
    fi
    disown 2>/dev/null || true
}

case "${1:---status}" in
    --upgrade)  cmd_upgrade ;;
    --diagnose) cmd_diagnose ;;
    --status)   cmd_status ;;
    *)
        echo "Uso: claude-update [--upgrade|--diagnose|--status]"
        exit 1
        ;;
esac
UPDATER
chmod +x "${PKGDIR}/usr/bin/claude-update"

# =============================================================================
# STEP 10 — PKGBUILD e build via makepkg
# =============================================================================
info "Generazione PKGBUILD..."

# Copia il pkg/ in una directory di staging che makepkg useri come $pkgdir
# Strategia: PKGBUILD usa una funzione package() che copia ${PKGDIR} dentro
# ${pkgdir}/. Mantieni tutto self-contained dentro WORKDIR.
mkdir -p "${WORKDIR}/makepkg-build"
cd "${WORKDIR}/makepkg-build"

# Copia il pkg già pronto qui dentro come "fonte"
cp -r "${PKGDIR}" "${WORKDIR}/makepkg-build/pkg-prebuilt"

cat > PKGBUILD << PKGBUILD_END
# Maintainer: Build locale (nessun maintainer esterno)
pkgname=${PACKAGE_NAME}
pkgver=${PKG_VERSION}
pkgrel=${PKGREL}
pkgdesc="Claude Desktop AI Assistant by Anthropic (build locale ricostruita per Linux)"
arch=('${ARCH}')
url="https://claude.ai"
license=('custom:proprietary')
depends=(
    'nss'
    'gtk3'
    'libxkbcommon'
    'libdrm'
    'mesa'
    'alsa-lib'
    'at-spi2-atk'
    'curl'
    'p7zip'
    'polkit'
    'nodejs'
)
optdepends=(
    'zenity: dialog grafici per upgrade'
    'xdg-utils: apertura URL diagnostica'
    'libnotify: notifiche desktop di aggiornamento'
)
options=('!strip' '!debug')

package() {
    cp -a "\${srcdir}/../pkg-prebuilt/." "\${pkgdir}/"
}
PKGBUILD_END

info "Esecuzione makepkg..."
# --skipchecksums: nessuna source da verificare (usiamo pre-built)
# --nodeps: dipendenze sono per il pacchetto installato, non per il build
# --force: sovrascrivi se esiste già
makepkg --skipchecksums --nodeps --force \
    || die "makepkg fallito"

# Trova il pacchetto generato
PKGFILE=$(ls -1 "${WORKDIR}/makepkg-build"/*.pkg.tar.* 2>/dev/null | head -1)
[[ -z "${PKGFILE}" ]] && die "Pacchetto .pkg.tar.* non generato"

# Sposta in cwd dell'utente
cd "$(dirname "$0")" 2>/dev/null || cd "$(pwd)"
FINAL_PKG="$(pwd)/$(basename "${PKGFILE}")"
cp "${PKGFILE}" "${FINAL_PKG}"

ok ""
ok "=========================================="
ok "Pacchetto creato: ${FINAL_PKG}"
ok "Installa con: sudo pacman -U $(basename "${FINAL_PKG}")"
ok "=========================================="
