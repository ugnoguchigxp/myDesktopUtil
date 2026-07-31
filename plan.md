> 実装方針更新（2026-07-31）: ユーザー要望により、アラームは全画面表示せず、画面中央上部の常に最前面のアラームカードとして実装する。
>
> 技術選定更新（2026-07-31）: 以下のRust案を比較検討した結果、この規模ではFFI層と独自非同期runtimeを持たないSwift 6 + AppKit + Foundationの単一プロセス構成が、メモリ・保守性・macOS統合の総合面で適すると判断して採用した。現在の実装仕様と手順は`README.md`を正とする。

以下を新規プロジェクトの空ディレクトリでCodexへ渡せば、設計だけで止まらず、動作する縦切りMVPから実装を始められる内容です。

macOS専用の軽量常駐デスクトップアプリをRustで新規開発してください。設計提案だけで終了せず、プロジェクト作成、実装、テスト、ローカル実行確認まで進めてください。

# 目的

次の2機能を、単一の軽量なmacOS常駐アプリとして実装します。

1. Outlook予定とSlack重要通知に対する、見逃しにくい前面アラームカード
2. 保存済み定型文を、グローバルショートカットまたはメニューバーのUI操作で、現在カーソルがある入力先へ貼り付ける機能

WindowsとLinuxは現時点では考慮しません。macOS 13以降、Apple Siliconを第一対象としてください。

# 最重要方針

* Rustで実装する
* 常駐時のメモリとCPU使用量を最小化する
* Electron、Tauri、WebView、React、Node.jsを使用しない
* 通常時に大きなGUIウィンドウを常駐させない
* Dockには表示せず、メニューバー常駐アプリとして動作させる
* AppKit、Core Graphics、Accessibility、ServiceManagementなどのmacOSネイティブAPIをRustから利用する
* ネットワーク接続に必要な非同期処理はTokioのcurrent-thread runtimeを基本とする
* 無制限キュー、無制限ログ、Slack履歴全保持など、常駐メモリが増え続ける設計を禁止する
* 外部認証情報がなくても、モックとテストモードで主要機能を確認できるようにする
* 初期版ではSQLiteを使わず、TOMLまたはJSONの小さな状態ファイルを使用する
* まず動作する最小の縦切り実装を完成させ、その後OutlookとSlackの実接続を追加する

# アプリ構成

Cargo workspaceとして構成してください。

```text
desk-agent/
├── Cargo.toml
├── crates/
│   ├── desk-core/
│   │   ├── alert domain
│   │   ├── scheduling
│   │   ├── snippet domain
│   │   ├── filtering
│   │   └── provider traits
│   ├── desk-agent/
│   │   ├── menu bar
│   │   ├── global hotkeys
│   │   ├── clipboard paste
│   │   ├── Outlook connector
│   │   ├── Slack connector
│   │   └── alarm-ui process management
│   └── alarm-ui/
│       ├── floating AppKit alarm card
│       ├── 3-frame animation
│       ├── alarm sound
│       └── click-to-dismiss
├── assets/
├── config/
├── packaging/
├── scripts/
└── README.md
```

アプリ名とBundle Identifierは後で変更しやすいように一か所へ集約してください。初期値は`Desk Agent`と`com.local.deskagent`で構いません。

# プロセスモデル

常駐プロセスは`desk-agent`の1つです。

`desk-agent`は次を担当します。

* macOSメニューバー
* グローバルショートカット
* 定型文管理
* Clipboardへの書き込みと⌘V送信
* Outlook予定同期
* Slackイベント受信
* アラームの時刻管理
* 通知の重複排除
* 必要時の`alarm-ui`起動

アラーム表示時だけ、別プロセス`alarm-ui`を起動してください。

`alarm-ui`との通信は、初期版では標準入出力によるJSONで構いません。

入力例：

```json
{
  "id": "outlook-event-123",
  "type": "calendar",
  "title": "Weekly Meeting",
  "body": "10:00から開始します",
  "startsAt": "2026-07-31T10:00:00+09:00"
}
```

クリックによる停止時の出力例：

```json
{
  "id": "outlook-event-123",
  "action": "acknowledge"
}
```

Named Pipe、localhostサーバー、HTTP IPCなどは現段階では作らないでください。

# 機能1：前面アラームカード

## Outlook予定

Outlook標準の15分前リマインダー値は使用せず、予定の開始時刻から独自に2分前を計算してください。

