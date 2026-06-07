# 自作ウェアラブル録音デバイス - システム仕様書

> **目的**: 起きている間ずっと録音し、後でローカルWhisper(faster-whisper large-v3)で文字起こしするウェアラブルデバイスを自作する。
> Omi DK2 (BasedHardware) を参考に、けんたさんの要件に合わせて改修。

---

## 0. このドキュメントの位置づけ

- このドキュメントは `shkentee/mozzy` リポジトリの仕様書（Phase 1 確定版）
- 元の仮版は Claude チャットでの議論ベース。本版は **公式 omi リポジトリ実物検証済み + 17項目の決定（D1〜D17）反映済み**
- 参考リポジトリ: https://github.com/BasedHardware/omi（git submodule として `third_party/omi/` に固定）
- ベースファームウェアパス: `third_party/omi/omi/firmware/devkit/`
- 改修方針: Plan B（常時SD書き込み）/ ボタン長押しMSCモード / ハートビート式LED通知

### 0.1 けんた17決定事項サマリ

進捗マーク: ✅ 実装完了 / 🟡 MVP実装済（残作業あり） / ⏳ 未着手

| # | 確定事項 | 進捗 |
|---|---|---|
| D1 | SD SPI: MOSI=D10/MISO=D9/SCK=D8/CS=D2(P0.28)/24MHz | ✅ |
| D2 | ボタン: D4(P0.04, OUT) + D5(P0.05, IN) | ✅ |
| D3 | LED: ハートビート式 + 警告優先 | ✅ Phase 4-5 + 4-5+（純化 + 13 ztest。バッテリーADCフックは Phase 5）|
| D4 | SD: Plan B（常時書き込み） | ✅ Phase 4-1（pusher() ファンアウト patch 適用済。実機ジッター測定は Phase 5）|
| D5 | バッテリー: 250mAh一本 | 🟡 Phase 6（`wr_battery.c` SAADC 純粋計算 + 15 ztest 完了 §22.16。Zephyr SAADC glue `wr_led_status.c` 実装完了 §22.19。DT overlay + Phase 5 実機ゲイン検証は Phase 5 後）|
| D6 | チャンク: 10分/file | ✅ Phase 4-2 + 4-6+（純化 + ztest。サイズ閾値は wr_chunk_logic 実装済、Phase 6 で配線）|
| D7 | ファイル名: `<UNIX_epoch>.opus` / 未同期時 `unsynced_<bootid>_<seq>.opus` | ✅ Phase 4-6+ + Phase 6（純化ロジック + ztest + 3-kind 判別 / 削除順 OK。`wr_time_sync` GATT char + `wr_chunk_set_sync_time()` runtime 配線完了 §22.15）|
| D8 | FIFO: 空き10%以下で最古から削除 | ✅ Phase 4-3 + 4-6+ + Phase 6（純化 + ztest + LEGACY/UNSYNCED/EPOCH classify + 削除優先度総順序、計 18 ztest 追加）|
| D9 | USB MSC: ボタン長押し起動でMSCモード | ✅ Phase 4-4 + 4-6+ + Phase 6（純化 + runtime-mode 述語 + chunk/fifo MSC short-circuit + 13 ztest + `usb_enable()` 実呼び出し + omi audio stack ゲート 0003 patch 完了 §22.17）|
| D10 | Opus: 32kbps（omi標準）| ✅ |
| D11 | DTX: 0（無効、omi標準）| ✅ |
| D12 | 時刻同期: omi `performSyncTime()` | ✅ |
| D13 | リポジトリ: 自前 + omi submodule | ✅ |
| D14 | テスト: GitHub CI + native_sim + 実機 | ✅ Phase 2/3 + Phase 4-5+/4-6+（ztest 約60本）+ Phase 5+（bsim CI scaffold、smoke のみ）。実機は Phase 5 |
| D15 | リポ名: `shkentee/mozzy` | ✅ |
| D16 | 充電中: 録音継続、黄HB/緑常時 | ✅ Phase 4-5 |
| D17 | スマホアプリ: Phase 6で自前ミニマル | 🟡 Phase 6 着手（`app_mobile/` Flutter skeleton: BLE スキャン / 接続 / Opus パケット notify dump）|

---

## 1. プロジェクト概要

### 1.1 用途

- 起きている間(15時間/日想定)の周辺音声を常時録音
- 録音データを後でローカルでfaster-whisper large-v3により文字起こし
- 文字起こしはバッチ処理(リアルタイム性は不要)
- 録音データはGoogleドライブにスマホ経由でアップロード

### 1.2 性能目標

- **150 mAh バッテリーで 20時間連続稼働を達成**(若干ショートしても可)
- 実装時は 250 mAh バッテリーで余裕を見込む
- 1日15時間稼働 + 充電1日 = 隔日運用可能

### 1.3 開発環境

- **Zephyr RTOS** + **nRF Connect SDK (NCS) 2.7.0以降**(2.9.0推奨)
- **Adafruit nRF52 Bootloader** + UF2 ドラッグドロップ書き込み
- ビルド対象ボード: `xiao_ble/nrf52840/sense`

---

## 2. ハードウェア構成(確定)

### 2.1 部品リスト

| 部品 | 型番・仕様 | 入手 | 備考 |
|---|---|---|---|
| MCU | Seeed Studio XIAO nRF52840 Sense | Seeed Studio直販 / Amazon | 内蔵PDMマイク MP34DT05、内蔵 P25Q16H 2MB QSPI flash |
| microSDブレイクアウト | 18×18mm 青基板 (WP-045系) | けんたさん既所有 | 10kΩプルアップ×4 + デカップリングコンデンサ。シンプル構成 |
| microSDカード | SanDisk Ultra 16GB or 32GB | Amazon B074B4P7KD (¥749, 並行輸入) | 待機電流 約250µA(Neurotech Hub 2025実測) |
| バッテリー | LiPo 150mAh(検証時) → 250mAh(本番採用) | - | 502030 250mAh (DK2と同じ型番、確定) |
| スイッチ | タクトスイッチ 4×4×1.5mm SMD | Amazon | DK2と同じ型番。電源ON/OFFと録音制御を兼用 |
| 充電 | XIAO Senseの USB-C(標準実装) | - | 充電中もUSB-C経由で SD読み出し可 |

### 2.2 採用しないもの

- **Adafruit 5769 Audio BFF**: スピーカー不要、待機電流の懸念あり、I2S配線不要のため不採用
- **スライドスイッチ**: タクトスイッチで電源制御も兼用するため不要
- **MOSFET電源カット**: DK2も未採用、microSDの250µA待機電流は許容範囲
- **専用エンクロージャー**: 今回は省略(機能検証優先)

### 2.3 SD カードへの PC アクセス方法

- **デバイス内蔵時のSDカード抜き差しは想定しない**
- **XIAO Sense の USB-C を PC に接続して SD 内ファイルを読み出す**
- そのため Mass Storage Class (MSC) または同等の機能を実装する
- ファイルシステム形式は **FAT32**(PCで直接読める)

---

## 3. ソフトウェア仕様

### 3.1 ベースファームウェア

- **リポジトリ**: `https://github.com/BasedHardware/omi`
- **ベースパス**: `omi/firmware/devkit/`
- **ベース設定ファイル**: `prj_xiao_ble_sense_devkitv1-spisd.conf`
  - DK1ハードウェア(単一PDM、Adafruit 5769なし)+ SPI SDカード追加版
  - けんたさん構成に最も近い
  - **要確認**: Claude Code起動後、まず実ファイルを `view` して内容を確認すること

### 3.2 ファイル構造(公式リポジトリから判明)

```
omi/firmware/devkit/
├── overlay/                                    # devicetree overlay
├── src/
│   ├── main.c          # メインループ・初期化
│   ├── transport.c/.h  # BLE GATT・接続管理
│   ├── codec.c         # Opus エンコード
│   ├── mic.c           # PDM マイク
│   ├── sdcard.c        # SDカード FAT書き込み
│   ├── storage.c       # Storage GATTサービス
│   ├── speaker.c       # I2Sスピーカー(DK2用、けんた案では不要)
│   ├── button.c        # タクトスイッチ
│   ├── usb.c           # USB CDC ACM
│   ├── utils.h         # マクロ
│   └── features.h      # OmiFeaturesビットマスク
├── CMakeLists.txt
├── CMakePresets.json
├── Kconfig
├── flash.sh
├── prj_xiao_ble_sense_devkitv1.conf
├── prj_xiao_ble_sense_devkitv1-spisd.conf       # ★ベース
└── prj_xiao_ble_sense_devkitv2-adafruit.conf
```

---

## 4. オーディオ仕様

### 4.1 確定事項(公式から判明)

| 項目 | 値 | 根拠 |
|---|---|---|
| サンプリングレート | **16 kHz** | DeepWiki公式情報 |
| ビット深度 | **16-bit (PCM16)** | 同上 |
| チャンネル | **1 (mono)** | codec.c: `opus_encoder_get_size(1)` |
| エンコーダー | **Opus** | 同上 |
| Opus演算モード | **整数モード固定** | ビルドフラグ `-DFIXED_POINT` |
| Opus エンコーダーサイズ | **7180 bytes** (mono+整数) | codec.c #define |
| ARM 最適化 | EDSP 命令使用 | `-DOPUS_ARM_INLINE_EDSP` |
| 出力 | 80バイト/フレーム × 100 frames/sec | DeepWiki |
| マイク | XIAO Sense内蔵 PDM (MP34DT05) | ハードウェア仕様 |

### 4.2 確定値（公式 `src/config.h` 実物検証済）

| 項目 | 値 |
|---|---|
| `CODEC_OPUS_BITRATE` | **32000 (32 kbps)** |
| `CODEC_OPUS_COMPLEXITY` | **3** （省電力寄り）|
| `OPUS_SET_DTX` | **0（無効）** ※連続録音用に正解 |
| `CODEC_OPUS_APPLICATION` | **`OPUS_APPLICATION_RESTRICTED_LOWDELAY`** （BLEストリーミング向け）|
| `CODEC_OPUS_VBR` | 1（可変ビットレート） |
| Opus mode | CELT |
| `CODEC_PACKAGE_SAMPLES` | 160（10ms @ 16kHz）|
| `MIC_BUFFER_SAMPLES` | 1600（100ms @ 16kHz）|
| `AUDIO_BUFFER_SAMPLES` | 16000 |

### 4.3 けんた案でのオーディオ設定方針

- **omi標準 Opus 設定をそのまま採用（D10確定）**
  - 32kbps mono Opus は Whisper 入力として十分高品質
  - SD容量影響: 32GB で約 **134日分**（15h/日、空き10%余白考慮）
  - DK2 は同設定で各種STTで実績あり
- 32kbps から下げる必要が出た場合は config.h を後で調整可能（電力影響は誤差レベル）

---

## 5. BLE 通信仕様

### 5.1 確定事項(公式から判明)

| 項目 | 値 | 根拠 |
|---|---|---|
| GATT audioCodec UUID | `19b10002` | DeepWiki |
| GATT features UUID | `19b10020` | DeepWiki |
| GATT storageDataStreamService | `30295780` | DeepWiki |
| GATT storageDataStream | `30295781` | DeepWiki |
| GATT storageReadControl | `30295782` | DeepWiki |
| MTU | **498 bytes** | `CONFIG_BT_L2CAP_TX_MTU=498` 確定済 |
| PHY | **2M PHY 有効** | `CONFIG_BT_AUTO_PHY_UPDATE=y` 確定済 |
| Connection Interval | 7.5-15ms | DK1+SPISD構成で `CONFIG_BT_PERIPHERAL_PREF_*` 確認済 |
| TX Power | **+8 dBm** | `CONFIG_BT_CTLR_TX_PWR_ANTENNA=8`（旧 `_PLUS_8` は誤記、修正済）|

