# Phase 5 Quickstart — 実機 bring-up（けんたさん向け、3 分で読める）

> 目的: XIAO BLE Sense + microSD ブレイクアウトに最新 firmware を焼いて、録音モード起動を目で確認する。電力測定（PPK2）まで一気通貫。

---

## 1. 必要機材

| 項目 | 備考 |
|---|---|
| Seeed XIAO nRF52840 **Sense**（"Sense" 必須、内蔵 PDM マイク要） | 既調達済 |
| microSD ブレイクアウト（青基板 18×18mm、WP-045 系 10kΩ プルアップ×4） | 既所有 |
| microSD カード（SanDisk Ultra 16GB or 32GB、FAT32 フォーマット） | Amazon B074B4P7KD |
| USB-C ケーブル（データ通信対応、充電専用 NG） | — |
| **PPK2** または **Joulescope**（任意、電力測定用）| Phase 5 後半で使う |
| 配線: D2(P0.28)=CS / D8(P1.13)=SCK / D9(P1.14)=MISO / D10(P1.15)=MOSI / 3V3 / GND | 仕様書 §13.1 |

---

## 2. 手順

### 2.1 最新 firmware UF2 を GitHub Actions artifacts から取得

```bash
# 直近 firmware-build run の id を取る
RUN_ID=$(gh run list --workflow=firmware --limit 1 --json databaseId -q '.[0].databaseId')

# artifact 名はビルド時の commit SHA を含む（例: mozzy-firmware-xiao-ble-65e286b）
gh run download "$RUN_ID"

# firmware.uf2 が落ちてくる
ls -la mozzy-firmware-xiao-ble-*/firmware.uf2
```

> `gh auth login` 済みでない場合は先に通すこと。リポジトリは `shkentee/mozzy`。

### 2.2 XIAO BLE Sense を bootloader モードへ

1. USB-C で PC に接続
2. **RST ボタン（基板裏側）を 2 回素早く押す**（目安: 0.3 秒以内）
3. PC で MSC ドライブ `XIAO-SENSE` がマウントされる（Adafruit nRF52 Bootloader が起動）

ドライブが見えない場合: ケーブル（充電専用ではないか）→ もう一度 RST 2回押し → 別 USB ポート の順で切り分け。

### 2.3 firmware.uf2 を MSC ドライブにコピー

`zephyr.uf2` を `XIAO-SENSE` ドライブのルートにドラッグ＆ドロップ。コピー完了後、自動で再起動する（ドライブが消える）。

### 2.4 起動確認 — 録音モード

- **緑 HB が見える**（5秒に1回 50ms 点灯、duty 1%）= 録音モード正常起動
- 赤高速点滅 = バッテリー異常 or `wr_led_pick` の最高優先警告
- 青点滅 = SD 未挿入 → カードと配線を確認
- 何も光らない = 電源断 or fatal、§2.6 のログ取得へ

### 2.5 MSC モード起動テスト（✅ D9 実装完了）

1. **D5 ボタンを押しながら USB 接続**（または RST 直後に 1 秒以上押し続ける）
2. PC で USB マスストレージドライブ `SD_CARD` がマウントされる
3. ドライブが見えない場合はログで `wr_msc_mode: button held at boot` を確認

> **実装状態**: `wr_msc_mode_boot_detect()` が起動時に D5 を 1 秒サンプリングし、
> 閾値（80/100サンプル）を超えると `usb_enable(NULL)` を呼び出して MSC スタックを起動する。
> `wr_chunk` / `wr_fifo` の SD アクセスも MSC モード中は自動でゲートされる。

### 2.6 D7 time-sync 動作確認

1. スマホアプリ（`mojio` APK）でデバイスに接続
2. 接続直後に自動で epoch が BLE WRITE_WITHOUT_RESP で送信される
3. ログで `wr_time_sync: received epoch XXXXXXXXXX s` が出ること
4. 次のチャンクローテーション後にファイル名が `<10桁epoch>.opus` 形式になること

> 接続前に作成されたファイルは `unsynced_<bootid>_<seq>.opus` 形式。
> 接続後のファイルは `<unix_secs>.opus` 形式。正常動作。

### 2.7 ログ取得（USB CDC）

