# obs-recording-with-mpv

OBS Studio の録画終了後に、指定した PowerShell スクリプト経由で **mpv** を自動起動し、録画ファイルを即座に再生する Lua スクリプトです。

以下のプロジェクトとの併用を前提としています。
https://github.com/sola0117/mpv-launcher

## 動作環境

| 要件 | バージョン |
|------|-----------|
| OBS Studio | **29.0.0 以上**（`obs_frontend_get_last_recording` を使用） |
| OS | Windows（PowerShell 経由で mpv を起動） |
| mpv | 任意のバージョン（PATH が通っているか、ps1 内でフルパス指定） |

## セットアップ

### 1. スクリプトの追加

1. OBS Studio を起動し、メニューバーから **ツール → スクリプト** を開く
2. 左下の **+** ボタンをクリックし、`open-recording-with-mpv.lua` を選択

### 2. PowerShell スクリプトの作成

mpv の起動オプションをカスタマイズするための `.ps1` ファイルを作成します。

```powershell
# launch-mpv.ps1
param([string]$VideoPath)
& mpv $VideoPath --geometry=50% --ontop
```

`$VideoPath` には録画ファイルのフルパスが自動的に渡されます。

### 3. スクリプト設定

OBS のスクリプト設定パネルで以下を設定します。

| 項目 | 説明 |
|------|------|
| **PowerShell スクリプト (.ps1)** | 上で作成した `.ps1` ファイルのフルパス |
| **起動遅延（ミリ秒）** | 録画停止から mpv 起動までの待機時間（デフォルト: 2000ms） |
| **スクリプトを有効にする** | オン/オフの切り替え |

> **起動遅延について**  
> OBS の「自動リマックス」（MKV → MP4 変換）やファイル名変更が有効な場合は、その処理が完了するまでの時間を設定してください。後処理がない場合は `0` でも動作します。

## 仕組み

```
録画停止
  ↓
OBS_FRONTEND_EVENT_RECORDING_STOPPED イベント
  ↓
obs_frontend_get_last_recording() でファイルパスを取得
  ↓
[delay_ms] ミリ秒待機
  ↓
powershell.exe で .ps1 を実行（OBS をブロックしない非同期起動）
  ↓
mpv で動画を再生
```

PowerShell の呼び出しは `Start-Process` で非同期に行われるため、mpv の起動中も OBS の操作が妨げられません。