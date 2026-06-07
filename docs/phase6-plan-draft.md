# Phase 6 着手プラン (ドラフト)

> Phase 5（実機書き込み + 電力測定）が一段落した後、Phase 6 で着手する内容をまとめたリード用メモ。

---

## 1. ゴール

1. 自前ミニマルスマホアプリで BLE 経由のデータ取得とリアルタイム再生／メタデータ書き戻しを実現する
2. Phase 4-2 でMVPに留まったチャンクローテーションを「仕様書 §7.2 完全形」に格上げする
3. Phase 4-4 でフラグだけ実装した USB MSC の **runtime mode switch** を実装する
4. Phase 4-5 でフックポイントだけ用意した **バッテリー ADC** をはじめとする実機ハードウェア依存ロジックを完成させる
5. Phase 4-1 Plan B の **実機検証**（pusher() ジッター・SD遅延の許容確認）

---

## 2. 自前ミニマルスマホアプリの設計骨子

### 2.1 技術選定（候補）

| 候補 | メリット | デメリット |
|---|---|---|
| Flutter | omi 公式アプリと同言語、BLE プラグイン（flutter_blue_plus）が成熟 | Dart 経験が要る |
| React Native | TypeScript で書ける、Web 系資産流用 | BLE 周りのライブラリが断片化（react-native-ble-plx）|

→ 第一候補は **Flutter**。omi 公式アプリ（`third_party/omi/app/`）を参考にできる利点が大きい。

### 2.2 機能スコープ（MVP）

- BLE スキャン → wearable-recorder デバイスに自動接続（フィルター: GATT service `19b10000-...`）
- audioCodec characteristic（`19b10002`）の notify 購読
- 受信した Opus パケットの **生データを SQLite or filesystem にダンプ**（再エンコードはせず、PC 側 Whisper パイプラインへ流す）
- `performSyncTime()` 互換の時刻同期送信
- 接続中 LED 状態の可視化（緑 HB ⇔ アプリ側「接続中」表示）
- Storage GATT 経由での未送信ファイルの一括取得（`storageDataStreamService` `30295780`）

### 2.3 機能スコープ（Phase 6 後半）

- Google Drive 自動アップロード（OAuth2 + Drive API）
- バックグラウンド常時接続（Foreground Service / iOS BLE bg mode）
- Whisper 連携（スマホ単体での文字起こしはオプション、PC 側 large-v3 が主）

---

## 3. omi の BLE プロトコル UUID 一覧（仕様書 §5.1 抜粋）

| サービス / 特性 | UUID | 種別 |
|---|---|---|
| audioCodec | `19b10002` | notify（Opus パケット）|
| features | `19b10020` | read（OmiFeatures ビットマスク）|
| storageDataStreamService | `30295780` | service |
| storageDataStream | `30295781` | notify（チャンクデータ）|
| storageReadControl | `30295782` | write（読み取り対象指定）|
| MTU | 498 bytes | `CONFIG_BT_L2CAP_TX_MTU=498` |
| PHY | 2M PHY 有効 | `CONFIG_BT_AUTO_PHY_UPDATE=y` |
| TX Power | +8 dBm | `CONFIG_BT_CTLR_TX_PWR_ANTENNA=8` |
| Connection Interval | 7.5–15ms | omi DK1+SPISD 標準 |

> アプリ側はまず audioCodec の notify を取れることを最優先目標にする。Storage GATT は後段。

---

## 4. ファームウェア側 Phase 6 残作業

### 4.1 チャンクローテーション本格化（仕様書 §7.2 完全形）

現在の `app/src/wr_chunk.c` は **10分タイマー + 連番命名** のみ。

| 項目 | 現状 | Phase 6 でやること |
|---|---|---|
| ファイル名 | `chunk_NNNNN.opus`（連番） | 時刻同期済: `<UNIX_epoch>.opus` / 未同期: `unsynced_<bootid>_<seq>.opus` |
| ローテーション条件 | 10分経過のみ | 10分 OR ファイルサイズ閾値（例 2MB）の早い方 |
| boot ID | なし | RAM 保持の起動カウンタ（不揮発化は不要、起動毎にインクリメント）|
| 時刻補正 | なし | `performSyncTime()` 後の最初のチャンクから epoch 命名に切替、過去の `unsynced_*` は PC 側ツールで mtime 補正 |

### 4.2 USB MSC runtime mode-switch

現在の `app/src/wr_msc_mode.c` はフラグ検出のみ:

```c
if (wr_msc_mode_is_active()) {
    // ここが空。Phase 6 で:
    // - usb_enable() で MSC LUN を SD に向ける
    // - 録音タスクを short-circuit（PDM, codec, transport を起動しない）
    // - LED は青 1秒周期点滅（MSC 状態表示の追加か検討）
}
```

参考: Zephyr `samples/subsys/usb/mass`（composite ではなく単一 MSC で実装）

### 4.3 バッテリー ADC フック

`app/src/wr_led_status.c` 内の `update_battery_warning()` でバッテリー残量パーセントを取得するが、現在ダミー値。

- XIAO Sense は P0.31（VBATT 1/2 divider 経由）から内部 ADC に接続済
- nRF52840 SAADC を `gain=1/4`, `reference=internal 0.6V`, `acquisition=10us` で読む
- 移動平均（10サンプル）で電圧 → `vbat_to_percent()` で割合化（LiPo 3.0V=0%, 4.2V=100%）

### 4.4 Plan B 実機検証

- pusher() ファンアウト後の **SD 書き込み遅延がジッターを引き起こさないか** PPK2 + ロジアナで確認
- 32GB Ultra SDカードでの fsync レイテンシ実測（仕様書 §6 想定値との照合）
- ワーストケース: 同時 BLE busy + SD ガベージコレクション時のキューオーバーフロー有無

---

## 5. Phase 6 着手前チェックリスト

- [ ] Phase 5 の電力実測値を §14.2 にフィードバック済か
- [ ] PPK2 / Joulescope のキャプチャを `tests/firmware/data/power-baseline/` 等に保存済か
- [ ] 250mAh バッテリーで 20h 目標達成済か（未達なら Opus ビットレート / sleep 戦略を再考）
- [ ] omi 公式アプリ `third_party/omi/app/` の Flutter プロジェクト構造を確認済か
- [ ] 実機（XIAO Sense + SD ブレイクアウト）の Plan B 動作（同時 SD + BLE 受信）を Wireshark で確認済か

---

## 6. 参考資料

- 仕様書 §5（BLE 通信仕様）, §7（チャンク分割）, §11.2（LED 状態マシン）
- omi 公式 DeepWiki: https://deepwiki.com/BasedHardware/omi
- Zephyr USB MSC sample: `samples/subsys/usb/mass`
- Flutter blue plus: https://pub.dev/packages/flutter_blue_plus

---

**EOF**
