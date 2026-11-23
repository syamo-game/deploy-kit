# VPS 標準デプロイ

Docker Compose で動かすサービスを、GitHub Actions から VPS へデプロイするための共通ワークフローです。
main への push でテストからデプロイまで進み、PR ではテストだけを実行します。

## デプロイの流れ

1. **テスト**：`Dockerfile` の `test` ステージを作り、その既定のコマンドでテストを実行します。PostgreSQL が要るテストでは、データベースも用意します。
2. **イメージ作成**：`runtime` ステージを作り、GHCR に置きます。VPS ではビルドしません。
3. **デプロイ**：Actions が SSH で VPS に入り、`remote/deploy.sh` を実行します。
   - 空き容量が足りなければ、何も変えずに止まる
   - イメージを取得し、データベースをバックアップする
   - マイグレーションのあと新しいイメージで起動し、ヘルスチェックが通るまで待つ
   - 通らなければ前のイメージに戻し、失敗として終える
   - 成功したら、古いイメージとバックアップを消す

VPS へは、テストを通ったイメージをダイジェストで指定して渡します。

## VPS に残すもの

| 対象 | 残す量 | 設定 |
| --- | --- | --- |
| サービスのイメージ | 動いているものを含めて3世代 | `KEEP_IMAGES` |
| データベースのバックアップ | 新しい3つ | `KEEP_BACKUPS` |
| コンテナのログ | 1サービスあたり 10MB を3ファイル | `compose.yml` の `logging` |

空き容量が 2GB（`MIN_FREE_MB`）を下回っていると、デプロイを始めません。GHCR のイメージは消しません。

## サービス側に置くファイル

| ファイル | 内容 |
| --- | --- |
| `Dockerfile` | `test` と `runtime` の2つのステージ |
| `deploy/compose.yml` | VPS での起動構成。雛形は [examples/compose.yml](examples/compose.yml) |
| `.github/workflows/deploy.yml` | 共通ワークフローの呼び出し。雛形は [examples/deploy.yml](examples/deploy.yml) |

`compose.yml` は次の決まりに沿って書きます。

- 自分のサービスのイメージは `${APP_IMAGE}` とする
- 動き続けるサービスにはヘルスチェックを付ける。デプロイはこれが通るまで待つ
- PostgreSQL のサービス名は `db` とする。デプロイの前にバックアップされる
- マイグレーションは、`ops` プロファイルの `migrate` サービスで実行する（なくても構わない）
- 本番の設定値は VPS の `/opt/<サービス名>/.env` に置き、`env_file: .env` で読む

呼び出し側では `@v1` のようにタグで版を固定します。

## 最初に行う準備

### VPS

1. デプロイ専用のユーザーを作り、`docker` グループに入れる
2. `/opt/<サービス名>/` を作り、そのユーザーの所有にする
3. `/opt/<サービス名>/.env` に本番の設定値を書く
4. Actions 用の SSH 公開鍵を、そのユーザーの `authorized_keys` に登録する

`docker` グループのユーザーは、root と同じことができます。この鍵が漏れると、VPS 全体を操作されます。

### GitHub

サービスのリポジトリに、次の Secrets を登録します。

- `VPS_HOST`：VPS のホスト名か IP アドレス
- `VPS_USER`：デプロイ専用のユーザー名
- `VPS_SSH_KEY`：Actions 用の SSH 秘密鍵
- `VPS_SSH_KNOWN_HOSTS`：VPS のホスト鍵（`ssh-keyscan` の出力）

## Cloudflare Tunnel の接続役

[infra/tunnel/](infra/tunnel/) は、VPS で Cloudflare Tunnel の接続役（cloudflared）を動かすための構成です。
VPS で `install.sh` を実行すると、トークンの入力を求め、起動して接続を確かめます。トークンは単体でも、Cloudflare の画面に出るコマンド全体でも受け付けます。
接続役は Docker の `proxy` ネットワークに入ります。サービスをこのネットワークにつなぐと、Cloudflare の画面から公開先に指定できます。

## テスト

```bash
bash tests/test_deploy.sh
```

```bash
bash tests/test_tunnel_install.sh
```