```rust
alarm_at = event.start_at - Duration::minutes(2);
```

次の予定だけをアラーム対象にしてください。

* キャンセルされていない
* Declinedではない
* 終日予定ではない
* 開始時刻が存在する
* 同一イベントについて未通知

予定が更新された場合は、古いスケジュールを削除して再登録してください。キャンセルされた場合も削除してください。

PCがスリープから復帰した際、開始2分30秒前から開始時刻までの範囲に入っていれば即時アラームを出してください。開始後は出さないでください。

## Slack通知

初期版でアラーム対象とするのは次だけです。

* 自分宛てのDM
* グループDM
* 自分への明示的なメンション

通常のチャンネル投稿は通知対象外です。

Slack受信時は2分待たず、受信直後にアラームを表示してください。

Slackにはユーザー向け通知一覧APIがないため、Events APIで受信したイベントをアプリ側で判定する構成にしてください。自分のSlack User IDを取得し、本文中の`<@USER_ID>`をメンションとして判定してください。

Slack Appの設定を再現可能にするため、リポジトリへSlack App Manifestのサンプルを追加してください。Socket Modeを利用し、公開Webhookサーバーは作らないでください。

外部Slack認証情報がない状態でも、JSON fixtureを入力してDM・メンション判定をテストできるようにしてください。

## アラームUI

`alarm-ui`は次の仕様にしてください。

* 現在利用中のディスプレイ中央上部へ、画面を覆わないカードとして表示
* 常に最前面
* 可能な範囲でmacOSのすべてのSpacesと他アプリ上に表示
* 背景は暗い赤または黒
* 中央に大きなベル画像
* 予定名またはSlack送信者名を表示
* 開始時刻またはメッセージ冒頭を表示
* 「クリックして停止」を表示
* ウィンドウ内のどこをクリックしても停止
* クリック時にアニメーションと音を即時停止
* acknowledge JSONをstdoutへ出力
* その後プロセスを終了
* 閉じるボタン、設定ボタン、複雑な操作は作らない

ベルアニメーションは3コマで十分です。

1. 左に傾いたベル
2. 中央のベル
3. 右に傾いたベル

約150ミリ秒間隔で繰り返してください。絵文字はOSやフォントで見た目が変わるため使用しないでください。単純なベクター描画または小さな画像アセットを使用してください。

アラーム音は短い音を繰り返してください。音声再生は`alarm-ui`側で担当し、`alarm-ui`が終了すれば必ず停止する構造にしてください。第三者のライセンス不明な音源は使用せず、単純な音を生成するか、ライセンス上問題のない小さな音源を同梱してください。

最初に次の開発用コマンドを実装してください。

```bash
cargo run -p desk-agent -- alarm-test
```

これにより、OutlookやSlackへ接続していない状態でもアラームUIを確認できるようにしてください。

# 機能2：定型文ペースト

## 定型文保存

初期版ではTOMLファイルへ保存してください。

保存先は次を基本とします。

```text
~/Library/Application Support/DeskAgent/snippets.toml
```

サンプル：

```toml
[[snippets]]
id = "codex-review"
label = "Codex: コードレビュー"
hotkey = "Cmd+Option+1"
text = """
以下の変更内容をレビューしてください。

特に次の観点を確認してください。
- 型安全性
- エラーハンドリング
- パフォーマンス
- テスト不足
"""

[[snippets]]
id = "codex-investigate"
label = "Codex: 原因調査"
hotkey = "Cmd+Option+2"
text = """
この問題の原因を調査してください。
まだ修正は行わず、再現条件、根本原因、影響範囲を報告してください。
"""
```

初回起動時にファイルがなければ、コメント付きサンプルを作成してください。

次を検証してください。

* ID重複
* ショートカット重複
* 空文字
* 不正なショートカット
* 極端に大きな定型文

初期版ではプレースホルダー、変数展開、LLM呼び出し、履歴管理、クラウド同期は実装しないでください。

## グローバルショートカット

定型文ごとに任意のグローバルショートカットを登録してください。

`global-hotkey` crateの単体利用を第一候補とします。Tauri本体は導入しないでください。

ショートカットが他のアプリやmacOSに占有されていて登録できない場合、アプリ全体を終了させず、メニューバーに警告を表示してください。

次のショートカットも追加してください。

```text
Cmd+Option+P
```

