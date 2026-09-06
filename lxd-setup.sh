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
LXD_DATA_DIR="/opt/lxd-data"

# ------------------------------------------------------------
# Btrfsサブボリュームの保証 (CachyOS / Btrfs環境用)
#   /opt が Btrfs の場合、指定ディレクトリを独立サブボリューム化する。
#   目的: snapper のシステムスナップショット (@) からコンテナ実体・
#   共有データを除外し、肥大化と rollback 時の巻き込みを防ぐ。
#   fstab 追記は不要 (親ボリューム内に自動で現れる)。
#   - 既にサブボリューム → スキップ
#   - 存在しない / 空ディレクトリ → サブボリュームとして作成
#   - 空でない通常ディレクトリ → データ保護のためスキップ (警告のみ)
#   - 非Btrfs / btrfs コマンド無し → 何もしない
# ------------------------------------------------------------
ensure_btrfs_subvolume() {
  local dir="$1"
  command -v btrfs &>/dev/null || return 0
  local parent
  parent="$(dirname "$dir")"
  [ -d "$parent" ] || mkdir -p "$parent"
  if [ "$(stat -f -c %T "$parent" 2>/dev/null)" != "btrfs" ]; then
    return 0
  fi
  if [ -d "$dir" ] || [ -e "$dir" ]; then
    if btrfs subvolume show "$dir" &>/dev/null; then
      echo "[SKIP] $dir は既に Btrfs サブボリュームです"
      return 0
    fi
    if [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
      echo "[RUN]  空ディレクトリ $dir をサブボリュームに置き換えます..."
      rmdir "$dir"
    else
      echo "[WARN] $dir は空でない通常ディレクトリのためサブボリューム化をスキップします"
      echo "       移行する場合はコンテナ停止→退避→削除→subvolume create→復元してください"
      return 0
    fi
  fi
  echo "[RUN]  Btrfs サブボリューム $dir を作成します..."
  btrfs subvolume create "$dir"
}

# Btrfs上なら btrfs ドライバー、そうでなければ dir ドライバーを使う。
wanted_storage_driver() {
  if command -v btrfs &>/dev/null && [ "$(stat -f -c %T "$(dirname "$LXD_POOL_DIR")" 2>/dev/null)" = "btrfs" ]; then
    echo "btrfs"
  else
    echo "dir"
  fi
}

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
#    LXD は既定でホスト側に約10億個の ID 範囲を要求するため
#    root:1000000:1000000000 が必要 (ArchWiki 推奨)。
#    加えて EasyLXD の /opt/lxd-data 共有で使う raw.idmap "both 1000 1000"
#    のため root:1000:1 の委譲も必要。
#    不足・旧形式 (例: root:1000000:65536 のみ) の場合は置き換える。
# ------------------------------------------------------------
for f in /etc/subuid /etc/subgid; do
  if [ ! -f "$f" ]; then
    echo "[RUN]  $f を作成します..."
    touch "$f"
  fi
  if grep -q '^root:1000000:1000000000' "$f" && grep -q '^root:1000:1' "$f"; then
    echo "[SKIP] $f の root マッピングは設定済みです"
  else
    echo "[RUN]  $f の root マッピングを設定します..."
    grep -v '^root:' "$f" > "$f.tmp" || true
    cat "$f.tmp" > "$f"
    rm -f "$f.tmp"
    echo 'root:1000000:1000000000' >> "$f"
    echo 'root:1000:1' >> "$f"
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
#    Btrfs上ならサブボリューム化 + btrfs ドライバー、非Btrfsなら
#    通常ディレクトリ + dir ドライバー。
#    --skip-pool 指定時 (サーバアップデート時) はスキップ。
# ------------------------------------------------------------
# /opt/lxd-data もプール処理の成否に関わらずサブボリューム化だけは保証する
# (snapper 除外のため。--skip-pool 時も実行される)。
ensure_btrfs_subvolume "$LXD_DATA_DIR" || true
if [ -d "$LXD_DATA_DIR" ]; then
  chown -R 1000:1000 "$LXD_DATA_DIR" 2>/dev/null || true
  chmod -R 775 "$LXD_DATA_DIR" 2>/dev/null || true
fi

if [ "$SKIP_POOL" = true ]; then
  echo "[SKIP] サーバアップデートのためストレージプールの変更をスキップします"
else
  ensure_btrfs_subvolume "$LXD_POOL_DIR" || true
  mkdir -p "$LXD_POOL_DIR"

  WANT_DRIVER="$(wanted_storage_driver)"
  echo "[INFO] ストレージドライバー: $WANT_DRIVER (source=$LXD_POOL_DIR)"

  CURRENT_SOURCE=$(lxc storage get default source 2>/dev/null || echo "")
  CURRENT_DRIVER=$(lxc storage show default 2>/dev/null | awk -F': *' '$1=="driver" {print $2}' || echo "")
  if [ "$CURRENT_SOURCE" = "$LXD_POOL_DIR" ] && [ "$CURRENT_DRIVER" = "$WANT_DRIVER" ]; then
    echo "[SKIP] Storage pool は既に $LXD_POOL_DIR ($WANT_DRIVER) を向いています"
  else
    echo "[RUN]  Storage pool を $LXD_POOL_DIR ($WANT_DRIVER) に変更します..."
    if lxc storage show default &>/dev/null; then
      # インスタンスやカスタムボリュームが残っているとプール削除できない。
      # 中途半端な削除を避けるため事前に検出して中断する。
      if lxc list --format csv -c n 2>/dev/null | grep -q .; then
        echo "ERROR: インスタンスが残っているためストレージプールを変更できません。"
        echo "       先に全インスタンスを削除 (lxc delete --force <name>) してから再実行してください。"
        exit 1
      fi
      if lxc storage volume list default --format csv 2>/dev/null | grep -q .; then
        echo "ERROR: カスタムボリュームが残っているためストレージプールを変更できません。"
        echo "       先にボリュームを削除してから再実行してください。"
        exit 1
      fi
      # default プールを参照しているプロファイルデバイスを先に外す
      lxc profile device remove default root 2>/dev/null || true
      lxc storage delete default
    fi
    lxc storage create default "$WANT_DRIVER" source="$LXD_POOL_DIR"
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
