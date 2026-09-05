# KonomiTV (DTV) on CachyOS / Arch — 注意点

EasyLXD 本体のコンテナ操作 (作成・Tailscale・Docker・マウント・スナップショット・
アプリインストール・DTV管理ダッシュボード) は、コンテナ内が Ubuntu のため
CachyOS ホストでもそのまま動作します。

## 動作しないもの: 「px4_drvインストール」ボタン

`tuner-lxd.sh` のドライバ導入は以下を前提にしており、CachyOS/Arch ホストでは
そのまま実行できません (UI から実行すると手順書への誘導エラーになります)。

- `px4-drv-dkms_*_all.deb` の取得 → `sudo apt install -y <deb>` で導入
- `modprobe px4_drv` でロード、`/dev/isdb2056video*` の出現を確認

## 代替手段 (ホスト側で手動導入)

### 選択肢 A: AUR パッケージ (paru)

```bash
paru -S px4_drv-dkms-git
```

注意: 2024〜2025 年時点の報告では、新カーネル (class_create API 変更など) で
ビルド失敗するケースがあります。失敗した場合は選択肢 B を検討してください。

### 選択肢 B: ソースから DKMS ビルド (tsukumijima/nns779 系 px4_drv)

```bash
sudo pacman -Sy --needed dkms linux-cachyos-headers git unzip gcc make
git clone https://github.com/tsukumijima/px4_drv.git
cd px4_drv
# ファームウェア抽出 (README の手順に従う)
cd fwtool && make
wget http://plex-net.co.jp/plex/pxw3u4/pxw3u4_BDA_ver1x64.zip -O pxw3u4_BDA_ver1x64.zip
unzip -oj pxw3u4_BDA_ver1x64.zip pxw3u4_BDA_ver1x64/PXW3U4.sys
./fwtool PXW3U4.sys it930x-firmware.bin
sudo cp it930x-firmware.bin /lib/firmware/
cd ..
# DKMS 登録・インストール (バージョンは dkms.conf に合わせる)
sudo cp -a ./ /usr/src/px4_drv-<version>
sudo dkms add px4_drv/<version>
sudo dkms install px4_drv/<version>
sudo modprobe px4_drv
ls /dev/isdb2056video*
```

新カーネルではソース側の修正が必要になる場合があります。
`nns779/px4_drv` の README・Issue も参照してください。

## ドライバ導入後のフロー (UI のまま実行可)

1. ホストで `lsusb` (ISDBT2056) と `/dev/isdb2056video*` を確認
   (`usbutils` は本インストーラで導入済み)
2. UI の「コンテナ作成」→「アプリインストール」→「DTV管理」の順に実行
   (USB パススルー・Tailscale・スナップショットは LXD 機能のため OS 非依存)
