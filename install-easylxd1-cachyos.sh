#!/bin/bash
# ============================================================
# Easy LXD UI Installer (CachyOS / Arch Linux 版)
#
# ソース: https://github.com/hirogura/cachyos-easylxd (CachyOS 専用プロジェクト)
# 元プロジェクト: https://github.com/hirogura/easylxd (Ubuntu + snap 前提)
# を CachyOS 向けに直接改変したもの。
#
# Ubuntu 版との差分:
#   - LXD は snap ではなく pacman で導入 (cachyos-extra-v3/extra の lxd)
#   - snap への PATH 参照 (/snap/bin) を排除
#   - systemd ユニットは lxd.socket / lxd.service 前提
#     (ArchWiki: lxd.socket を enable。自動起動には lxd.service も enable)
#   - /etc/subuid・/etc/subgid の root マッピングを保証 (非特権コンテナ用)
#   - firewalld が有効な環境への最低限の配慮 (ufw 対応は維持)
#   - npm 12+ の install scripts ブロック対策 (node-pty 承認＋ビルド確認)
#   - UI の「サーバアップデート」は lxd-setup.sh --skip-pool + 本体更新として
#     CachyOS リポジトリを直接参照。「サーバ再起動」は easy-lxd の再起動
#     (systemd 共通。サービス定義の After= のみ CachyOS 化)
#   - KonomiTV の px4_drv 導入は tuner-lxd-cachyos.sh (ソース + DKMS) に対応
#     (KONOMITV-CACHYOS.md。コンテナ内操作は Ubuntu コンテナなので変更なし)
#
# 使い方:
#   sudo bash /opt/easy-lxd/install-easylxd1-cachyos.sh
# ============================================================
set -euo pipefail

INSTALL_DIR="/opt/easy-lxd"
PORT=3329
REPO_URL="https://github.com/hirogura/cachyos-easylxd"
GIT_BRANCH="main"

echo "=== Easy LXD UI Installer (CachyOS版) ==="
echo ""

# --- root 必須 ---
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: root 権限が必要です。sudo で実行してください。"
  exit 1
fi

# --- OS 確認 ---
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "OS: ${PRETTY_NAME:-$ID}"
  case "${ID_LIKE:-} ${ID:-}" in
    *arch*)
      echo "Arch 系として検出しました。続行します。"
      ;;
    *)
      echo "WARNING: Arch/CachyOS 以外の環境です。pacman が必要なので続行できるか不明ですが試行します。"
      ;;
  esac
fi
command -v pacman &>/dev/null || { echo "ERROR: pacman が見つかりません。CachyOS/Arch 系でのみ動作します。"; exit 1; }

# --- pacman 依存パッケージ ---
# lxd 本体 / Node.js / ビルドツール / GPU・チューナー検出用 / Tailscale を一括導入。
echo "依存パッケージを確認・インストール中 (pacman)..."
pacman -Sy --needed --noconfirm \
  curl git nodejs npm base-devel python3 \
  pciutils usbutils jq procps-ng \
  tailscale lxd dkms \
  || { echo "ERROR: pacman での依存パッケージ導入に失敗しました"; exit 1; }

# カーネルヘッダ (px4_drv の DKMS ビルド時に必要。無くても本体動作には支障なし)
KVER="$(uname -r)"
if [[ "$KVER" == *cachyos* ]]; then
  pacman -Sy --needed --noconfirm linux-cachyos-headers \
    || echo "WARNING: linux-cachyos-headers を導入できませんでした (px4_drv の DKMS 時に手動導入してください)"
else
  pacman -Sy --needed --noconfirm linux-headers \
    || echo "WARNING: linux-headers を導入できませんでした (px4_drv の DKMS 時に手動導入してください)"
fi

# --- Node.js / npm ---
command -v node &>/dev/null || { echo "ERROR: node が見つかりません (pacman の nodejs を確認してください)"; exit 1; }
command -v npm &>/dev/null || { echo "ERROR: npm が見つかりません (pacman の npm を確認してください)"; exit 1; }
NODE_PATH="$(command -v node)"
echo "Node: $(node -v) ($NODE_PATH)"
echo "npm: $(npm -v)"

# --- tailscale (Serveに必要) ---
command -v tailscale &>/dev/null || { echo "ERROR: tailscale is not installed"; exit 1; }
if ! tailscale status &>/dev/null; then
  echo "WARNING: tailscale にログインしていません。'tailscale up' でログインしてから Serve 設定を確認してください。"
fi

# --- 既存停止 ---
if pgrep -f "node.*easy-lxd/server.js" &>/dev/null; then
  echo "既存の Easy LXD を停止します..."
  pkill -f "node.*easy-lxd/server.js" 2>/dev/null || true
  sleep 1
fi

# --- ディレクトリ ---
mkdir -p "$INSTALL_DIR"

# --- /opt/lxd-data ディレクトリ作成と権限設定 ---
if [ ! -d "/opt/lxd-data" ]; then
  echo "/opt/lxd-data ディレクトリを作成します..."
  mkdir -p /opt/lxd-data
fi

# raw.idmap "both 1000 1000" はコンテナ内 UID/GID 1000 をシフトせずホストにそのまま通す設定。
# ユーザー名の存在有無に依存せず、数値UID/GIDで直接 chown することで確実に権限を合わせる。
echo "/opt/lxd-data の権限を UID/GID 1000 に設定します..."
chown -R 1000:1000 /opt/lxd-data
chmod -R 775 /opt/lxd-data