### 5.2 接続戦略の方針

**Omi DK2の方式(常時接続+リアルタイムストリーミング)を採用**

理由:
- スマホ側電池消費が無視できる(Xiaomi 14T Pro 5000mAhで 1.2%/日)
- リアルタイム文字起こしの可能性を残す
- データ損失リスクが最小
- DK2 ファームをそのまま流用できる
- 10分毎バースト方式のリスク(背景接続不可、再接続失敗ループ等)を回避

### 5.3 動作フロー(公式DeepWiki確認済)

```
PDMバッファfill
 → mic_handler() (mic.c)
 → codec_receive_pcm(buffer, MIC_BUFFER_SAMPLES)
 → Opusエンコード (codec.c)
 → codec_handler()
 → broadcast_audio_packets(data, len) (transport.c)
 → BLE GATT notify (audioCodec characteristic 19b10002)

[BLE接続中]
 → リアルタイムストリーミング
 → SD書き込みは行うかどうか要確認(設計選択肢あり、§7参照)

[BLE切断時]
 → SDカード書き込み (FAT32)
 → WRITE_BATCH_COUNT = 10 でバッファリング
 → SD_FSYNC_THRESHOLD = 20000 bytes ごとに fsync

[再接続時]
 → getStorageList() でアプリが残データを取得
 → storageDataStream characteristic 経由で転送
```

### 5.4 確定 CONFIG 値（`prj_xiao_ble_sense_devkitv1-spisd.conf` 実物検証）

| CONFIG | 値 |
|---|---|
| `CONFIG_BT_L2CAP_TX_MTU` | 498 |
| `CONFIG_BT_BUF_ACL_RX_SIZE` | 2048 |
| `CONFIG_BT_BUF_ACL_TX_SIZE` | 2048 |
| `CONFIG_BT_AUTO_PHY_UPDATE` | y |
| `CONFIG_BT_CTLR_TX_PWR_ANTENNA` | 8 |
| `CONFIG_BT_MAX_CONN` | 1 |
| `CONFIG_MAIN_STACK_SIZE` | 8192 |
| `CONFIG_HEAP_MEM_POOL_SIZE` | 4096 |
| `CONFIG_OMI_CODEC_OPUS` | y |
| `CONFIG_OMI_OFFLINE_STORAGE` | y |
| `CONFIG_LOG_DEFAULT_LEVEL` | 3 |

`CONFIG_BOARD_ENABLE_DCDC` / `CONFIG_PM` は Phase 5（電力測定）で必要に応じて追加。

---

## 6. ストレージ仕様

### 6.1 確定事項(公式から判明)

| 項目 | 値 | 根拠 |
|---|---|---|
| ファイルシステム | **FAT32 + exFAT** | `CONFIG_FAT_FILESYSTEM_ELM=y` + `CONFIG_FS_FATFS_EXFAT=y` |
| マウントポイント | `/SD:` | omi `sd_card.c` |
| ファイルシステムライブラリ | FatFS (`CONFIG_FAT_FILESYSTEM_ELM=y`) | omi `prj_*-spisd.conf` |
| WRITE_BATCH_COUNT | — | **omi未実装**（DeepWikiの古い記述）。Phase 4 で自前実装 |
| SD_FSYNC_THRESHOLD | — | **omi未実装**。Phase 4 で自前実装 |
| インターフェース | SPI（24MHz）| `xiao_ble_sense_devkitv1-spisd.overlay` |
| 書き込み形式 | Opus エンコード済みデータをそのまま保存 | omi `sdcard.c` |
| 現状ファイル名 | `audio/a##.txt` 連番（Phase 4 で改修） | omi `sdcard.c` |

### 6.2 動作仕様(公式)

- **BLE切断時にSDへ書き込み開始**(オフラインバックアップ)
- **BLE再接続時に未送信データを送信**(storage syncプロトコル)
- DK2 標準では「BLE接続中はSDに書かず、切断中だけSDに書く」運用

### 6.3 採用方針: Plan B（常時SD書き込み）【D4確定】

- BLE接続/切断にかかわらず常時SDに書き込み
- BLE は補助的なリアルタイム転送（D17の自前アプリで使用予定）
- メリット: 確実にローカル保存される、Phase 6 のアプリ完成前も録音継続
- 電力影響: +0.6〜1.0mA（SDアイドル260µA前提、§14.2参照）
- SD寿命: 32GB Ultra で 32kbps常時書き込み → 約15年（書き込み量から逆算）

#### 改修箇所

| ファイル | 内容 |
|---|---|
| `transport.c::broadcast_audio_packets()` | BLE接続中も `write_to_storage()` を呼ぶ |
| `storage.c` | `is_connected` ガードを削除（BLE切断時のみの分岐を撤廃） |

### 6.4 SD容量とFIFOリングバッファ運用【D8確定】

- **32GB microSD で約 134日分の Opus 32kbps 音声**（15h/日、空き10%余白考慮）
- 24h連続なら約92日
- **FIFO自動削除しきい値: 空き容量10%以下で最古ファイルから削除**
  - 32GB → 約3.2GB余白を常時確保（17日分の余白）
  - 録音中ファイル（`current_fp`）は除外
  - 起動時 + 1分ごとにチェック
- **omi公式は FIFO 削除未実装** → Phase 4 で `app/src/sd_fifo.c` として新規実装

### 6.5 PCからのアクセス方法【D9確定: ボタン長押し起動でMSCモード】

- **omi 公式 USB 実装**: `usb.c` は USB 接続検知（充電状態判定）+ ログ出力のみ。**ファイル転送機能は無い**
- **採用方式**: 起動時にボタン長押しで **MSCモード**に入る、通常起動は録音モード
  - 理由: 録音中の SD への同時アクセス（FAT32破損リスク）を完全回避
  - USB 接続だけでは MSC にならず、充電のみ
  - 明示的な「PC接続したい」操作（ボタン長押し再起動）でモード切替
- **実装内容**:
  - 通常起動: 従来 CDC ACM（ログ出力）+ 録音モード
  - MSC起動: `CONFIG_USB_MASS_STORAGE=y` で SD を USB MSC LUN として公開、録音は停止
  - 起動時に `button.c` でD5入力を1秒以上 HIGH 検出 → MSCモード分岐
- 実装難易度: 中（Zephyr `samples/subsys/usb/mass` ベース、composite 構成は不採用）

---

## 7. チャンク分割方式【D6, D7 確定】

### 7.1 omi の現状

- ファイル名: **`audio/a##.txt` 連番（##=01-99）**
- 再起動で連番リセット → 衝突する欠陥あり
- ローテーションのタイミング: omi 実装を Phase 1 で精読、おそらくサイズ閾値

### 7.2 けんた案【D6: 10分、D7: UNIX_epoch ファイル名】

- **1ファイル = 10分単位** （1.8MB/file, 90ファイル/日 @15h, Whisperと相性良）
- ファイル名規則:
  - 時刻同期済み: `<UNIX_epoch>.opus`（例: `1745654400.opus`）
  - 時刻未同期時: `unsynced_<bootid>_<seq>.opus`（例: `unsynced_b03_005.opus`）
    - `bootid` は起動カウンタ（不揮発書き込みは不要、RAM保持で十分）
    - 後で時刻が同期したら、PC側ツールでファイル mtime や接続時の時刻ログから時刻補正
- 連結処理: PC側 Whisper 前/後で `ffmpeg concat` 結合
- 実装: Phase 4 で `sdcard.c::create_audio_file()` を改修（連番→ epoch ベース）

---

## 8. VAD(音声検出)

### 8.1 公式実装の確認状況

- **Omiファームウェア側にVAD実装は無さそう**(DeepWiki記載なし)
- Omiバックエンド(Pythonサーバー側)で **Silero VAD** を使用
- ファームウェアは**常時録音、常時Opusエンコード、常時BLE送信**

### 8.2 けんた案での方針

- **ファームウェア側に VADは実装しない**(公式踏襲)
- Opus 標準の DTX 機能のみ利用(無音時パケット削減)
- 環境音録音も要件に入っているため、過度なフィルタリングは避ける
- PC側Whisperで自動的に無音区間を検出するためファームではフィルタ不要

### 8.3 DTX 確定値【D11: DTX=0】

- omi `codec.c` の実物検証: **`OPUS_SET_DTX(0)`**（無効）で確定
- 当初仮説の「DTX=1に変更検討」は **撤回**:
  - 連続録音 + Whisper 文字起こしのパイプラインでは **時刻が連続している** ことが重要
  - DTX=1 だと無音区間でパケット間引きが起きて、再生時の時刻整列が崩れる
  - DTX=0 が正解（電力差は誤差レベル）

---

## 9. システム全体構成(エンドツーエンド)

### 9.1 データフロー

```
┌──────────────────────────────────────────────┐
│  ウェアラブルデバイス (XIAO nRF52840 Sense)   │
│                                              │
│  PDMマイク → Opus encode → ┬→ BLE notify     │
│                            └→ SD書き込み      │
└──────────────────────────────────────────────┘
                  │ BLE                  │ USB-C
                  ▼                      ▼
        ┌──────────────────┐    ┌─────────────────┐
        │ Xiaomi 14T Pro   │    │ PC (OMEN 25L)   │
        │ スマホアプリ      │    │ Mass Storage   │
        │                  │    │ ↓               │
        │ ↓                │    │ faster-whisper │
        │ Google Drive     │    │ large-v3        │
        │ アップロード      │    │ ↓               │
        │                  │    │ 文字起こし       │
        └──────────────────┘    └─────────────────┘
```

### 9.2 処理パイプライン(2ルート)

**ルートA(リアルタイム/準リアルタイム)**:
1. デバイスがBLEで Opusデータをスマホに送信
2. スマホアプリがGoogleドライブにアップロード(リアルタイムまたはバースト)
3. PCで定期的にGoogleドライブから取得、Whisper処理

**ルートB(バックアップ/メイン)**:
1. デバイスが常時SDに録音保存
2. 1日終わりまたは充電タイミングでUSB-C接続
3. SDの内容をPCが直接読み取り、Whisper処理

→ **両方並行運用**(冗長性確保)

### 9.3 録音できなかった場合の動作

ケース別:
- **BLE切断**: SDに書き続ける、再接続時にスマホへ転送
- **SD満杯**: FIFOで古いファイル削除、LED警告
- **SD未挿入/エラー**: BLE接続中ならBLEのみで継続、切断中はLED警告のみ
- **バッテリー切れ**: 自動的に正常シャットダウン(電源喪失前にfsync)

### 9.4 スマホアプリ(後回し)

- スコープ: けんたさんの要件「アプリは後回し」
- 暫定: BLE経由のリアルタイム/バースト送信機能のみ実装
- 最終: Googleドライブアップロード機能を追加
- 実装言語: Flutter (Omi 公式アプリと互換性確保) または React Native
- ベース: Omi 公式アプリ (`app/` ディレクトリ) を fork して改修

---

## 10. タイムスタンプ管理

### 10.1 確定事項(公式)

- スマホ接続時に `performSyncTime()` でUTC epoch を時刻同期
- nRF52840内蔵RTC使用、精度 ±20ppm
- 1日のドリフト: 約1.7秒