これは定型文一覧を開くために使用します。

## メニューバーUI

AppKitの`NSStatusItem`と`NSMenu`を使って、Dockに表示されないメニューバーアプリにしてください。

メニュー例：

```text
Desk Agent
├── Codex: コードレビュー       Cmd+Option+1
├── Codex: 原因調査             Cmd+Option+2
├── 区切り
├── 定型文ファイルを開く
├── 定型文を再読み込み
├── アラームテスト
├── 接続状態
└── 終了
```

メニュー項目をクリックしても、元の入力先に定型文が貼り付けられるようにしてください。

メニューを開く直前または項目選択前に、元のFrontmost Applicationを記録してください。必要なら元アプリを再アクティブ化し、50～100ミリ秒待ってから⌘Vを送信してください。

初期版では複雑な設定ウィンドウは作らず、「定型文ファイルを開く」でTOMLを標準エディタへ開ければ十分です。

## Clipboard経由の貼り付け

定型文の挿入は、1文字ずつキーイベントを送る方式ではなく、Clipboardと⌘Vを利用してください。

基本フロー：

1. 現在の`NSPasteboard`内容とchangeCountを取得
2. 保存されている定型文をClipboardへ設定
3. Core Graphicsの`CGEvent`でCommand+Vのkeydown/keyupを送信
4. 300～500ミリ秒待機
5. ClipboardのchangeCountを確認
6. ユーザーによる新しいコピーが発生していなければ元のClipboardを復元
7. changeCountが想定外に変わっていれば復元しない

初期版では、元のClipboardがプレーンテキストの場合は確実に復元してください。元のClipboardが画像やファイルなどの場合は、内容を壊す危険がある実装を避けてください。完全なPasteboard Item復元が安全に実装できない場合は、その制約をREADMEへ明記し、無理に復元しないでください。

貼り付け処理は1つの関数へ集約してください。

```rust
paste_snippet(snippet_id: &str) -> Result<PasteOutcome>
```

ショートカットとメニュー項目は、必ず同じ処理を呼び出してください。

## macOSアクセシビリティ権限

別アプリへ⌘Vを送信するため、macOSのAccessibility権限が必要です。

初回起動時に`AXIsProcessTrustedWithOptions`で確認してください。未許可の場合は、ユーザーに理由を説明し、macOSの設定画面へ誘導してください。

権限がない状態でもアプリをクラッシュさせず、次の状態をメニューバーへ表示してください。

```text
Accessibility: Permission Required
```

ログには定型文本文、Slack本文、OAuth token、refresh tokenを出力しないでください。

# Outlook連携

Microsoft Graphの`calendarView/delta`を利用してください。

* 公開Webhookサーバーは作らない
* 初回は対象期間を同期
* 以後は`@odata.deltaLink`で差分同期
* 対象範囲は過去1時間から今後14日
* 同期間隔は通常2～5分
* ローカルでは次回アラーム時刻を保持して待機
* スリープ復帰時には即時再同期
* 認証切れ時にはrefresh tokenを使用
* 認証情報はmacOS Keychainへ保存
* 設定ファイルへtokenを平文保存しない

権限は予定読み取りに必要な最小限としてください。

Microsoft EntraのClient IDが未設定の場合も、アプリの定型文機能とアラームテストは動作させてください。

Graphクライアントはtraitで抽象化し、fixtureまたはfake clientによるテストを可能にしてください。

参考：