# --- GitHub からソースを取得 ---
echo "GitHub からソースを取得中..."
echo "  URL: ${REPO_URL}/archive/refs/heads/${GIT_BRANCH}.tar.gz"
TMP_TAR="$(mktemp)"
curl -fsSL -o "$TMP_TAR" "${REPO_URL}/archive/refs/heads/${GIT_BRANCH}.tar.gz"
# 展開前に正規のアプリ内容か検証する
# (リポジトリ未push時などの不完全な tarball による破壊を防ぐ)。
if ! tar -tzf "$TMP_TAR" | grep -q "server.js"; then
  echo "ERROR: tarball に server.js が含まれていません。"
  echo "リポジトリ (${REPO_URL}) の push 状態を確認してください。"
  rm -f "$TMP_TAR"
  exit 1
fi
mkdir -p "$INSTALL_DIR"
tar -xzf "$TMP_TAR" --strip-components=1 -C "$INSTALL_DIR"
rm -f "$TMP_TAR"
echo "GitHub からの取得が完了しました"

# --- 取得ファイルの確認 ---
for f in server.js package.json public/index.html lxd-setup.sh; do
  if [ ! -f "$INSTALL_DIR/$f" ]; then
    echo "ERROR: $INSTALL_DIR/$f が取得できませんでした。リポジトリの公開状態を確認してください。"
    exit 1
  fi
done
echo "ソースファイルの確認 OK"

# --- LXD セットアップ (冪等。未導入なら導入、未初期化なら初期化し、
#     ストレージプールと default プロファイルの root ディスクを必ず保証する) ---
echo "LXD セットアップを実行します..."
bash "$INSTALL_DIR/lxd-setup.sh"
command -v lxc &>/dev/null || { echo "ERROR: LXD のセットアップに失敗しました (lxc コマンドが見つかりません)"; exit 1; }
echo "LXD: $(lxc version 2>/dev/null || lxc --version)"

# --- npm パッケージ (WebSocket + PTY) ---
echo "npm パッケージをインストール中..."
cd "$INSTALL_DIR"
npm install
# npm 12+ では install scripts がデフォルトでブロックされるため、
# node-pty (ターミナル用ネイティブモジュール) を明示的に承認してビルドする。
# 承認状態は package.json の allowScripts に保存される。
npm install-scripts approve node-pty 2>/dev/null || true
npm rebuild node-pty 2>/dev/null || npm install --build-from-source node-pty || true
if [ ! -f "$INSTALL_DIR/node_modules/node-pty/build/Release/pty.node" ]; then
  echo "ERROR: node-pty のネイティブビルドに失敗しました。"
  echo "base-devel / python3 が導入されているか確認し、以下で手動ビルドしてください:"
  echo "  cd ${INSTALL_DIR} && npm install-scripts approve node-pty && npm rebuild node-pty"
  exit 1
fi
echo "npm パッケージ インストール完了 (node-pty ビルド確認 OK)"

# --- systemd ---
# CachyOS/Arch では lxd が socket activation のため、After に lxd.socket を含める。
SERVICE_FILE="/etc/systemd/system/easy-lxd.service"
cat > "$SERVICE_FILE" << SVCEOF
[Unit]
Description=Easy LXD UI
After=network-online.target lxd.socket lxd.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${NODE_PATH} ${INSTALL_DIR}/server.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable easy-lxd
systemctl restart easy-lxd
echo "Systemd サービスをインストールし起動しました"

# --- Tailscale Serve (HTTPS / Tailnet限定で公開、LANには公開しない) ---
echo ""
echo "Tailscale Serve を設定中..."
TAILSCALE_PORT=$PORT
# 冪等性確保のため一旦offにしてから再登録 (tailscale serve reset は使わない)
tailscale serve --https="${TAILSCALE_PORT}" off >/dev/null 2>&1 || true
tailscale serve --bg --https="${TAILSCALE_PORT}" "http://127.0.0.1:${PORT}"

TAILSCALE_DOMAIN=""
if command -v jq &>/dev/null; then
  TAILSCALE_DOMAIN=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
else
  TAILSCALE_DOMAIN=$(tailscale status --json | python3 -c "import json,sys;print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null || echo "")
fi

if [ -n "$TAILSCALE_DOMAIN" ]; then
  echo "Tailscale Serve 設定完了: https://${TAILSCALE_DOMAIN}:${TAILSCALE_PORT}"
else
  echo "WARNING: Tailscale ドメインの取得に失敗しました。'tailscale serve status' で確認してください。"
fi

echo ""
echo "=== インストール完了 (CachyOS版) ==="
echo "  Node:  ${NODE_PATH} ($(${NODE_PATH} -v))"
if [ -n "$TAILSCALE_DOMAIN" ]; then
  echo "  URL:   https://${TAILSCALE_DOMAIN}:${TAILSCALE_PORT}  (Tailnet内のみ)"
else
  echo "  URL:   tailscale serve status で確認してください"
fi
echo "  Dir:   ${INSTALL_DIR}"
echo ""
echo "注意:"
echo "  - LXD は pacman 版 (snap 不使用) です。"
echo "  - UI の「サーバアップデート」は lxd-setup.sh --skip-pool + 本体更新として動作します。"
echo "    「サーバ再起動」は easy-lxd サービスの再起動です。"
echo "  - KonomiTV の px4_drv 導入は UI の「px4_drvインストール」ボタンで実行できます。"
echo "    (tuner-lxd-cachyos.sh を使用。詳細は ${INSTALL_DIR}/KONOMITV-CACHYOS.md)"
echo ""
