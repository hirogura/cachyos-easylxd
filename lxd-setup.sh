#!/bin/bash
set -euo pipefail

# ============================================================
# LXD セットアップスクリプト (CachyOS / Arch Linux 版)
# 元: lxd-setup.sh (Ubuntu + snap 前提) の pacman 移植。
# 何度実行しても安全。既に設定済みの項目はスキップします。
# root で実行してください。
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: root で実行してください。"
  exit 1
fi

LXD_POOL_DIR="/opt/lxd-pool"

# ------------------------------------------------------------
# オプション解析
#   --skip-pool : ストレージプール関連の処理をスキップする。
#                 サーバアップデート時に UI から実行される場合に指定され、
#                 default プールが /opt/lxd-pool 以外の既存環境で
#                 プールの削除・再作成が走ってエラー/データ破壊になるのを防ぐ。
#                 初回インストール時は指定しないため従来通りプールを変更する。
# ------------------------------------------------------------
SKIP_POOL=false
for arg in "$@"; do
  case "$arg" in
    --skip-pool) SKIP_POOL=true ;;
    *)
      echo "ERROR: 不明なオプション: $arg"
      echo "使い方: $0 [--skip-pool]"
      exit 1
      ;;
  esac
done

# ------------------------------------------------------------
# 1. LXD インストール (pacman。導入済みならスキップ)
#    ArchWiki: lxd パッケージ導入後、lxd.socket を enable。
#    自動起動させたい場合は lxd.service も enable する。
# ------------------------------------------------------------
if command -v lxc &>/dev/null && command -v lxd &>/dev/null; then
  echo "[SKIP] LXD は既にインストール済みです"
else
  echo "[RUN]  LXD をインストールします (pacman)..."
  pacman -Sy --needed --noconfirm lxd
fi
command -v lxc &>/dev/null || { echo "ERROR: lxc コマンドが見つかりません"; exit 1; }

# socket activation (オンデマンド起動) + service (自動起動) を両方有効化。
# どちらか一方が無効でも起動できるよう冪等に設定する。
echo "[RUN]  lxd.socket / lxd.service を有効化します..."
systemctl enable --now lxd.socket 2>/dev/null || systemctl enable lxd.socket || true
systemctl enable lxd.service 2>/dev/null || true
systemctl start lxd.service 2>/dev/null || systemctl start lxd.socket 2>/dev/null || true
# lxcfs がある場合は有効化 (コンテナ内のリソース表示用)
if systemctl cat lxcfs.service &>/dev/null; then
  systemctl enable --now lxcfs.service 2>/dev/null || true
fi

# ------------------------------------------------------------
# 2. LXD 初期化 (本当に未初期化の時だけ実行)
# ------------------------------------------------------------
if lxc info &>/dev/null; then
  echo "[SKIP] LXD は既に初期化済みです"
else
  echo "[RUN]  LXD を初期化します..."
  lxd init --minimal
fi

# ------------------------------------------------------------
# 3. 非特権コンテナ用の subuid/subgid を保証 (Arch 特有)
#    Ubuntu (snap) では自動設定されるが、Arch では手動が必要な場合がある。
# ------------------------------------------------------------
for f in /etc/subuid /etc/subgid; do
  if [ ! -f "$f" ]; then
    echo "[RUN]  $f を作成します..."
    touch "$f"
  fi
  if grep -q '^root:' "$f"; then
    echo "[SKIP] $f の root マッピングは設定済みです"
  else
    echo "[RUN]  $f に root マッピングを追加します..."
    echo 'root:1000000:65536' >> "$f"
  fi
done

# ------------------------------------------------------------
# 4. ネットワークブリッジ lxdbr0 を保証 (NAT有効)
# ------------------------------------------------------------
if lxc network show lxdbr0 &>/dev/null; then
  echo "[SKIP] lxdbr0 は既に存在します"
else
  echo "[RUN]  lxdbr0 を作成します (IPv4 NAT有効)..."
  lxc network create lxdbr0 ipv4.nat=true
fi

# ------------------------------------------------------------
# 5. default プロファイルへの eth0 (lxdbr0) 割り当てを保証
# ------------------------------------------------------------
if lxc profile device list default 2>/dev/null | grep -qw eth0; then
  echo "[SKIP] default プロファイルには eth0 が設定済みです"
else
  echo "[RUN]  default プロファイルに eth0 を追加します..."
  lxc profile device add default eth0 nic network=lxdbr0 name=eth0