* Microsoft Graph calendarView delta:
  [https://learn.microsoft.com/en-us/graph/api/event-delta](https://learn.microsoft.com/en-us/graph/api/event-delta)

# Slack連携

SlackはSocket Modeを使用してください。

* WebSocketは1本
* 切断時は指数バックオフ＋jitter
* イベントのacknowledgeを忘れない
* 同一event_idの重複処理を防止
* recent event IDは上限付きで保持
* メッセージ履歴を無制限保存しない
* app tokenとuser/bot tokenはmacOS Keychainへ保存
* 設定ファイルやログへtokenを出さない
* 認証情報がない場合はSlack機能だけをdisabledにする

Slackの権限やEvent SubscriptionはREADMEとmanifest sampleへ明記してください。

参考：

* Slack Socket Mode:
  [https://docs.slack.dev/apis/events-api/using-socket-mode/](https://docs.slack.dev/apis/events-api/using-socket-mode/)
* Slack Events API:
  [https://docs.slack.dev/apis/events-api/](https://docs.slack.dev/apis/events-api/)

# 状態保存

初期版では小さなJSONファイルを使用してください。

```text
~/Library/Application Support/DeskAgent/state.json
```

保存対象：

* Graph deltaLink
* 今後14日分の必要最小限の予定
* recent Slack event IDs
* 通知済みID
* スヌーズまたはacknowledge状態
* 最終正常同期時刻

一時ファイルへ書き込み、atomic renameしてください。壊れた状態ファイルを検出した場合はバックアップへ退避し、アプリ全体を起動不能にしないでください。

# macOS常駐とパッケージング

`LSUIElement=true`としてDockに表示しない`.app` bundleを作成してください。

macOS 13以降では`SMAppService`によるLogin Item登録を使用してください。開発中は手動起動も可能にしてください。

`.app` bundle内に`alarm-ui` helperを同梱してください。

例：

```text
Desk Agent.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── desk-agent
    ├── Helpers/
    │   └── alarm-ui
    └── Resources/
        ├── alarm sound
        └── bell assets
```

初期段階では署名なしローカルビルドでも構いませんが、Accessibility権限がバイナリパスや署名変更で失われる可能性をREADMEに記載してください。

# テスト

最低限、次のユニットテストを実装してください。

* Outlook予定開始2分前の計算
* 更新された予定の再スケジュール
* キャンセル、Declined、終日予定の除外
* スリープ復帰時の猶予判定
* 同一Outlookイベントの二重通知防止
* Slack DM判定
* SlackグループDM判定
* Slack自分宛てメンション判定
* Slack通常チャンネル投稿の除外
* Slack event_idの重複排除
* snippets.tomlの正常読み込み
* ID重複検出
* ショートカット重複検出
* Clipboard復元判断の状態遷移
* アラームUIへ渡すJSONのserialize/deserialize

外部ネットワークを必要としないテストにしてください。

# 品質確認

実装後に次を実行してください。

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cargo build --workspace --release
```

可能であればmacOS用GitHub Actionsも追加してください。

# メモリとパフォーマンス

目標：

* 通常待機時：20～40MB程度
* CPU idle：ほぼ0%
* `alarm-ui`は通知時だけ追加起動
* アラーム終了後は`alarm-ui`のメモリを全解放
* 定型文数が数百件でもメモリが大きく増えない

厳密な達成を保証する必要はありませんが、READMEへ計測方法を記載してください。

常駐プロセスでは以下を避けてください。

* Tokio multi-thread runtime
* WebView
* 常時表示ウィンドウ
* SQLiteの不要な導入
* unbounded channel
* 無制限キャッシュ
* 無制限ログ
* Slackメッセージ本文の永続保存
* 定型文本文のログ出力

# 実装順序

次の順序で進めてください。

1. Cargo workspaceとドメインモデル
2. `alarm-test`から起動できる前面alarm-ui
3. snippets.tomlの読み込みと検証
4. Clipboard＋CGEventによる定型文貼り付け
5. グローバルショートカット
6. NSStatusItem＋NSMenu
7. Accessibility権限確認
8. mock Outlook／mock Slackからアラームまでの縦切り動作
9. Microsoft Graph連携
10. Slack Socket Mode連携
11. Login Itemと.app bundle作成
12. テスト、README、メモリ計測

外部認証情報がないことを理由に作業を停止しないでください。実接続部分以外を完成させ、fixtureとmockで動作を確認してください。

# 完了条件

最低限、次がローカルで確認できる状態にしてください。

1. メニューバーにDesk Agentが表示される
2. TOMLの定型文がメニューに並ぶ
3. Codexやテキストエディタへフォーカスした状態でショートカットを押すと定型文が貼り付けられる
4. メニューバーの定型文項目をクリックしても元アプリへ貼り付けられる
5. 元のテキストClipboardが安全に復元される
6. `alarm-test`で前面アラームカードが表示される
7. ベルが3コマでアニメーションする
8. アラーム音が繰り返される
9. 画面内をクリックすると音とアニメーションが止まり、alarm-uiが終了する
10. mockのOutlook予定が開始2分前にアラームを発火する
11. mockのSlack DMまたはメンションが即時アラームを発火する
12. fmt、clippy、test、release buildが成功する

作業の最後に、実装した内容、未実装部分、必要な外部設定、確認コマンド、既知の制約を簡潔にまとめてください。
