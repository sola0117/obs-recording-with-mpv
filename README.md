# obs-recording-with-mpv

OBS Studio の録画終了後に録画ファイルをリネームし、**mpv を直接起動または既存インスタンスへ読み込む** Lua スクリプトです。外部の `mpv-launcher`、PowerShell スクリプト、新規常駐プロセスは必要ありません。

mpv は最初のフレームで一時停止し、その後の再生操作は `remote_mpv` など既存の JSON IPC クライアントに委ねます。

## 動作環境

| 要件 | 内容 |
|------|------|
| OBS Studio | 29.0.0 以上（`obs_frontend_get_last_recording` を使用） |
| OS | Windows 10 / 11 |
| mpv | JSON IPC と `--fs-screen` を利用できるバージョン |
| Lua | OBS に同梱される LuaJIT（別途インストール不要） |

## ファイル構成

次の3ファイルを同じフォルダに置いてください。

```text
任意のフォルダ/
├── open-recording-with-mpv.lua  # OBSスクリプト本体
├── mpv_control.lua              # mpv起動・Windows名前付きパイプ通信
└── ljsocket.lua                 # ブラウザドック用HTTPサーバー
```

`ljsocket.lua` は [CapsAdmin/luajitsocket](https://github.com/CapsAdmin/luajitsocket)（MIT License）を同梱しています。

## セットアップ

### 1. mpvを用意する

[mpv公式のインストール案内](https://mpv.io/installation/)に従ってmpvをインストールし、`mpv.exe`の場所を確認します。

通常の`mpv.conf`は引き続き読み込まれます。音声デバイスなどは従来どおり`mpv.conf`で設定してください。このスクリプトは既存設定ファイルを変更・上書きしません。

### 2. OBSへスクリプトを追加する

1. OBS Studioで **ツール → スクリプト** を開く
2. 左下の **+** を押す
3. `open-recording-with-mpv.lua`を選択する
4. 下表の項目を設定する

| 項目 | 説明 | デフォルト |
|------|------|------------|
| **ブラウザドック連携ポート番号** | ローカルHTTPサーバーのポート | `4050` |
| **MPV Executable Path** | `mpv.exe`のフルパス | 未設定 |
| **Playback Monitor** | mpvが使う0始まりのモニター番号 | `0` |
| **Auto Playback** | 録画後にmpvへ自動で読み込む | ON |
| **IPC Pipe** | mpv JSON IPCの名前付きパイプ | `\\.\pipe\mpvsocket` |
| **Playback Delay** | 録画停止からリネーム・再生処理までの待機時間 | `2000 ms` |
| **スクリプトを有効にする** | 録画終了処理全体のON/OFF | ON |

`Auto Playback`をOFFにしても、録画ファイルのリネームとテイク番号更新は継続します。

### 3. ブラウザドックを追加する

1. OBSメニューから **ドック → カスタムブラウザドック** を開く
2. 名前を入力する（例: `録画ファイル名`）
3. URLへ次を入力する

```text
http://127.0.0.1:4050/
```

## ブラウザドックの使い方

録画前にドックでファイル名とテイク番号を設定すると、録画終了後に次の形式へリネームします。

```text
{take_name}_t{take_number}.{extension}
例: Scene001_t03.mkv
```

| 操作 | 動作 |
|------|------|
| ファイル名を入力して **セット** | 次の録画に使う名前とテイク番号を設定 |
| **＋ / －** | テイク番号を増減して即時反映 |
| 録画停止 | 処理後にテイク番号を自動インクリメント |
| ファイル名を変更して **セット** | テイク番号を`01`へリセット |
| ファイル名を空欄で **セット** | リネームをスキップ |

同名のリネーム先が存在する場合は上書きせず、元の録画ファイルを維持してOBSログへ警告を出します。

## Playback Monitorの番号

`Playback Monitor`はWindows設定画面に表示される「ディスプレイ1」「ディスプレイ2」ではなく、**mpvが使用する0始まりの番号**です。

Windows版mpvは`--fs-screen`の番号をWindows APIの`EnumDisplayMonitors`列挙順で解釈します。この順序はWindows設定画面の番号と一致する保証がありません。番号が無効な場合、mpvはプライマリモニターへフォールバックし、本スクリプトもOBSログへ警告を出します。

希望するモニターへ表示されない場合は、`0`、`1`、`2`の順に確認してください。ウィンドウ配置にはmpv標準の`--fs-screen`を使用し、独自のウィンドウ移動処理は行いません。

## mpv起動・再利用の動作

```text
録画終了
  ↓
Playback Delay
  ↓
録画ファイルの存在確認・リネーム（上書きなし）
  ↓
テイク番号更新
  ↓
\\.\pipe\mpvsocket への接続を確認
  ├─ 接続可能: 既存mpvへloadfile
  └─ 接続不可: mpv.exeを直接起動
  ↓
file-loadedまたはpath応答を確認
  ↓
先頭へシーク・pause状態と読み込みパスを確認
  ↓
IPC接続を閉じ、以後の操作をremote_mpvへ委譲
```

新規起動時は次のmpv標準オプションを指定します。

```text
--fullscreen
--fs-screen=<Playback Monitor>
--pause=yes
--keep-open=yes
--loop-file=no
--input-ipc-server=\\.\pipe\mpvsocket
```

IPC処理はOBSの短周期タイマーで進行し、名前付きパイプの応答をメインスレッドで長時間待ちません。既存mpvの読み込みでは`file-loaded`イベントを使用し、新規mpvで接続前にイベントが発生した場合は`path`プロパティの応答で読み込み完了を確認します。

## remote_mpvとの互換性

- 既定のパイプ名`\\.\pipe\mpvsocket`を維持しています。
- mpv JSON IPCは複数クライアントを受け付けるため、プレイバック準備中も`remote_mpv`の接続を妨げません。
- このスクリプト自身のIPC接続は初期状態の確認後に閉じます。
- mpvが終了した場合、次の録画終了時に新しいmpvを起動します。`remote_mpv`側の既存再接続動作は変更しません。
- Companionモジュール側の設定・実装変更は不要です。

独自のパイプ名へ変更する場合は、mpvへ接続する他のクライアント側も同じ名前に合わせてください。

## 自動リマックスについて

OBSの`OBS_FRONTEND_EVENT_RECORDING_STOPPED`は録画が完全に停止した時点で発生し、スクリプトは`obs_frontend_get_last_recording()`が返すパスを処理します。ただし、自動リマックス完了を通知する専用Luaイベントは使用していません。

自動リマックスを有効にしている環境では、変換が完了してから処理されるよう`Playback Delay`を十分長く設定してください。スクリプトが扱うのはOBSが「最後の録画」として返すファイルであり、別途生成されたリマックス先ファイルを探索・推測はしません。

## エラー時の挙動

次の問題はOBSログへ警告を出し、録画ファイルを削除しません。

- `mpv.exe`が未設定、存在しない、または起動できない
- 録画ファイルが存在しない
- リネームに失敗した、または同名ファイルが存在する
- IPCへ接続できない、切断された、応答がタイムアウトした
- mpvが要求と異なるファイルを読み込んだ
- 指定モニター番号が現在のモニター数を超えている
- プレイバック準備中にmpvが終了した

ファイル操作とプロセス起動にはWindowsのUnicode APIを使用するため、日本語、空白、括弧を含むパスを扱えます。

## 既知の制約

- Windows専用です。
- mpvを起動してからIPCパイプが利用可能になるまで最大8秒、ファイル読み込み応答を最大15秒待ちます。待機は非同期タイマーで行われます。
- `Playback Monitor`の番号はモニターの接続変更やドライバー構成で変わる可能性があります。
- 自動リマックス先ファイルの自動検出は行いません。

## 開発時のテスト

LuaJITが利用できる環境では、Windows APIをモックしたテストと引数クォートのテストを実行できます。

```sh
luajit tests/test_script.lua
luajit tests/test_mpv_control.lua
```

このテストは、既存mpvの再利用、新規mpvの直接起動、IPCコマンド、Unicode・空白・括弧を含むパス、リネーム、同名衝突、テイク更新、`Auto Playback`無効時の録画後処理を確認します。

## 参考仕様

- [mpv Manual: Window options / JSON IPC](https://mpv.io/manual/master/)
- [mpv Windows monitor implementation](https://github.com/mpv-player/mpv/blob/master/video/out/w32_common.c)
- [Microsoft: Named Pipe Client](https://learn.microsoft.com/windows/win32/ipc/named-pipe-client)
- [OBS Studio Frontend API](https://docs.obsproject.com/reference-frontend-api)
