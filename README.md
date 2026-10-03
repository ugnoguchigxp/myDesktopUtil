# Desk Agent

macOS 13以降向けの軽量なメニューバー常駐アプリです。

- TOMLに保存した定型文をグローバルショートカットまたはメニューバーから現在の入力先へ貼り付け
- 設定ウィンドウで定型文の名前・本文・ショートカット・実行方法を編集

Swift 6、AppKit、FoundationのOS標準APIだけで実装し、WebView、Electron、Tauri、Node.js、SQLite、常駐する独自非同期ランタイムは使用していません。

## ビルド

```bash
swift test
./scripts/install-local-signing-identity.sh
./scripts/build-app.sh
```

生成先:

```text
dist/Desk Agent.app
```

起動:

```bash
open "dist/Desk Agent.app"
```

通常のアプリとして配置:

```bash
ditto "dist/Desk Agent.app" "/Applications/Desk Agent.app"
open "/Applications/Desk Agent.app"
```

Accessibility権限とログイン時起動は、配置後の`/Applications/Desk Agent.app`に対して設定してください。
ローカル署名IDのインストールはこのMacで最初の1回だけ必要です。再ビルド後も同じアプリとして識別されます。Apple DevelopmentまたはDeveloper IDの証明書がある場合は、`DESK_AGENT_SIGNING_IDENTITY`へそのIDを指定できます。
ローカル署名IDの作成時だけ`openssl`コマンドを使用します。アプリの実行時依存関係には含まれません。

## 保存場所

初回起動時に次のファイルを作成します。

```text
~/Library/Application Support/DeskAgent/snippets.toml
```

`DESK_AGENT_DATA_DIR`環境変数を指定すると、開発・テスト時だけ保存先を変更できます。

メニューバーの「ペースト設定…」から、定型文を自由に追加・削除し、名前・ショートカット・本文を編集できます。登録件数の固定上限はありません。「保存」でファイルとショートカットの両方へ即時反映されます。「キャンセル」では変更を保存しません。ショートカットを空欄にすると、メニューからのみ実行できます。`Cmd+Option+P`は一覧を開くための専用キーです。起動済みのDesk Agentをアプリケーションフォルダから開いても設定画面を表示できます。

ショートカットは、キー欄をクリックしてキーボードを押すだけで設定できます。単独のキーを入力して`Cmd`・`Option / Alt`・`Control`・`Shift`のチェックを選ぶ方法と、`⌘⌥K`などの組み合わせを押してまとめて設定する方法に対応します。修飾キーは1つ以上必要です。キー欄で`Delete`を押すとショートカットを解除できます。設定画面にフォーカスがある間は、ペースト用のグローバルショートカットを停止します。他のアプリへ切り替えると再開します。設定画面は通常のウィンドウで、他のアプリより前に居続けず、最小化もできます。

数字・英字・`F1`〜`F20`・記号・矢印・`SPACE`・`RETURN`などに対応しています。TOMLへ直接書く場合の例：`Control+Shift+K`、`Cmd+Option+7`、`Cmd+Shift+/`。

初期設定では`Cmd+Option+1〜6`に、コードレビュー・原因調査・実装・テスト・説明・文章の推敲を割り当てています。更新後の初回読み込みでは、同じIDやショートカットがない定型文だけ追加します。元のファイルは同じフォルダの`snippets.before-six-slots.toml`に一度だけ保存します。削除した定型文は再起動後も復活しません。

実行方法は定型文ごとに選べます。

- **すぐ貼り付ける**：現在の入力先へ本文を貼り付け、元のクリップボードを復元します。
- **コピーだけする**：本文をクリップボードへ保存します。自分で`⌘V`を押して貼り付けられます。Accessibility権限は不要です。

TOMLでは`mode = "copy"`でコピーのみ、`mode = "paste"`または省略で即時貼り付けになります。外部エディタで編集した場合は、メニューの「定型文を再読み込み」を選んでください。設定画面を開いている間に外部で変更された場合は、上書きを防ぐため保存を中止します。

定型文には次の上限があります。

- 表示名は最大128文字かつ512バイト
- 1件64KiB
- 本文合計2MiB
- ID、ショートカットの重複は禁止

## Accessibility権限

別アプリへ⌘Vを送信するため、Desk AgentへAccessibility権限が必要です。

1. `.app` bundleからDesk Agentを起動
2. 定型文の貼り付けを1回実行
3. 表示された案内から「システム設定 > プライバシーとセキュリティ > アクセシビリティ」を開く
4. Desk Agentを許可

既に許可済みなのにメニューが「Accessibility: 未許可」と表示される場合は、設定内の古いDesk Agentと`desk-agent`を`−`で削除し、`/Applications/Desk Agent.app`を`＋`から追加し直してください。署名、バイナリパス、Bundle Identifierを変更すると、macOSが別アプリと判断して再許可が必要になります。未許可時のシステム案内は1回の起動につき1回だけ表示します。

Clipboardは最大128項目・512 representation・合計4MiB以内の場合だけ一時保存します。安全に保存できない大きな画像や特殊な遅延データが入っている場合、Clipboardを破壊せず貼り付けを中止します。貼り付け中にユーザーが新しくコピーした場合も復元しません。同時に複数の定型文を呼び出した場合は、元のClipboardを守るため後続の貼り付けを拒否します。

## ログイン時起動

`.app` bundleから起動後、メニューの「ログイン時に起動」を選択します。macOS 13以降の`SMAppService.mainApp`を使用します。承認待ちの場合はメニューからシステム設定を開けます。

## メモリ計測

Release版を起動し、5分待ってから実行します。

```bash
./scripts/memory-check.sh
```

さらに次を比較します。

1. 起動5分後
2. 定型文貼り付け100回後

`ps`のRSSだけでなく`footprint`のphysical footprint、Xcode InstrumentsのAllocationsとVM Trackerを確認してください。回数に比例してprivate dirty memoryが増え続けないことを合格条件とします。

## 既知の制約

- パスワード入力などの保護された入力欄では、定型文を貼り付けられない場合があります。
- このMacではローカル自己署名を使用します。他のMacへ配布する場合はDeveloper ID署名とnotarizationが必要です。