### 10.2 けんた案での方針

- 公式と同じ仕組みを使用
- BLE接続時に毎回時刻同期(差分大なら更新)
- ファイル名にUNIXタイムスタンプを埋め込み(§7.2)
- スマホ未接続時に録音されたデータも、次回接続時にRTC補正してメタデータ更新

---

## 11. 緊急通知(LED/振動)

### 11.1 公式DK2の機能

- LED あり(`OmiFeatures.ledDimming`)
- 振動(haptic)あり(`OmiFeatures.haptic`)、ただしDK2は未搭載

### 11.2 LED通知パターン【D3, D16 確定: ハートビート式 + 充電表示追加】

警告系（高優先）と平常系（低優先）はハートビート式で識別。同時発生時は **高優先が低優先を上書き** する優先順位ロジック。

#### 警告系（高優先、警告中は平常HBを停止）

| イベント | LED | 優先度 |
|---|---|---|
| バッテリー残≤5% | 赤 高速点滅（500ms周期）| **最高** |
| バッテリー残≤20% | オレンジ点滅（1秒周期）| 高 |
| SD満杯（FIFO閾値到達後の完全フル）| 赤 常時点灯 | 中 |
| SD未挿入 | 青 点滅（1秒周期）| 中 |

#### 平常系（低優先、警告無し時のみ表示）

| イベント | LED | 優先度 |
|---|---|---|
| 録音中 | **白ハートビート（5秒間隔で50ms点灯、duty 1%）** | 低 |
| BLE接続中 | **緑ハートビート（同様）** | 低 |
| 録音中 + BLE接続中 | 白HB と 緑HB を交互 | 低 |

#### 充電系【D16】

| イベント | LED | 表示タイミング |
|---|---|---|
| 充電中 | 黄ハートビート（赤+緑同時、5秒間隔HB）| USB-C 接続中、充電継続中 |
| 充電完了 | 緑 常時点灯（明るめ）| USB-C接続済 + 充電IC が完了報告（または満充電閾値到達） |

#### 電力影響

ハートビート方式により、平常系LEDの電流消費は **+0.01mA未満**（無視できるレベル）。
警告系発生時の電流増は数mA程度だが、警告状態自体が一時的。

→ 実装: Phase 4 で新規 `app/src/led_status.c`、ADC経由でバッテリー残取得、LED状態マシンで優先順位判定

---

## 12. 充電方式【D16確定】

- **USB-C 直接**（XIAO Sense 標準、内蔵 BQ25101 充電IC）
- **充電中も録音/BLE/SD書き込み 全て継続**（電力供給ありなので問題なし）
- 充電中表示: **黄ハートビート（赤+緑同時 HB）** ※BLE接続中の緑HBと識別可能
- 充電完了表示: **緑常時点灯（明るめ）**
- omi 標準は「充電中=緑常時点灯」のみだが、けんた案は BLE緑HBと被るため変更
- 実装メモ: omi `usb.c` の `usb_charge` フラグ + 充電IC CHRGピン読み込み（後者は実装オプション）

---

## 13. ピンアサイン(要確認)

### 13.1 ピンアサイン【D1, D2 確定: omi標準そのまま】

`third_party/omi/omi/firmware/devkit/overlay/xiao_ble_sense_devkitv1-spisd.overlay` 実物検証済み。

| 機能 | XIAO ピン | nRF52840 GPIO | ソース |
|---|---|---|---|
| SD MOSI | **D10** | **P1.15** | overlay 確定 |
| SD MISO | **D9** | **P1.14** | overlay 確定 |
| SD SCK (CLK) | **D8** | **P1.13** | overlay 確定 |
| SD CS | **D2** | **P0.28** | overlay 確定（仮版の `D7/P1.12` は誤推定、修正済） |
| SD SPI 速度 | — | — | 24 MHz |
| PDM CLK | 内蔵 | （nRF52840 PDM周辺） | XIAO Sense内蔵マイク MP34DT05 |
| PDM DATA | 内蔵 | 同上 | 同上 |
| ボタン 電源出力 | **D4** | **P0.04** | omi `button.c` 実物検証 |
| ボタン 入力 | **D5** | **P0.05** | omi `button.c`（立ち上がりエッジ割込）|
| LED R / G / B | 内蔵 RGB | XIAO Sense 内蔵 | （overlay で alias 定義） |

#### ボタン配線

タクトスイッチを **D4 と D5 の間に挟む** 構成（GND 不要、omi標準）:
- D4 を HIGH 出力 → 押下時に D5 が HIGH を読む
- スリープ時は D4 を LOW にすればボタン回路の待機電流もゼロ化可能

---

## 14. 電力目標と現実的予測

### 14.1 公式DK1/DK2の実績

| | DK1 | DK2 |
|---|---|---|
| バッテリー | 250 mAh | 250 mAh |
| 持続時間 | 4日 (≒96h) | 2日 (≒48h) |
| 平均電流 | 2.6 mA | 5.2 mA |

### 14.2 けんた案の予測（D5 確定: 250mAh 一本）

実測 SD アイドル電流 **260µA** ベースで再算出:

| 内訳 | 電流 |
|---|---|
| DK1ベース（BLE+PDM+Opus）| 2.6mA |
| SD常時書き込み（Plan B、260µA アイドル + 1% バースト）| +0.6〜1.0mA |
| LED ハートビート | +0.01mA |
| **合計平均電流** | **3.2〜3.7mA** |

| 容量 | 連続稼働 | 15h/日運用 |
|---|---|---|
| 150mAh | 41〜47h | 隔日OK（40%余裕）|
| 200mAh | 54〜63h | 3日連続OK |
| **250mAh（採用）** | **67〜78h** | **4日連続OK（230%余裕）** |

### 14.3 20時間目標の達成性

- **250mAh で 67h以上** → 20h目標に対して **230%以上の余裕**
- 150mAh でも達成可能（41〜47h）だったが、Plan B採用＋実機誤差を考慮して 250mAh に拡張（D5確定）

> **注記**: §14.2 の電流値は理論計算ベース。実測差分は Phase 5（PPK2 計測）で本仕様書をアップデート予定。

### 14.4 電力最適化施策(優先度順)

1. **DC/DCコンバータ有効化** (`CONFIG_BOARD_ENABLE_DCDC=y`)
2. **2M PHY** (`CONFIG_BT_AUTO_PHY_UPDATE=y`)
3. **System sleep / Deep sleep 対応** (`CONFIG_PM=y`)
4. **PDM/Opus を必要時のみON** (将来的にVAD実装)
5. **SD writeのバッチ化を維持**(WRITE_BATCH_COUNT=10、20KB毎fsync)

→ Omi DK1の `prj_xiao_ble_sense_devkitv1-spisd.conf` には既にこれらが設定されているはず。Claude Code で確認・追加。

---

## 15. ビルド方法

### 15.1 開発環境セットアップ

```bash
# 1. nRF Connect for VS Code Extension Pack をインストール
# 2. nRF Connect SDK Toolchain v2.7.0以降をインストール
# 3. nRF Connect SDK v2.7.0以降をインストール

# リポジトリclone
git clone https://github.com/BasedHardware/omi.git
cd omi/omi/firmware/devkit
```

### 15.2 ビルド手順

```bash
# DK1+SPISD構成でビルド(けんた案ベース)
west build -b xiao_ble/nrf52840/sense \
  -- -DCONF_FILE=prj_xiao_ble_sense_devkitv1-spisd.conf

# UF2に変換(Adafruit Bootloader用)
adafruit-nrfutil dfu genpkg \
  --dev-type 0x0052 \
  --application build/zephyr/zephyr.hex \
  Wearable_OTA_v0.1.zip
```

### 15.3 書き込み手順

1. XIAO Sense リセットボタンを2回素早く押す
2. PCで `XIAO-SENSE` ドライブが認識される
3. ビルドした `.uf2` ファイルをドラッグ&ドロップ
4. 自動でリセット・実行開始

### 15.4 既知の落とし穴

