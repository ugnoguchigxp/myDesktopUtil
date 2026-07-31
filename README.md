# Desk Agent

macOS 13以降向けの軽量なメニューバー常駐アプリです。

- Outlook予定の開始2分前、およびSlackのDM・グループDM・自分へのメンションを前面アラームカードで表示
- TOMLに保存した定型文をグローバルショートカットまたはメニューバーから現在の入力先へ貼り付け

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

アラームカードだけを確認:

```bash
./scripts/run-app.sh --alarm-test
```

モックを確認:

```bash
./scripts/run-app.sh --mock-outlook
./scripts/run-app.sh --mock-slack
```

JSON fixtureを読み込むこともできます。

```bash
./scripts/run-app.sh --slack-fixture "$PWD/Fixtures/slack-dm.json"
./scripts/run-app.sh --outlook-fixture "$PWD/Fixtures/outlook-events.json"
```

## 保存場所

初回起動時に次のファイルを作成します。

```text
~/Library/Application Support/DeskAgent/snippets.toml
~/Library/Application Support/DeskAgent/connections.json
~/Library/Application Support/DeskAgent/state.json
```

`DESK_AGENT_DATA_DIR`環境変数を指定すると、開発・テスト時だけ保存先を変更できます。

定型文には次の上限があります。

- 最大256件
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

## Outlook

macOSのカレンダーへ同期されたExchange予定をEventKitから読み取ります。Microsoft Entraのアプリ登録、Client ID、Microsoft Graphの権限は不要です。

1. 「システム設定 > インターネットアカウント」でExchangeアカウントを追加
2. そのアカウントの「カレンダー」を有効化
3. Desk Agentを起動し、カレンダーへのフルアクセスを許可

権限を拒否した場合は、Desk Agentメニューの「カレンダー設定を開く」から許可できます。Outlookアプリ自体は起動していなくても同期できます。

同期間隔は`connections.json`で設定できます。

```json
{
  "outlookPollSeconds": 180,
  "slack": {
    "selfUserID": ""
  }
}
```

旧設定の`graphPollSeconds`も互換性のため読み取ります。`microsoft`ブロックは使用されないため削除できます。設定変更後はメニューバーの「接続設定を再読み込み」を選択してください。

通常は3分ごと、スリープ復帰時は即時に予定を再取得します。カレンダー権限が未許可、Exchangeカレンダーが未設定、または取得に失敗した場合は、既に読み込んだ予定とアラームを削除せず次回同期まで保持します。終日予定、キャンセル済み予定、辞退済み予定はアラーム対象外です。

## Slack Socket Mode

[`config/slack-app-manifest.yaml`](config/slack-app-manifest.yaml)からSlack Appを作成します。App-level tokenには`connections:write`が必要です。manifestは認可ユーザー向けの次のeventを購読します。

- `message.im`
- `message.mpim`
- `message.channels`
- `message.groups`

tokenを平文ファイルへ保存せず、ReleaseバイナリからKeychainへ登録します。

```bash
"dist/Desk Agent.app/Contents/MacOS/desk-agent" secret set slack-app-token
"dist/Desk Agent.app/Contents/MacOS/desk-agent" secret set slack-user-token
```

`connections.json`の`slack.selfUserID`へ自分の`U...` IDを設定してください。空の場合は`slack-user-token`を使って`auth.test`から取得します。その後「接続設定を再読み込み」を選択します。

Slackイベントは最大512KiB、重複排除IDは最新512件、アラーム待ちキューは8件に制限しています。メッセージ本文は表示用の先頭256文字だけを一時利用し、永続化・ログ出力しません。

## ログイン時起動

`.app` bundleから起動後、メニューの「ログイン時に起動」を選択します。macOS 13以降の`SMAppService.mainApp`を使用します。承認待ちの場合はメニューからシステム設定を開けます。

## メモリ計測

Release版を起動し、初回同期後に5分待ってから実行します。

```bash
./scripts/memory-check.sh
```

さらに次を比較します。

1. 起動5分後
2. 定型文貼り付け100回後
3. アラーム開閉30回後
4. Slack fixture 1,000件相当の分類テスト後

`ps`のRSSだけでなく`footprint`のphysical footprint、Xcode InstrumentsのAllocationsとVM Trackerを確認してください。回数に比例してprivate dirty memoryが増え続けないことを合格条件とします。

## 既知の制約

- ロック画面、パスワード入力などのsecure system UIより前面に表示することはできません。
- アラームカードはマウスポインタがあるディスプレイの中央上部に表示します。
- 会社の端末管理ポリシーでmacOS標準カレンダーへのExchange同期が禁止されている場合、Outlook予定は取得できません。
- Slackの個人向けevent購読はWorkspace管理者の承認やポリシーにより利用できない場合があります。
- このMacではローカル自己署名を使用します。他のMacへ配布する場合はDeveloper ID署名とnotarizationが必要です。