通常起動時、XIAO Sense は USB CDC ACM でログを吐く。

- **mac / Linux**: `screen /dev/ttyACM0 115200`（終了は `Ctrl-A` → `K` → `y`）
- **Windows**: PuTTY で `Serial`、`COMx`（デバイスマネージャで確認）、`115200` baud
- 期待ログ（録音モード起動時）:
  ```
  *** Booting Zephyr OS build v3.6.0 ***
  [00:00:00.050,000] <inf> wr_msc_mode: recording mode (N/100 high)
  [00:00:02.001,000] <inf> wr_led_status: armed (first tick in 2 s, period 100 ms)
  [00:00:02.005,000] <inf> wr_chunk: boot_id = XXXXXXXX
  [00:00:02.006,000] <inf> wr_chunk: armed, period 600000 ms, size limit 2097152 B
  ```
  BLE 接続後:
  ```
  [HH:MM:SS.xxx] <inf> wr_time_sync: received epoch XXXXXXXXXX s
  [HH:MM:SS.xxx] <inf> wr_chunk: time synced to XXXXXXXXXX s
  ```

---

## 3. 電力測定（PPK2 持ちの場合）

### 3.1 配線

PPK2 を **VBAT と XIAO の 3V3 ピンの間に直列**で挟む（Source Meter モードで 3.7V 供給、または XIAO の VBAT パッドへ）。

| PPK2 端子 | XIAO 側 |
|---|---|
| VOUT(+) | XIAO `3V3` |
| GND | XIAO `GND` |

> XIAO Sense を USB-C で給電したまま PPK2 を Ampere Meter モードで挟む構成も可（その場合は PC からの 5V 給電を切る）。

### 3.2 30 秒キャプチャ（ppk2-cli）

```bash
# Linux（要 ppk2-api-python）
ppk2-cli --source 3700 --duration 30 --output power-baseline-$(date -u +%Y%m%dT%H%M%SZ).csv
```

CSV は `tests/firmware/data/power-baseline/` にコピーして git 管理推奨（バイナリではないため diff 可能）。

---

## 4. Phase 5 確認チェックリスト

| 項目 | 方法 | 判定基準 |
|---|---|---|
| 録音モード起動 | 緑 HB LED 点滅 | 5秒周期 50ms 点灯 |
| SD 録音 | 10分待ち → MSC で確認 | `unsynced_XXXX_00000.opus` 存在 |
| MSC モード | D5 長押し起動 | PC でドライブマウント |
| D7 time-sync | アプリ接続 → ログ確認 | `received epoch` ログ + epoch ファイル名 |
| 電力（録音中） | PPK2 30s 測定 | 3.2〜3.7 mA 平均（仕様書 §14.2） |
| バッテリー ADC | `wr_led_batt_pct` ログ | 🔶 Phase 5 で ADC_GAIN 確認要（§22.19） |

> **バッテリー ADC ゲインについて**: `wr_led_status.c` は `ADC_GAIN_1_4`（フルスケール 2.4V）で実装済み。
> OMI firmware は `ADC_GAIN_1_6`（3.6V）を使用。XIAO Sense の VBATT/2 分圧回路の実測値と
> 照合してどちらが正しいかを Phase 5 で確認し、`wr_battery.h` / `wr_led_status.c` を修正すること。

---

## 5. 次にやること

§14.2 の電力目標値と照合する。

| シナリオ | 仕様書予測 | 実測 | 判定 |
|---|---|---|---|
| 録音中（BLE 切断、SD 書き込みあり） | **3.2〜3.7 mA 平均** | TBD | — |
| BLE 接続中（Plan B、SD 書き込み継続） | 3.2〜3.7 mA + α | TBD | — |
| アイドル（録音停止 + BLE 切断） | < 1 mA | TBD | — |
| MSC モード（録音停止 + USB 給電） | n/a（USB 給電中）| TBD | — |

実測結果は以下に保存:
- 生 CSV: `tests/firmware/data/power-baseline/<scenario>-<date>.csv`
- サマリ: `docs/wearable-recorder-spec.md` §14.2 の表をアップデート

§14.2 が更新されたら Phase 5 実機検証完了。次は Phase 6（Flutter 実機 BLE 接続 / APK インストール検証）。

---

**EOF**