- **prj.conf が存在しない問題**(Issue #1045)
  - 対応: ビルドコマンドで `-DCONF_FILE=...` を明示する
- **ff.h が見つからない**(Issue #1047)
  - 対応: `prj_xiao_ble_sense_devkitv1-spisd.conf` に `CONFIG_FAT_FILESYSTEM_ELM=y` が含まれていることを確認

---

## 16. Phase 1 確認結果サマリ

このセクションは仮版時の「Claude Code 起動時の最初の作業」だったが、Phase 1 完了時点で **すべて検証・反映済み**。各章の確定値を見ること。

### 16.1 検証済み事項

| 確認対象 | 結果 | 反映先 |
|---|---|---|
| `prj_xiao_ble_sense_devkitv1-spisd.conf` | 全 CONFIG 値抽出済 | §5.4 |
| `src/codec.c` + `src/config.h` | Opus 設定値確定（32kbps, complexity=3, DTX=0, RESTRICTED_LOWDELAY）| §4.2 |
| `src/transport.c` | MTU=498, AUTO_PHY_UPDATE=y, write_to_storage 連携確認 | §5.1, §5.4, §6.3 |
| `src/sdcard.c` | ファイル名 `audio/a##.txt` 連番、WRITE_BATCH_COUNT/SD_FSYNC_THRESHOLD なし | §6.1, §7.1 |
| `src/storage.c` | `is_connected` ガードで Plan A 動作 | §6.3（Plan B改修対象） |
| `src/usb.c` | CDC ACM のみ、ファイル転送機能なし | §6.5（MSC新規実装） |
| `src/led.c` + `src/main.c` | 充電中=緑常時のみ、警告系 LED 未実装 | §11.2, §12（拡張対象） |
| `src/button.c` | D4 出力 + D5 入力（割込）構成 | §13.1 |
| `overlay/xiao_ble_sense_devkitv1-spisd.overlay` | SD CS=P0.28, MOSI=P1.15, MISO=P1.14, SCK=P1.13, 24MHz | §13.1 |
| `src/mic.c` | XIAO Sense 内蔵 PDM (MP34DT05) を使用 | §4.1 |
| `west.yml` | **omi に存在せず** → 自前 manifest 作成（NCS v2.9.0 import） | この repo の `west.yml` |

### 16.2 Phase 1 で発見した重要事項

- omi `firmware/devkit/CMakeLists.txt` は Opus ライブラリを **ソースバンドル** している（`src/lib/opus-1.2.1/` に150+ファイル）
- omi の Kconfig は `CONFIG_OMI_*` シンボルを定義（例: `CONFIG_OMI_CODEC_OPUS`, `CONFIG_OMI_OFFLINE_STORAGE`）
- omi リポジトリには **ファームウェア用 GitHub Actions CI が無い**（`docs/lint` 系のみ）→ Phase 2 で新規構築
- omi 全体サイズは 663MB（shallow clone でも）。Phase 4 で sparse-checkout 検討の余地あり

### 16.3 Phase 4 で発見した重要事項

実装中に omi 公式コードに以下の課題を発見した。けんたフォークではすべて回避済み。

- **omi `transport.c::pusher()` が単一 TX キューで排他消費**: BLE 送信に成功するとキューから取り出されてしまうため、SD への同時書き込みができない。Plan B 実現のため `app/patches/0001-plan-b-fanout-tx-queue.patch` でファンアウト構造に refactor（peek してから SD/BLE 両方へ書き、両方成功時のみ pop）
- **omi `sdcard.c` はファイルローテーションを実装していない**: `file_count = 1` がハードコードされており、起動するたびに同じ `audio/a01.txt` を上書きする欠陥がある。Phase 4-2 で `app/src/wr_chunk.c` を新規追加し、10分タイマーで `chunk_NNNNN.opus` にリネーム→新規 `a01.txt` 作成のフローを実装
- **omi `prj.conf` にタイポ**: `CONFIG_OFFLINE_STORAGE` と書かれていたが正しくは `CONFIG_OMI_ENABLE_OFFLINE_STORAGE`。けんたの `app/overlay/spisd-fixup.conf` で正しいシンボルに上書き
- **omi の DK1+SPISD prj.conf が機能不足**: `CONFIG_PM_DEVICE` / `CONFIG_WATCHDOG` / `CONFIG_FLASH` が抜けていてビルド/動作上必要だった。`spisd-fixup.conf` で追加
- **NCS v2.9 で `CONFIG_NRFX_PDM` が直接設定不可になった**: アクセスパスが内部化されたため、CI / west.yml を **NCS v2.7-branch コンテナ** にダウングレード（仕様書 §1.3 の v2.9.0推奨は実質 v2.7 ベースで運用）

---

## 17. 改修の実装順序(推奨)

### フェーズ1: 動作確認(まずDK1+SPISD相当を動かす)

1. ベース設定そのままでビルド・書き込み
2. XIAO Sense + 青microSDブレイクアウト で動作確認
3. PDMマイク → Opus → SD 書き込み の経路確認
4. Omiモバイルアプリで BLE 接続確認

### フェーズ2: けんた案への改修

1. 常時SD書き込みモードへの変更(§6.3 Plan B)
2. 32GB対応・FIFO 自動削除実装(§6.4)
3. USB Mass Storage実装(§6.5)
4. けんた向けLED通知ロジック追加(§11)
5. ボタン1つで電源ON/OFF + 録音制御(§2.1)

### フェーズ3: 電力測定と最適化

1. PPK2 または Joulescope で実測
2. 150 mAh で 20時間動くか検証
3. 必要に応じて BLE接続パラメータ調整、システム sleep最適化
4. バッテリー容量を 250 mAh に増やすか判断

### フェーズ4: スマホアプリ(後回し)

1. Omi 公式アプリ (Flutter) を fork
2. Googleドライブアップロード機能追加
3. Whisper連携(将来的にスマホ単体でも文字起こし)

---

## 18. リスクと対応

| リスク | 影響 | 対応 |
|---|---|---|
| ベース設定がそのまま使えない | フェーズ1停滞 | DK2用設定ファイルを参考に手動マージ |
| MSC実装が複雑 | フェーズ2停滞 | 当面はBLE経由でのみファイル取得、PCで定期受信 |
| 電力が予測より悪い | 20時間目標未達 | 200/250mAhバッテリー採用、Opusビットレート低減 |
| FAT32 実装の電源断破損 | データ損失 | fsyncを頻繁に行う、または LittleFSへ変更検討 |
| BLE再接続失敗 | スマホ転送失敗 | SD保存があるので最終的なデータ損失はなし |

---

## 19. 参考リンク

### Omi 公式

- リポジトリ: https://github.com/BasedHardware/omi
- ドキュメント: https://docs.omi.me/
- DK2 ハードウェア: https://docs.omi.me/doc/hardware/DevKit2
- DK2 README (BOM・組立): `omi/hardware/triangle v2 w memory/README.md`
- DK2 回路図: `omi/hardware/triangle v2 w memory/omi-dk2-schematics.pdf`

### 関連 Issue/PR

- Issue #1047: ビルドエラー(ff.h)
- Issue #1393: DK2 OTA対応
- Issue #752: Friend v2 onboard memory連携(賞金タスク)
- Issue #2815: DK2 電源OFF方法

### Nordic Semiconductor

- nRF Connect SDK ドキュメント: https://docs.nordicsemi.com/
- XIAO BLE Sense + Zephyr SD: https://devzone.nordicsemi.com/f/nordic-q-a/98746/

### XIAO ハードウェア

- Seeed Studio XIAO nRF52840 Sense: https://wiki.seeedstudio.com/XIAO_BLE/

---

## 20. 用語集

| 用語 | 説明 |
|---|---|
| DK1 | Omi DevKit 1(Friend、SDなし基本構成) |
| DK2 | Omi DevKit 2(SD+スピーカー+ボタン搭載) |
| CV1 | Omi Consumer V1(nRF5340+Wi-Fi、別物) |
| PDM | Pulse Density Modulation(マイク方式) |
| DTX | Discontinuous Transmission(無音時送信抑制) |
| FATFS | FAT File System の組み込み実装(ChaN製) |
| MSC | USB Mass Storage Class |
| GATT | Generic Attribute Profile(BLE上の属性プロファイル) |
| MTU | Maximum Transmission Unit |

---

## 21. 変更履歴

| 日付 | 内容 |
|---|---|
| 2026-04-26 | 初版作成（仮版）。Claude(チャット)とけんたさんの議論をもとに策定 |
| 2026-04-26 | Phase 1 確定版。omi リポジトリ実物検証 + 17項目決定（D1〜D17）反映。`shkentee/mozzy` の仕様書として運用開始 |
| 2026-04-26 | Phase 2 完了。GitHub Actions ビルド CI（NCS v2.7-branch コンテナ、UF2 アーティファクト出力） |
| 2026-04-26 | Phase 3 完了。Twister + native_sim サニティテスト（FIFO 閾値の単体テスト）|
| 2026-04-26 | Phase 4 完了（5サブタスク MVP）。Plan B / チャンクローテーション / FIFO / LED / USB MSC を実装。詳細は §22 / §16.3 参照 |
| 2026-04-26 | Phase 4-5+ 完了。`wr_led_pick()` 純化 + native_sim ztest 13本（§22.2）|
| 2026-04-26 | Phase 4-6+ 完了。`wr_chunk_logic` / `wr_fifo_logic` / `wr_msc_mode_logic` 純化 + ztest 約60本（§22.3、見かけ上の D6/D7/D8/D9 ロジックが Twister 緑で確認可能に）|
| 2026-04-26 | Phase 5+ 着手（CI scaffold のみ）。BabbleSim smoke ワークフロー追加（`.github/workflows/bsim.yml`、manual trigger）。実機検証 / 電力測定は引き続き Phase 5 本体タスク（§22.4）|
| 2026-04-26 | Phase 6 着手（skeleton のみ）。`app_mobile/` Flutter プロジェクト雛形（BLE スキャン / 接続 / `audioCodec` notify dump）（§22.5）|

---

## 22. Phase 4 実装状況

5 サブタスクの実装状況サマリ。残作業は Phase 5（実機検証）/ Phase 6（自前アプリ）に持ち越し。

| サブタスク | 仕様書参照 | 実装ファイル | 状態 | MVP 残作業 |
|---|---|---|---|---|
| 4-1 Plan B（常時SD書き込み）| §6.3 | `app/patches/0001-plan-b-fanout-tx-queue.patch` | ✅ 完了 | Phase 5 で実機検証（pusher() の SD 書き込み遅延 / ジッター測定）|
| 4-2 チャンクローテーション | §7.2 | `app/src/wr_chunk.c` + `wr_chunk_logic.c` | 🟡 MVP | 純粋ロジックは epoch / boot ID / unsynced / サイズ閾値まで完成（§22.3）。`performSyncTime()` 後のファイル生成パスへの配線のみ Phase 6 後半 |
| 4-3 FIFO 自動削除 | §6.4 | `app/src/wr_fifo.c` + `wr_fifo_logic.c` | ✅ 完了 | LEGACY/UNSYNCED/EPOCH 3-kind 削除順 + MSC short-circuit 済（§22.7 / §22.8）|
| 4-4 USB Mass Storage | §6.5 | `app/src/wr_msc_mode.c` + `wr_msc_mode_logic.c` + `app/overlay/spisd-fixup.conf` | 🟡 MVP | 起動時長押し検出 + runtime-mode 述語 + chunk/fifo short-circuit 完了（§22.8）。`usb_enable()` 実呼び出しのみ Phase 5 実機後 |
| 4-5 LED 状態マシン | §11.2, §12 | `app/src/wr_led_status.c` | ✅ 完了 | バッテリー ADC 読み取りフックは Phase 5（実機 + ハードウェア依存）|

### 22.1 メモリ予算（Phase 4 完了時点）

| リソース | 使用量 | 上限 | 使用率 | 余裕 |
|---|---|---|---|---|
| FLASH | 318,204 B | 788 KB | **39.43%** | 約 61% |
| RAM | 191,096 B | 256 KB | **72.90%** | 約 27% |

→ Phase 5/6 の追加実装（USB MSC ランタイム、ADC、Plan B 実機チューニング、Phase 6 で時刻管理拡張）に対しても十分な余裕あり。

---

### 22.2 Phase 4-5+: `wr_led_pick()` 純化 + LED ztest

LED 状態マシンを「純粋ロジック（優先度カスケード + ハートビート位相演算）」と「Zephyr グルー（タイマー + GPIO write）」に分離した。純粋部分は `app/src/wr_led_pick.c` / `app/include/wr_led_pick.h`、ファームと native_sim ztest 両方からリンクされる。

**成果物**
- `app/include/wr_led_pick.h` / `app/src/wr_led_pick.c`（pure picker）
- `app/src/wr_led_status.c`（純粋部分を呼ぶグルーに refactor）

**テスト**: `tests/firmware/wr_led/`（ztest 13本、native_sim）
- バッテリー警告の上書き優先度（crit > low > sd-full > sd-missing > charging > BLE/録音 HB > idle）
- batt-crit / batt-low / sd-missing のブリンク位相
- sd-full 赤 solid、charged 緑 solid、charging 黄 HB
- BLE-only / 録音-only / 両方ON 時の交互パターン
- バッテリー閾値境界（6%, 21%）

**コミット範囲**: `3b29e18` (`Phase 4-5+: extract wr_led_pick() pure picker + 12 ztest cases`)、`68e810b` (Twister 用 ztest 名前 prefix 修正)、`d72e22f` (未使用 const 整理)

**制約**: 実機 ADC 未配線（バッテリー残量はテストで擬似値を渡す）。GPIO 出力の実際の色味は実機 LED で要確認。

---

### 22.3 Phase 4-6+: wr_chunk / wr_fifo / wr_msc_mode の純化 + ztest

Phase 4-5+ と同じパターンで、残り 3 モジュールも「純粋ロジック」を切り出して native_sim ztest を追加した。

**成果物**

| モジュール | 純粋ヘッダ / 実装 | ztest |
|---|---|---|
| wr_chunk | `app/include/wr_chunk_logic.h` / `app/src/wr_chunk_logic.c` | `tests/firmware/wr_chunk/`（連番命名 / `should_rotate` 述語 / **epoch 命名 / unsynced_<bootid>_<seq> / boot ID 生成 / サイズ閾値ローテ** を含む 約30本超） |
| wr_fifo | `app/include/wr_fifo_logic.h` / `app/src/wr_fifo_logic.c` | `tests/firmware/wr_fifo/`（prune 述語 / `is_managed_chunk` / `compare_chunk` の 16本） |
| wr_msc_mode | `app/include/wr_msc_mode_logic.h` / `app/src/wr_msc_mode_logic.c` | `tests/firmware/wr_msc_mode/`（threshold 上下 / 全押し / ゼロ・負値防御 の 11本） |

**コミット範囲**: `ddaf161` (wr_chunk)、`cec8549` (wr_fifo)、`e5ce707` (header コメント修正)、`fc926c6` (wr_msc_mode)

**制約**:
- ファーム側（`wr_chunk.c` 等）から純粋ロジックへの呼び出し置き換えは最小限。動作変更はゼロ（refactor only、振る舞い同値）
- D7（UNIX_epoch / unsynced ファイル名）は **純粋ロジック側は完成**。`performSyncTime()` 後のチャンクファイル生成パスへの配線は Phase 6 で実施
- D9 の USB MSC `usb_enable()` 配線は引き続き Phase 5 実機検証後

---

### 22.4 Phase 5+: BabbleSim CI scaffold

Phase 5 の実機検証に先立って、Linux 上で **実 Zephyr Bluetooth ホスト + コントローラ** を 2.4 GHz 物理層シミュレータ（[BabbleSim](https://babblesim.github.io/)）に対して走らせる土台を整備した。Phase 6 で「omi GATT サービスに対する接続 / 切断 / MTU ネゴシエーション / チャンク push プロトコルの長時間挙動」を hardware-in-the-loop 抜きで回せる準備。

**成果物**
- `.github/workflows/bsim.yml`（manual trigger / `workflow_dispatch`、bsim を `bsim_west` manifest からビルド → smoke check）
- `docs/bsim-setup.md`（理由・スコープ分離・将来の `tests/bsim/wr_*/` 配置パターン）

**テスト**: 現時点は **smoke check のみ**（`bs_2G4_phy_v1` / `bs_device_handbrake` 等の bsim binary が `-help` を返すこと）。Zephyr-bundled の bsim test を NCS 上で直接コンパイルすると `nrfxlib/softdevice_controller` が `nrf52_bsim` の float ABI を CMake-reject するため、コントローラ差し替え（`CONFIG_BT_LL_SW_SPLIT=y` + SoftDevice 抑止）が必要。これは Phase 6 で `tests/bsim/wr_*/` 着手時に対応。

**コミット範囲**: `528659f` → `c879ad6` → `0deac40` → `d0f17f2` → `5e973ad` → `65e286b`（manifest URL / 32-bit toolchain / bsim_west の nested layout / ZEPHYR_BASE 退避 / apt deps / smoke 範囲縮退の一連）

**制約**:
- 自動 CI トリガーは無し（push / PR では走らない）。`make everything` が ~5 分かかるため、安定するまで manual のみ
- Zephyr/NCS bsim テスト本体（`tests/bsim/wr_*/`）は **未作成**。Phase 6 で omi の audio / DFU / accel GATT を 2 デバイス間で叩くシナリオを追加予定
- 実機との等価性は **未保証**（bsim はロジック検証用、電力やラジオの実物特性は PPK2 + 実機のみで検証）

---

### 22.5 Phase 6 着手: `app_mobile/` Flutter skeleton

D17（自前ミニマルスマホアプリ）の雛形に着手。Phase 6 本体（Google Drive アップロード / Foreground Service / Storage GATT 経由の一括取得）に向けた **接続 + audioCodec notify dump** までの最低限を実装。

**成果物**
- `app_mobile/pubspec.yaml`（`flutter_blue_plus` / `permission_handler` / `path_provider`、Flutter SDK ≥3.24 / Dart ≥3.5）
- `app_mobile/lib/main.dart` + `lib/pages/scan_page.dart` / `device_page.dart`（BLE スキャン → 接続 → 状態表示）
- `app_mobile/lib/services/wr_uuids.dart`（仕様書 §5.1 の omi GATT UUID 一覧の Dart 定義）
- `app_mobile/lib/services/wr_ble_scanner.dart` / `wr_ble_device.dart`（接続管理）
- `app_mobile/lib/services/wr_audio_packet.dart` / `wr_packet_sink.dart`（audioCodec notify を `path_provider` のドキュメント領域へ生バイト dump、PC 側 Whisper パイプラインに引き渡す前提）

**テスト**: 現時点は **none**（`flutter test` 雛形はあるが実機 BLE 依存のため CI 化は Phase 6 後半）。

**コミット範囲**: `2fee03e` (`Phase 6 着手: minimal Flutter mobile-app skeleton`)、その後 `wr_audio_packet.dart` / `wr_packet_sink.dart` 追加と `device_page.dart` / `wr_ble_device.dart` の packet sink 配線（このセクションが書かれた時点で `app_mobile/` ディレクトリは並行 agent が作業中）

**制約**:
- **実機未到着のため未検証**: BLE スキャンが実 wearable-recorder デバイスを発見できるか、notify ペイロードが §5.1 の UUID で取れるか、Android 13+ / iOS 17+ の権限プロンプトが正しく出るか
- Storage GATT (`30295780`) 経由の未送信ファイル一括取得は **未実装**（接続後の audioCodec ストリーミングのみ）
- `performSyncTime()` 互換の時刻同期送信は **未実装**（Phase 6 で追加、§22.3 の D7 配線とセット）
- Google Drive アップロード / Foreground Service / バックグラウンド常時接続は Phase 6 後半

---

### 22.6 Phase 5+ bsim: `wr_smoke` を bs_2G4_phy_v1 で実走 + `wr_link` 2-device GATT verdict

§22.4 の段階では bsim binary の `-help` 起動確認止まりだった bsim CI を、**実際に Zephyr アプリを `bs_2G4_phy_v1` 上で走らせる** ところまで前進させた。さらに後続コミットで **2 デバイス（peripheral + central）の GATT 接続 verdict** まで拡張。

**成果物（5 段階構成の bsim CI）**
1. bsim binary `-help`（基底環境チェック）
2. `tests/bsim/wr_smoke/test_scripts/_env.sh` / `_compile.sh` / `run_smoke.sh`（Zephyr v3.6 bsim 慣例。`west build` で `nrf52_bsim` ビルド → `zephyr.exe`/`.elf` を `${BSIM_OUT_PATH}/bin` に test-id 名でコピー、device + `phy_2G4_v1` で起動 / 60s wall-clock cap、sim 時間は約5秒）
3. `wr_smoke` run（1 デバイス smoke、上記スクリプトで verdict）
4. `tests/bsim/wr_link/`（**同一バイナリが `bs_tests -testid` で peripheral / central どちらにも切り替わる**: peripheral は omi audio service UUID を advertise → 接続受領で PASS、central は scan → connect で PASS。`bs_tests` 標準フレームワーク（`test_post_init_f` / `test_tick_f` / `test_main_f`）+ 15s sim-time timeout で fail 化、`CONFIG_BT_LL_SW_SPLIT` で nrfxlib SoftDevice を gating）
5. `wr_link` run（2 デバイス、90s wall-clock cap = 15s sim + 2 デバイスビルドの slack）

**コミット**: `a7f3370`（`Phase 5+ bsim: actually run wr_smoke under bs_2G4_phy_v1`）、`eff39bb`（`Phase 5+ bsim wr_link: 2-device peripheral+central GATT link verdict`）

**制約**:
- `nrfxlib/softdevice_controller` の float ABI 制約は引き続き存在 → `CONFIG_BT_LL_SW_SPLIT=y` でゲート（`wr_smoke` / `wr_link` 共通）
- 実機との等価性は **未保証**（bsim はロジック検証専用。電力 / ラジオ実物特性は PPK2 + 実機のみ）

---

### 22.7 Phase 6: `wr_fifo classify` + LEGACY/UNSYNCED/EPOCH の削除優先度

D8 の最古削除は §22.3 までフラット strcmp ベースだったが、Phase 6 の 3 種類のファイル名スキーマ（連番 `chunk_NNNNN.opus` / `unsynced_<bootid8hex>_<seq5>.opus` / `<10digit_unix_secs>.opus`）が並存すると、ASCII 順では `'0'..'9' < 'a'..'z'` なので **新しく書かれた EPOCH ファイルが古い legacy/unsynced より先に消される** バグになる。これを総順序つき `classify` + `compare_priority` に置き換えた。

**成果物**
- `app/include/wr_fifo_logic.h` に `wr_fifo_kind_t { LEGACY, UNSYNCED, EPOCH, UNKNOWN }` 追加
- `wr_fifo_classify(name)` 純関数（EPOCH は **必ず 10 進 10 桁 + ".opus"** を要求）
- `wr_fifo_compare_priority(a, b)` 純関数（**LEGACY < UNSYNCED < EPOCH** の総順序、同 kind 内は strcmp で creation 順）
- `wr_fifo_find_oldest()` を `classify`（UNKNOWN は skip）+ `compare_priority` ベースに差し替え。録音中ファイルの skip は引き続き strcmp で先に弾く
- 旧 `wr_fifo_is_managed_chunk` / `wr_fifo_compare_chunk` は backward compat で温存

**テスト**: `tests/firmware/wr_fifo/src/main.c` に **18 ztest 追加**
- 9 本: `wr_fifo_classify`（LEGACY / UNSYNCED / EPOCH ×3 / 桁数違い / garbage / `chunkfoo` / NULL / 空文字）
- 9 本: `wr_fifo_compare_priority`（同 kind 内 ×3 / kind 間 ×3 + 対称性チェック / NULL safety）

**コミット**: `9620dcb`（`Phase 6: wr_fifo classify + priority order across legacy/unsynced/epoch filenames`）

**制約**: 純粋ロジック完成。実機 SD 上での long-run 削除挙動は Phase 5 で検証。

---

### 22.8 Phase 6: `wr_msc` runtime-mode decision + chunk/fifo short-circuit

「起動時に MSC モードに入ったら録音系を止める」分岐を、各サブシステムが個別に再導出するのをやめて `wr_msc_mode_logic` に集約。chunk rotation と FIFO prune の **MSC 競合（fs_rename / fs_unlink が USB MSC スタックと FAT を同時に触るレース）** を予防する短絡が入る。

**成果物**
- `app/include/wr_msc_mode_logic.h`:
  - `wr_msc_runtime_mode_t { RECORDING, USB_MSC }` + `wr_msc_runtime_mode(boot_flag)`
  - 述語群（すべて純関数）:
    - `wr_msc_should_suppress_recording(mode)`
    - `wr_msc_should_enable_usb_msc(mode)`
    - `wr_msc_should_enable_chunk_rotation(mode)`
    - `wr_msc_should_enable_fifo_pruning(mode)`
  - `wr_msc_led_hint_for(mode)`（MSC 時は **slow_blue_blink** ヒント）
- `app/src/wr_chunk.c::wr_chunk_rotate()`: MSC モード中は no-op + `LOG_INF`（fs_rename を打たない）
- `app/src/wr_fifo.c::wr_fifo_check()`: MSC モード中は no-op + `LOG_INF`（fs_unlink を打たない）
- `wr_msc_mode.c` 自体は変更なし（`usb_enable()` の実発行は引き続き Phase 5 実機後）
- 述語呼び出しは `wr_msc_mode_is_active()` の forward extern 経由（公開ヘッダ依存を増やさない）

**テスト**: `tests/firmware/wr_msc_mode/src/main.c` に **13 ztest 追加**（両 mode × 各述語 / LED ヒント / round-trip composition）

**コミット**: `fd7fb4e`（`Phase 6: wr_msc runtime-mode decision + chunk/fifo MSC short-circuit`）

**制約**: LED 配線（`slow_blue_blink` ヒントを `wr_led_pick` に流す）は Phase 5 実機後。`usb_enable()` の実呼び出しは §22.17 で完了。

---

### 22.9 PC 側ツール `tools/decode-dump.py` + `tools/power-predict.py` + `tools` CI

Phase 6 後半（Whisper パイプライン）+ Phase 5 実機電力検算に向けた PC 側スクリプト群と専用 CI を追加。

**成果物 1: `tools/decode-dump.py`**

`app_mobile/lib/services/wr_packet_sink.dart` が吐くバイナリ dump（**3-byte omi header + Opus payload を verbatim で連結、長さ prefix なし**）を PC 側で復号する stdlib-only ツール。

- パケット境界は **次の expected-successor header**（`packet_id + 1`, `frame_id == 0`）でスキャン、BLE 再接続による不連続は bounded-jump フォールバック
- 出力: `<prefix>.json`（`{packet_id, frame_id, payload_hex, offset_in_file, payload_len}` の manifest）+ `<prefix>.opus`（header を剥いだ raw Opus 連結）
- `--wav` は best-effort（実行時に `pyogg` / `opuslib` を try import、ハード依存にしない）
- 不連続（packet_id ジャンプ / frame_id 欠け）は INFO ログで surface
- `tools/test_decode_dump.py`: **7 pytest**（happy path / 出力ファイル生成 / 1 packet_id 内マルチフレーム / 非単調 packet_id 検出 / 空入力 / warn-default と `strict=True`）

**成果物 2: `tools/power-predict.py`**

§14.2 の電力見積もり（3.2-3.7 mA → 250 mAh で 67-78 h）を **CLI で再現 + what-if 検証** できる pre-Phase-5 リファレンスモデル。PPK2 到着前に「バッテリー違い / 録音 duty 違い / BLE オーバーヘッド違い」の効きを試せる。

- pure-stdlib（`argparse` / `json` / `dataclasses` / `math`、PyYAML 不要）
- モデル: `avg = (pdm+codec+ble)*record_duty + sd*sd_duty + led + mcu_idle*(1-record_duty)`
- デフォルト出力: **3.71 mA / 67.4 h / 2.81 days**（§14.2 と一致）
- `--fail-under-target` で CI ガード化可能（デフォルト OFF）、`--target-hours` で §14.3 の 20h ベースラインを上書き
- `tools/test_power_predict.py`: **10 pytest**（spec デフォルト一致 / 線形バッテリースケール / record-duty 半減でほぼ倍寿命（1.89×解析） / `sd_write_duty=1.0` での寿命崩壊 / 全 0 ガード / 充電オフセット → 無限寿命センチネル / `--fail-under-target` の exit code）

**成果物 3: CI**

- `.github/workflows/tools.yml`（**`tools` workflow**、ubuntu-latest / Python 3.11、`tools/**` 変更で push/PR トリガー + manual dispatch、他 workflow には触らない）
- `tools/README.md`（両ツールの使い方 + `pip install pyogg` opt-in + Phase 5 実機後の retune note）

**テスト**: 計 **17 pytest 全 green**（Phase 5+ bsim とは独立 CI）。

**コミット**: `4424dc7`（`tools: PC-side dump decoder + pytest CI`）、`3369ef0`（`tools: power consumption predictor + pytest cases`）

**制約**:
- `decode-dump.py`: Opus → WAV はハード依存にしていないので、デフォルトでは `.opus` 連結止まり。BLE 再接続時の連番ロスは検出のみ（補完はしない）
- `power-predict.py`: あくまでモデル値。Phase 5 で PPK2 計測値が出たらデフォルト mA を再フィット（README に明記）

---

### 22.10 関連ファイル

| 新規ファイル | 役割 |
|---|---|
| `app/patches/0001-plan-b-fanout-tx-queue.patch` | omi `transport.c::pusher()` のファンアウト refactor |
| `app/patches/0002-cmake-add-app-sources.patch` | omi の CMakeLists.txt に app/src/*.c をビルド対象として追加 |
| `app/overlay/spisd-fixup.conf` | omi prj.conf の typo 修正・抜け CONFIG 補完・MSC 関連 CONFIG 追加 |
| `app/src/wr_chunk.c` + `app/src/wr_chunk_logic.c` + `app/include/wr_chunk_logic.h` | 10分タイマー → ファイルリネーム → 新ファイル作成 + 純粋ロジック（命名 / 述語 / boot ID / epoch / unsynced / size 閾値）+ MSC short-circuit |
| `app/src/wr_fifo.c` + `app/src/wr_fifo_logic.c` + `app/include/wr_fifo_logic.h` | 1分ごとに `fs_statvfs`、空き<10% で最古 chunk を unlink + 純粋述語 + LEGACY/UNSYNCED/EPOCH classify + 削除優先度 + MSC short-circuit |
| `app/src/wr_led_status.c` + `app/src/wr_led_pick.c` + `app/include/wr_led_pick.h` | 100ms tick の警告優先 + ハートビート LED 状態マシン + 純粋 picker |
| `app/src/wr_msc_mode.c` + `app/src/wr_msc_mode_logic.c` + `app/include/wr_msc_mode_logic.h` | 起動時 D5 長押し検出 → `wr_msc_mode_is_active()` フラグ + 純粋判定 + runtime-mode 述語群 + LED ヒント |
| `tests/firmware/sanity/` | Twister + native_sim FIFO 閾値テスト（Phase 3 オリジナル）|
| `tests/firmware/wr_led/` | LED picker ztest（13本、Phase 4-5+）|
| `tests/firmware/wr_chunk/` `tests/firmware/wr_fifo/` `tests/firmware/wr_msc_mode/` | 純粋ロジック ztest 群（Phase 4-6+ + Phase 6 追加分: wr_fifo +18 / wr_msc +13）|
| `tests/bsim/wr_smoke/test_scripts/` | bsim `wr_smoke` の `_env.sh` / `_compile.sh` / `run_smoke.sh`（Phase 5+ 1-device 実走）|
| `tests/bsim/wr_link/` | bsim `wr_link` 2-device peripheral+central GATT verdict（同一バイナリ + `bs_tests -testid` で切替）|
| `tools/decode-dump.py` + `tools/test_decode_dump.py` | PC 側 BLE notify dump デコーダ（stdlib-only、7 pytest 付）|
| `tools/power-predict.py` + `tools/test_power_predict.py` | 電力モデル CLI + 10 pytest（§14.2 デフォルト一致）|
| `tools/README.md` | tools/ 群の使い方 + Phase 5 retune note |
| `.github/workflows/build.yml` | firmware-build CI（NCS v2.7-branch、UF2 + ztest）|
| `.github/workflows/bsim.yml` | BabbleSim CI（manual trigger、5 stage: -help → wr_smoke compile/run → wr_link compile/run）|
| `.github/workflows/bsim-nightly.yml` | bsim nightly trigger（`bsim.yml` を呼び出す）|
| `.github/workflows/mobile.yml` | Flutter mobile app 用 CI |
| `.github/workflows/tools.yml` | `tools/` の pytest CI（ubuntu-latest / Python 3.11、Phase 6）|
| `app_mobile/`（Flutter skeleton）| Phase 6 自前ミニマルスマホアプリの雛形（BLE スキャン → 接続 → audioCodec notify dump）|
| `docs/bsim-setup.md` | bsim 設計メモ（CI 構成・将来の bsim test 配置）|
| `docs/phase5-quickstart.md` | Phase 5 実機 bring-up 手順（けんたさん向け 3 分版）|
| `docs/phase6-plan-draft.md` | Phase 6 着手 TODO ドラフト |

---

### 22.11 Phase 6: Mobile widget tests + Android APK CI

§22.5 で skeleton 化した `app_mobile/` に **Flutter widget テスト**を追加し、`mobile.yml` workflow を **flutter-test + android-apk** の 2 ジョブ構成に拡張した。「実機 BLE がなくても UI ロジックの回帰検出ができる」「PR ごとに署名なし debug APK が artifact として落とせる」状態を作る。

**成果物 1: widget テスト（`app_mobile/test/`）**

- `scan_page_test.dart`: **4 widget テスト**（empty-state ヒント表示 / `ScanResult` ストリームに対する `ListTile` レンダリング / scan ストリーム error 時の赤バナー / タップ → 接続フロー遷移）。`mocktail` で `WrBleScanner` を差し替え、platform channel を一切踏まない
- `device_page_test.dart`: **5 widget テスト**（connect 中の "connecting…" 表示 / 接続状態ストリーム遷移 / `packetCount` ストリーム → カウンタ更新 / `bytesSaved` ストリーム → 表示更新 / `connect()` 例外時のエラーステータス）。`pumpAndSettle()` で setState チェーンの 1 フレーム遅延を吸収
- 既存の `wr_audio_packet_test.dart`（9 ケース）/ `wr_packet_sink_test.dart`（7 ケース）と合わせ **計 25 Dart テスト**

**成果物 2: `android-apk` ジョブ（`.github/workflows/mobile.yml`）**

- ubuntu-latest + Temurin JDK 17 + Flutter 3.24（AGP 8.x 互換）
- `flutter create --platforms=android` で android scaffold を **CI 上で都度生成**（gradle wrapper / proguard / keystore を git に持たない方針、`app_mobile/.gitignore` で除外）。`flutter create` が落とす stub `test/widget_test.dart` は即削除（`MyApp` 参照で `flutter analyze` が落ちる）
- `android/settings.gradle` の `org.jetbrains.kotlin.android` を **1.7.10 → 1.9.24** に sed bump（推移依存の annotation-jvm 1.9.1 が metadata 1.9.0 で出力するため）
- `AndroidManifest.xml` に `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` / `ACCESS_FINE_LOCATION` を Python スクリプトで `<application>` 直前に注入
- `~/.pub-cache/.../flutter_blue_plus_android-7.0.4/android/build.gradle` の `compileSdkVersion = flutter.compileSdkVersion` を **`= 34` リテラルに sed パッチ**（Flutter 3.24 scaffold で `flutter` android-extension property が消えたため）
- `flutter build apk --debug` → 約 **84 MB** の `app-debug.apk` を `wearable-recorder-debug-${sha}` artifact として 14 日保存

**コミット**: `bda0c54`（android scaffold + APK artifact）/ `c5d5181`（stub `widget_test.dart` 削除）/ `41665fc`（`flutter_blue_plus_android` gradle パッチ）/ `12f18e7`（Kotlin plugin 1.9.24 bump）/ `cdbc880`（`pumpAndSettle` for state-stream widget tests）/ `7fe036c`（`pumpAndSettle` for packetCount + bytesSaved）

**制約**:
- **debug APK のみ**（署名鍵を CI に持ち込まない方針、release APK は Phase 6 後半）
- Android scaffold は CI 都度再生成のため、generator 出力が変わると CI が壊れる可能性あり（Flutter SDK バージョンを `3.24.0` 固定で吸収）
- iOS ジョブは未追加（Phase 6 後半、macOS runner コスト判断後）

---

### 22.12 Phase 6: PC 側 decoder `--wav` Opus 実復号 + `power-predict.py`

§22.9 で stdlib-only の `tools/decode-dump.py` を入れた段階では `--wav` は best-effort（pyogg / opuslib がなければスキップ）だったが、**実際の Opus → PCM → WAV 復号パスを `opuslib` で実装**して PR ごとに pytest で検証できるようにした。`tools/power-predict.py` も §22.9 で導入済（10 pytest）。

**成果物**

- `tools/decode-dump.py` `--wav`:
  - omi は **1 BLE notify あたり 1 Opus フレーム**を吐くので Ogg framing は不要 → `opuslib.Decoder` を per-packet payload boundary で直接呼ぶ
  - `--rate` フラグ（デフォルト 16000 Hz）で PDM サンプリングレート上書きに対応
  - **decoder 未 import 時の優雅な縮退**: パケット 0 件なら header-only WAV / データありなら WAV スキップ、いずれも warn ログ + `exit 0` で `tools.yml` の依存ゼロ方針を維持
  - `pyogg` は pre-wrapped Ogg コンテナ用の fallback として保持
- `tools/test_decode_dump.py`: **+5 ケース**（decoder import 失敗 with packets / 同 no packets / `--rate` propagation / end-to-end CLI exit-0 / `pytest.importorskip` で gating した opuslib roundtrip）→ §22.9 の 7 ケースと合わせ **12 ケース**
- `tools/README.md`: "Decoding to WAV" → "Opus decode (`--wav`)" に書き換え（`opuslib` OR `pyogg` install / 16-bit mono 16 kHz / `--rate` 上書きを明記）

**コミット**: `a267d65`（並走 agent staging race により decoder 本体は載らず、誤って `app_mobile/test/*` が staged されたメッセージ違いコミット）/ `54353a0`（実体: `tools/decode-dump.py` + `test_decode_dump.py` + `tools/README.md`）

**制約**:
- `opuslib` は `tools.yml` の **CI 必須依存にしない**（README で `pip install opuslib` を opt-in 案内、CI は decoder 不在でも green）
- BLE 再接続による `packet_id` ジャンプは検出のみで補完しない（§22.9 制約継続）
- §14.2 の電力モデルは PPK2 計測値で再フィット予定（§22.9 制約継続）

---

### 22.13 OSS readiness: `CONTRIBUTING.md` / PR・Issue templates / `LICENSE` (MIT)

リポジトリ public 化と外部コントリビューション受付に向けて GitHub 標準の community files を整備した。

**成果物**

- `LICENSE`: **MIT**（けんた改修部分。omi 部分は元の MIT ライセンスを継承するので whole-repo MIT で整合）
- `CONTRIBUTING.md`: ブランチ運用 / コミットメッセージ規約（Phase prefix）/ ローカルビルド手順 / ztest と pytest の走らせ方 / submodule (`third_party/omi`) を触らない原則 / レビュアー期待値
- `.github/PULL_REQUEST_TEMPLATE.md`: 変更概要 / 対応 Phase / テスト結果 / リスク・ロールバック手順
- `.github/ISSUE_TEMPLATE/bug.yml` / `feature.yml` / `task.yml`: Issue Forms 形式（Phase / 影響範囲 / 再現手順 を必須化）
- `.github/CODEOWNERS`: 全パスを `@shkentee` に default 振り

**コミット**: `7dd7939`（`docs: CONTRIBUTING + PR/issue templates + LICENSE for community readiness`、7 file / +368 行）

**制約**:
- `CODEOWNERS` は単一オーナー（Phase 5 以降 reviewer 増員時に再分割）
- README の "ライセンス" セクションは MIT を明示（§22.14 の README rev で更新）

---

### 22.14 Phase 5+ bsim wr_link v2: notify exchange 達成（peripheral GATT + central subscribe + 7-byte sentinel 受信）

§22.6 で「2 デバイス GATT 接続 verdict」まで進んだ `wr_link` を、**peripheral GATT service 公開 + central scan/connect/discover/subscribe + notify ペイロード受信**までエンドツーエンドで通すことに成功した。一度 §22.14 旧版（`23c1818`）で kernel panic により revert（`ed47783`）したが、`bt_conn_cb_register()` 動的版で v2 として再構築し最終 green。

**達成内容**

- peripheral 側: `BT_GATT_SERVICE_DEFINE` で omi audio service を 1 本公開し、`audioCodec` characteristic（notify、UUID `19b10002-...`）に **3-byte omi header + "ABCD" の 7-byte sentinel** を `bt_gatt_notify` で送信
- central 側: scan → connect → `bt_gatt_discover` でサービス + characteristic 探索 → `bt_gatt_subscribe` で CCC 書き込み → `notify_cb` 初回発火で PASS
- ロール分岐: `BT_CONN_CB_DEFINE` 廃止 → `bs_test_post_init_f` で testid を見て自ロール用 callback だけ `bt_conn_cb_register()` で登録（同一 ELF / 両ロール混在問題を解消）
- 所要時間: bsim 上で **1 秒未満で notify exchange 完了**（`peripheral=0 central=0 phy=0` で `wr_link run: PASSED`）

**試行錯誤の経緯**（v2 で踏んだ罠）

1. `BT_CONN_CB_DEFINE` 起因の kernel panic → `bt_conn_cb_register()` 動的登録版に移行（`1ffbfb1`）
2. peripheral が CCC subscribe 前に notify を撃って central が受け取れず → CCC subscribe 完了待機後に発火（`7611749`）
3. characteristic discover で end_handle 0 → `svc->end_handle` を流し込み（`5f476a5`）→ それでも検出失敗で全範囲スキャン簡略化（`994c4e9`）→ `DISCOVER_ATTRIBUTE` 経由を試行（`f0a5c31`）
4. 最終的な鍵は **`BT_GATT_DISCOVER_CHARACTERISTIC` の `uuid` filter は chrc 宣言の UUID（汎用 chrc UUID）と比較する**仕様だった点。uuid=NULL で全 chrc を歩いて callback 内で `chrc->uuid`（= 値側の UUID）を比較する Zephyr 公式パターンに切替えて green（`0f11a1d`）

**確認ログ**

```
peripheral: sent 7 byte notify
central: notify received (7 bytes)
peripheral=0 central=0 phy=0
wr_link run: PASSED
```

**コミット系譜**: `23c1818`（v1 実装）→ `ed47783`（v1 revert）→ `1ffbfb1`（v2 動的 conn cb）→ `7611749`（CCC 待機）→ `5f476a5` / `994c4e9` / `f0a5c31`（discover 試行）→ `0f11a1d`（**最終 green**）

**現状**:
- `wr_link` は §22.6 の接続 verdict + notify exchange エンドツーエンド検証まで到達
- bsim CI 上で GATT notify 経路が常時 green。multi-notify burst / backpressure 計測は別 issue で追跡

---

### 22.15 Phase 6: D7 配線 — epoch/unsynced ファイル名を runtime に適用

D7（`<UNIX_epoch>.opus` / `unsynced_<bootid8hex>_<seq5>.opus`）の純粋ロジックは §22.3 で完成済みだったが、runtime の `wr_chunk.c` はまだ旧来の `chunk_NNNNN.opus` 命名を使っていた。このセクションでその配線を完了させた。

**成果物**

- `app/src/wr_time_sync.c`（新規）:
  - UUID `19B10005-E8F2-537E-4F6C-D104768A1214` の **二次 GATT サービス** を `BT_GATT_SERVICE_DEFINE` で登録
  - `BT_GATT_CHRC_WRITE_WITHOUT_RESP` characteristic を 1 本: 8 バイト LE64 Unix 秒を受信
  - 受信後 `wr_chunk_set_sync_time(uint64_t unix_secs)` を呼び出す
  - `third_party/omi/` は一切変更しない（Zephyr は複数 `BT_GATT_SERVICE_DEFINE` をサポート）

- `app/src/wr_chunk.c`（更新）:
  - `wr_chunk_sync` 静的 struct（`sync_time_secs` / `sync_uptime_ms` / `is_synced` / `boot_id`）を追加
  - `wr_chunk_set_sync_time(uint64_t)`: 受信値と `k_uptime_get()` を記録、`is_synced = true` にセット
  - `wr_chunk_build_target()`: 同期済みなら `wr_chunk_format_epoch_name(sync_secs + elapsed_s)`、未同期なら `wr_chunk_format_unsynced_name(boot_id, seq)`
  - `wr_chunk_init()`: 起動時に `wr_chunk_make_boot_id(k_cycle_get_32(), sys_rand32_get())` で `boot_id` を 1 度だけ生成
  - `wr_chunk_rotate()`: 旧 `wr_chunk_format_name()` 呼び出しを `wr_chunk_build_target()` に置き換え

- `app/patches/0002-cmake-add-app-sources.patch`（更新）:
  - `wr_time_sync.c` を `target_sources` に追加

- `tests/firmware/wr_chunk/src/main.c`（更新）:
  - `test_chunk_unsynced_name_format`: `(0xdeadbeef, 3)` → `/SD:/audio/unsynced_deadbeef_00003.opus`
  - `test_chunk_epoch_name_format`: `1714180000` → `/SD:/audio/1714180000.opus`
  - 既存テストと値が重複しないスポットチェック（Flutter アプリが送信する値に一致する固定値で確認）

**動作フロー（D7 完全配線後）**

1. 起動直後: `is_synced = false`、ローテーション時は `unsynced_<boot_id>_<seq>.opus` で保存
2. Flutter アプリが UUID `19B10005-...` に 8 バイトを Write Without Response
3. `wr_time_sync_write()` → `wr_chunk_set_sync_time(unix_secs)` → `is_synced = true`
4. 次のローテーション: `unix_secs + (k_uptime_get() - sync_uptime_ms) / 1000` を epoch として命名

**制約**

- `sync_uptime_ms` は `k_uptime_get()` (ms 精度) ベースのため、±1 秒の誤差あり（Whisper 文字起こし用途では許容範囲）
- 衝突プローブは `sync_time_secs++` でナッジするため、連続 epoch 衝突時に秒数がずれる（実運用上は 10 分ごとのローテーションで衝突は極めて稀）
- `sys_rand32_get()` は Zephyr の entropy ドライバが必要（nRF52840 は HW RNG 搭載のため問題なし）

**コミット**: `feat(firmware): D7 wire epoch/unsynced filename at runtime via wr_time_sync GATT write`

---

### 22.16 Phase 6: D5 バッテリー ADC — 純粋計算層

D5（バッテリー 250 mAh 一本、SAADC 測定）の純粋計算部分（Zephyr 非依存）を実装した。

**成果物**
- `app/include/wr_battery.h`:
  - `wr_battery_raw_to_mv(int16_t raw_adc) → uint16_t`: SAADC raw → mV 変換  
    SAADC 設定: gain=1/4, Vref=0.6V, VBATT/2 分圧 → `raw * 4800 / 4096`
  - `wr_battery_mv_to_pct(uint16_t vbat_mv) → uint8_t`: mV → 0-100% 変換  
    LiPo 線形近似: 3000 mV (0%) – 4200 mV (100%); 端点クランプ
- `app/src/wr_battery.c`: 上記 2 関数の実装

**テスト**: `tests/firmware/wr_battery/` — **15 ztest**
- ゼロ/負値クランプ、フルスケール、中点
- LiPo 空 (raw=2560 → 3000 mV)、LiPo 満充電 (raw=3584 → 4200 mV)
- pct クランプ (over/under)
- パイプライン 3 点: raw=3072 → 3600 mV → 50%

**制約**: Zephyr SAADC glue（`zephyr/drivers/adc.h`、DT overlay、`wr_led_status.c` への hook）は Phase 5 実機 bring-up 後。

**コミット**: `4623ff5`（`feat(D5): wr_battery pure ADC math + 15 ztest`）

---

### 22.17 Phase 6: D9 完了 — `usb_enable()` runtime 呼び出し + omi audio stack ゲート

§22.8 で構築した runtime-mode 述語に続き、USB MSC の実際の USB スタック起動とファームウェア録音側の短絡を完了させた。

**成果物**
- `app/src/wr_msc_mode.c`（更新）:
  - `#include <zephyr/usb/usb_device.h>` 追加
  - `wr_msc_mode_flag = true` のタイミングで `usb_enable(NULL)` を呼び出し
  - `-EALREADY` は正常として無視（`CONFIG_USB_DEVICE_INITIALIZE_AT_BOOT=n` 構成で重複呼び出し対策）
  - `CONFIG_UART_CONSOLE=y` により omi の `init_usb()` は status callback の登録のみ（`usb_disable()/re-enable` を行わない）ためコンフリクトなし
- `app/patches/0003-msc-mode-gate-audio.patch`（新規）: omi の `main.c` に3ハンクを適用
  1. `extern bool wr_msc_mode_is_active(void);` を `LOG_MODULE_REGISTER` 直後に挿入
  2. MSC モードでなければ録音スタック（transport + codec + mic 初期化）を実行する `if (!wr_msc_mode_is_active())` 分岐を追加
  3. `else` ブロックで 3×青 LED 点滅（0.5s ON/OFF）+ `LOG_INF("USB MSC mode active: recording stack disabled.")` を追加し main loop（watchdog_feed）へフォールスルー

**動作フロー（D9 完全実装後）**
1. 起動: `wr_msc_mode_boot_detect()` が D5 (P0.05) を 1 秒間サンプリング
2. 80/100 以上 HIGH → `wr_msc_mode_flag = true`、`usb_enable(NULL)` でホストに USB MSC を公開
3. `main()` 到達時: `if (!wr_msc_mode_is_active())` = false → 録音スタックをスキップ
4. 3×青 LED 点滅後に main loop へ — watchdog は継続給電、SD は USB MSC で直接アクセス可能

**コミット**: `3a12569`（`feat(D9): usb_enable in wr_msc_mode + 0003 gate-audio patch`）

---

### 22.18 Phase 6: Mobile Google Drive uploader + time-sync GATT write

Flutter モバイルアプリに Google Drive アップロード機能（D17）と D7 time-sync 自動送信を追加した。

**成果物**
- `app_mobile/lib/services/wr_drive_uploader.dart`（新規）:
  - `WrDriveUploader` — `google_sign_in` + `googleapis` Drive v3 を使って録音ファイルを "wearable-recordings/" フォルダにアップロード
  - `WrDriveUploader.withApi(DriveApi)` テスト用コンストラクタ（BLE / Sign-in フローを完全にモック可）
  - フォルダ ID をインスタンス内にキャッシュし、複数アップロードで `files.list()` を1回のみ呼ぶ
  - MIME type: `audio/ogg; codecs=opus`
- `app_mobile/lib/pages/device_page.dart`（更新）: FloatingActionButton "Upload to Drive" + `_uploading` フラグ + `_uploadToDriver()` メソッド
- `app_mobile/lib/services/wr_uuids.dart`（更新）: `timeSyncService` / `timeSyncChar` = `19b10005-e8f2-537e-4f6c-d104768a1214`
- `app_mobile/lib/services/wr_ble_device.dart`（更新）:
  - `connect()` 完了後に `_trySendTimeSync(services)` を自動呼び出し
  - `_trySendTimeSync()`: time-sync サービスが存在すれば現在 epoch を 8 バイト LE64 WRITE_WITHOUT_RESP で送信。サービスが見つからない場合はサイレントスキップ（旧ファームウェア互換）
  - `epochToBytes(int epochSecs) → List<int>`: LE64 エンコーダ（static、unit test 可能）

**テスト**
- `test/wr_drive_uploader_test.dart`: 6 シナリオ（フォルダ作成・既存再利用・ID キャッシュ・null ID → StateError・Sign-In キャンセル → StateError・リモートファイル名検証）
- `test/wr_time_sync_test.dart`: `epochToBytes` 6 ケース（0, 1, 256, 0x01020304, 2^32, 現在値の長さ）+ UUID 定数 4 ケース（`timeSyncService` / `timeSyncChar` 文字列一致 + 両者一致 + bsim 試験 epoch LE64 整合）

**コミット**: `0c0a0cc`（Drive uploader）/ 本セッション（time-sync GATT write）

---

### 22.19 Phase 6: Battery ADC Zephyr glue（`wr_led_status.c` SAADC 配線）

`wr_led_status.c` に `#if IS_ENABLED(CONFIG_ADC)` ガードつきで SAADC 読み取りグルーを追加した。`k_timer` 満了関数は ISR コンテキストのため `adc_read()` は呼べない → `K_WORK_DEFINE` ＋ workqueue で非同期化。

**成果物 (`app/src/wr_led_status.c`)**
- `batt_ch_cfg`: `ADC_GAIN_1_4` / `ADC_REF_INTERNAL` / AIN7 / `#ifdef CONFIG_ADC_NRFX_SAADC .input_positive = SAADC_CH_PSELP_PSELP_AnalogInput7`
- `batt_adc_worker`: `adc_read()` → `wr_battery_raw_to_mv()` → `wr_battery_mv_to_pct()` → `wr_led_batt_pct` 更新
- `K_WORK_DEFINE(batt_adc_work, batt_adc_worker)`: システム workqueue で実行
- `wr_led_tick()` に 100 tick（10 秒）ごとの `k_work_submit(&batt_adc_work)` を追加
- `wr_led_status_init()` に `DEVICE_DT_GET(DT_NODELABEL(adc))` + `device_is_ready()` + `adc_channel_setup()` を追加

**注意**: OMI ファームウェアは `ADC_GAIN_1_6` を使用。`wr_battery.h` は `ADC_GAIN_1_4` を前提（raw × 4800 / 4096）。Phase 5 実機で抵抗分圧比を確認してゲインを確定すること（コードにコメント記載）。

`CONFIG_ADC=y` は OMI の `prj_xiao_ble_sense_devkitv1.conf` に既存。追加 Kconfig 不要。DT overlay（`adc` ノード設定）は OMI ボードファイルに存在するため追加不要。

---

### 22.20 Phase 6: Mobile Drive ファイル一覧 / 削除画面

`WrDriveUploader` に `listFiles()` / `deleteFile()` を追加し、アップロード済みファイルを一覧表示・削除できる `DriveFilesPage` を実装した。

**成果物**
- `app_mobile/lib/services/wr_drive_uploader.dart`（更新）:
  - `listFiles()`: フォルダ ID を lookup（cache hit ならスキップ）→ `files.list(q="'id' in parents...", orderBy='modifiedTime desc')` → `List<drive.File>` 返却。フォルダ未存在時は空リスト。
  - `deleteFile(String fileId)`: `api.files.delete(fileId)` 委譲。
- `app_mobile/lib/pages/drive_files_page.dart`（新規）:
  - `DriveFilesPage`（StatefulWidget）— `initState` でファイル一覧取得、ListView に `ListTile`（audiotrack icon / filename / modifiedTime / delete icon）。
  - 状態: loading（CircularProgressIndicator）/ empty（"No recordings uploaded yet."）/ error（"Error: ..."）/ list（RefreshIndicator + ListView）。
  - 削除: `deleteFile(file.id!)` 呼び出し後に `setState(() => _files.remove(file))`。失敗時は SnackBar。
  - AppBar に refresh IconButton。
  - `WrDriveUploader` を constructor injection 可能（テスト用）。
- `app_mobile/lib/pages/device_page.dart`（更新）: AppBar に `cloud_queue` IconButton を追加 → `Navigator.push` で `DriveFilesPage` へ遷移（`_uploader` を渡す）。

**テスト**
- `test/wr_drive_uploader_test.dart`: +3 シナリオ（フォルダ未存在→空リスト / フォルダ+ファイル存在→リスト返却・list()2回呼び出し / deleteFile→files.delete()呼び出し確認）
- `test/drive_files_page_test.dart`（新規）: 5 widget テスト（loading indicator / 空ステート / ファイルタイル表示 / delete タップ→deleteFile呼び出し+タイル消去 / エラーステート）

**コミット**: `249bacc`

---

### 22.21 Phase 6: Storage GATT — BLE 経由 SD ファイル転送

SD カード上の録音ファイルをスマホから BLE で直接取得できる Storage GATT サービスを実装した。スマホが近づいたときに SD の未転送ファイルを自動回収→Drive アップロードする「帰宅同期」フローの基盤。

**プロトコル概要**

| 方向 | UUID | 内容 |
|---|---|---|
| Client→Device | storageReadControl `30295782-...` | WRITE_WITHOUT_RESP: コマンドバイト + ペイロード |
| Device→Client | storageStream `30295781-...` | NOTIFY: タイプバイト + データ |

コマンド: `0x00` LIST / `0x01`+filename FETCH / `0xFF` ABORT

通知タイプ: `0x01` FILE_ENTRY / `0x02` DATA / `0x03` END / `0xFF` ERROR

**ファームウェア成果物 (`app/src/wr_storage_service.c`)**
- `BT_GATT_SERVICE_DEFINE` で GATT サービス登録（3ハンク: Service/storageStream NOTIFY+CCC/storageControl WRITE）
- LIST: `fs_opendir("/SD:/audio")` → `.opus` のみフィルタ（`a01.txt` 除外） → ファイル名 FILE_ENTRY notify → END
- FETCH: `fs_open` → `fs_read` を `WR_STORAGE_CHUNK_SIZE=494` バイト単位でループ → DATA notify → END
- バックプレッシャー: `bt_gatt_notify()` が `-ENOMEM` を返した場合は 20ms スリープ × 10回リトライ
- 転送は `k_work` (system work queue) で実行 — BLE RX スレッドをブロックしない
- CCC changed callback でアンサブスクライブ時に状態リセット

`app/patches/0002-cmake-add-app-sources.patch` に `wr_storage_service.c` のエントリを追加。

**モバイル成果物**
- `app_mobile/lib/services/wr_storage_client.dart`: `WrStorageSession`
  - `fromServices(List<BluetoothService>)` factory — storageService 不在時は null 返却（旧 omi ファームウェア互換）
  - `listFiles()`: LIST コマンド送信 → FILE_ENTRY 収集 → END で完了
  - `fetchFile(filename, {onProgress})`: FETCH コマンド → DATA チャンクを `Uint8List` に連結 → END で返却
  - `onValueReceived` ストリーム使用（BehaviorSubject の古いキャッシュ値を受け取らないため `lastValueStream` ではなく使用）
  - `forTest` コンストラクタでモック注入可能
- `app_mobile/lib/pages/storage_page.dart`: `StoragePage`
  - 起動時に `openStorageSession()` → `listFiles()` 実行
  - ListView: ファイル名 + cloud_upload ボタン（タップで fetch→Drive アップロード）
  - 転送中は `CircularProgressIndicator` + KB 表示
  - 状態: loading / empty / error / list（RefreshIndicator 付き）
- `app_mobile/lib/pages/device_page.dart`（更新）: AppBar に `sd_storage_outlined` IconButton → `StoragePage` へ遷移
- `app_mobile/lib/services/wr_ble_device.dart`（更新）:
  - `_discoveredServices` フィールドで `connect()` 時のサービス一覧を保持
  - `openStorageSession()`: `WrStorageSession.fromServices(_discoveredServices)` を返す

**テスト**
- `test/wr_storage_client_test.dart`: 9 unit test
  - listFiles: FILE_ENTRY+END → filenames / LIST コマンド 0x00 検証 / 空リスト / ERROR → StateError
  - fetchFile: DATA+END → bytes 連結 / FETCH コマンド 0x01+filename 検証 / onProgress コールバック / ERROR → StateError
  - abort: ABORT コマンド 0xFF 検証

**EOF**