fi

# ------------------------------------------------------------
# 6. コンテナの外部疎通を保証 (IP転送・ファイアウォール)
# ------------------------------------------------------------
if [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]; then
  echo "[SKIP] IP転送は既に有効です"
else
  echo "[RUN]  IP転送を有効化します (永続設定含む)..."
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  echo 'net.ipv4.ip_forward=1' | tee /etc/sysctl.d/99-easy-lxd-forward.conf >/dev/null
fi

if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  if ufw status | grep -q "allow in on lxdbr0"; then
    echo "[SKIP] ufw は既に lxdbr0 を許可しています"
  else
    echo "[RUN]  ufw に lxdbr0 の転送許可を追加します..."
    ufw allow in on lxdbr0 || true
    ufw route allow in on lxdbr0 || true
  fi
fi

# firewalld が有効な場合、lxdbr0 を trusted ゾーンに入れる (ベストエフォート)。
if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
  if firewall-cmd --zone=trusted --query-interface=lxdbr0 &>/dev/null; then
    echo "[SKIP] firewalld は既に lxdbr0 を trusted にしています"
  else
    echo "[RUN]  firewalld の trusted ゾーンに lxdbr0 を追加します..."
    firewall-cmd --permanent --zone=trusted --add-interface=lxdbr0 || true
    firewall-cmd --reload || true
  fi
fi

# ------------------------------------------------------------
# 7. ストレージプールを /opt/lxd-pool に変更
#    --skip-pool 指定時 (サーバアップデート時) はスキップ。
# ------------------------------------------------------------
if [ "$SKIP_POOL" = true ]; then
  echo "[SKIP] サーバアップデートのためストレージプールの変更をスキップします"
else
  mkdir -p "$LXD_POOL_DIR"

  CURRENT_SOURCE=$(lxc storage get default source 2>/dev/null || echo "")
  if [ "$CURRENT_SOURCE" = "$LXD_POOL_DIR" ]; then
    echo "[SKIP] Storage pool は既に $LXD_POOL_DIR を向いています"
  else
    echo "[RUN]  Storage pool を $LXD_POOL_DIR に変更します..."
    if lxc storage show default &>/dev/null; then
      # default プールを参照しているプロファイルデバイスを先に外す
      lxc profile device remove default root 2>/dev/null || true
      lxc storage delete default
    fi
    lxc storage create default dir source="$LXD_POOL_DIR"
  fi

  # ------------------------------------------------------------
  # 8. default プロファイルへの root ディスク割り当てを保証
  # ------------------------------------------------------------
  if lxc profile device list default 2>/dev/null | grep -qw "root"; then
    echo "[SKIP] default プロファイルには root ディスクが設定済みです"
  else
    echo "[RUN]  default プロファイルに root ディスクを追加します..."
    lxc profile device add default root disk path=/ pool=default
  fi
fi

# ------------------------------------------------------------
# 9. HTTPS API を有効化
# ------------------------------------------------------------
CURRENT_HTTPS=$(lxc config get core.https_address 2>/dev/null || echo "")
if [ "$CURRENT_HTTPS" = ":8443" ]; then
  echo "[SKIP] HTTPS API は既に :8443 で有効です"
else
  echo "[RUN]  HTTPS API を :8443 で有効化します..."
  lxc config set core.https_address :8443
fi

# ------------------------------------------------------------
# 10. ユーザーを lxd グループに追加
# ------------------------------------------------------------
TARGET_USER="${SUDO_USER:-$USER}"
if id -nG "$TARGET_USER" | grep -qw lxd; then
  echo "[SKIP] $TARGET_USER は既に lxd グループのメンバーです"
else
  echo "[RUN]  $TARGET_USER を lxd グループに追加します..."
  usermod -aG lxd "$TARGET_USER"
  NEED_RELOGIN=true
fi

# ------------------------------------------------------------
# 完了メッセージ
# ------------------------------------------------------------
echo ""
echo "=========================================="
echo " LXD セットアップ完了 (CachyOS版)"
echo "=========================================="
echo " アクセス先:"
echo "   https://$(hostname):8443"
echo "=========================================="
if [ "${NEED_RELOGIN:-false}" = "true" ]; then
  echo ""
  echo "※ グループ変更を反映するため、一度ログアウト＆再ログインしてください"
fi
echo ""
