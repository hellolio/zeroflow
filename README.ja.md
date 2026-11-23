# Zeroflow

[English](README.md) · [简体中文](README.zh-CN.md) · **日本語**

macOS ネイティブの軽量ユーティリティ集。スクリーンショット注釈、ウィンドウ切り替え、Dock 拡張、クリップボード履歴、ダイナミックアイランドを、メニューバーの 1 つのアイコンにまとめました。

ポップアップなし・サードパーティ製ライブラリ不使用。パッケージは小さく、起動は速く、常駐メモリもわずかです。

ウィンドウ切り替えツールの AltTab やクリップボード管理ツールの Maccy と比較して、ZeroFlow は数倍の機能を備えながら、メモリ使用量を大幅に抑えています。起動直後はもちろん、長時間使用した後でもその差は変わりません。ぜひ実際にダウンロードして、その違いを比較してみてください。

[![Sponsor][SponsorBadge]][SponsorUrl]
[![Latest release](https://img.shields.io/github/v/release/hellolio/zeroflow)](https://github.com/hellolio/zeroflow/releases/latest)
[![macOS: 14.0+](https://img.shields.io/badge/macOS-14.0%2B-black?logo=apple&logoColor=white)](https://github.com/hellolio/zeroflow)

[SponsorUrl]: https://github.com/sponsors/hellolio
[SponsorBadge]: https://img.shields.io/github/sponsors/hellolio?style=flat&logo=github&logoColor=white

## 機能

| モジュール | 内容 |
|---|---|
| スクリーンショット注釈 | `⌘⇧S` でいつでも撮影。直線・矩形・円・テキスト吹き出し・モザイクに対応し、取り消し／やり直しも可能。ショートカットは変更可 |
| ウィンドウ切り替え | `⌘⇥`（変更可）でサムネイル付きのウィンドウ切り替え。最小化中・画面外のウィンドウも表示 |
| Dock 拡張 | アイコンをクリックでウィンドウを最小化、ホバーで内容をプレビュー |
| クリップボード履歴 | `⌘⇧C`（変更可）で履歴を呼び出し、検索・矢印キーで選択・Return で貼り付け |
| ダイナミックアイランド | ノッチにホバーまたはクリックで展開。カレンダー、システムリソース（CPU / メモリ / GPU / ディスク / ネットワーク）、再生中を表示 |
| Finder コンテキストメニュー | Finder の右クリックメニューに独自コマンドを追加 |
| スクロール方向 | ホイールのスクロール方向を反転。トラックパッドのジェスチャーには影響なし |

## インストール

[Releases](https://github.com/hellolio/zeroflow/releases) から最新の `Zeroflow-x.x.x.dmg` をダウンロードし、開いて Zeroflow を「アプリケーション」フォルダにドラッグします。

> 開発者署名・公証を行っていないため、初回起動時に Gatekeeper にブロックされる場合があります。次のいずれかで解決できます。
>
> - ターミナルで `xattr -cr /Applications/Zeroflow.app` を実行してから、もう一度開く。
> - 「システム設定 → プライバシーとセキュリティ」で Zeroflow の通知を探し、「このまま開く」をクリックする。

## 技術スタック

| 項目 | 選定 |
|---|---|
| 言語 / UI | Swift 5 + SwiftUI + AppKit |
| 画面キャプチャ | ScreenCaptureKit（`SCScreenshotManager`） |
| グローバルホットキー | Carbon `RegisterEventHotKey`（スクリーンショット / クリップボード） |
| イベント傍受 | CGEventTap（`⌘⇥` 切り替え、スクロール反転、Dock とノッチのホットエリア） |
| ウィンドウサムネイル | SkyLight プライベート API `CGSHWCaptureWindowList`（`dlsym` 経由。最小化中・画面外のウィンドウも取得可能） |
| システム連携 | EventKit（カレンダー）、MediaRemote（再生中）、Accessibility API |
| 依存関係 | サードパーティ製ライブラリなし（単一プロジェクト） |
| 対応 OS | macOS 14.0 Sonoma 以降 |

## ディレクトリ構成

```
zeroflow/
├── Zeroflow.xcodeproj/      # Xcode プロジェクト
├── Zeroflow/
│   ├── ZeroflowApp.swift    # エントリポイント
│   ├── MenuBar/             # メニューバーコントローラ
│   ├── Models/              # 設定・ショートカット・編集ドキュメント・クリップボードのモデル
│   ├── Views/               # 設定画面、選択オーバーレイ、編集画面、各パネル
│   ├── Services/            # キャプチャ、ホットキー、ウィンドウ、Dock、クリップボード、ノッチ、Finder
│   └── Resources/           # ローカライズ文言（Translations.json）
├── FinderSyncExtension/     # Finder コンテキストメニュー拡張（サンドボックス、App Group 経由で本体と通信）
├── scripts/                 # 拡張の登録スクリプト
└── .github/workflows/       # CI：コンパイルチェックとリリース
```

## ロードマップ
- [ ] パフォーマンスの継続的な改善（特にメモリ使用量の削減）と、操作ロジックおよびユーザー体験の最適化。

## ライセンス

[AGPL-3.0-only](LICENSE)

著作権者は、本ソフトウェアを他の条件（商用ライセンスを含む）で配布する権利を留保します。

