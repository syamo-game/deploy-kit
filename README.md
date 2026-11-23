# VPS 標準デプロイ

VPS で Docker Compose を使って動かすサービスを、同じ手順で本番に出すための共通部品です。
漏れても困る情報を持たないサービスが対象です。機密情報を持つサービスには使いません。

main に push すると、テストのあと自動で本番に出ます。PR ではテストだけが動きます。

## 流れ

1. **テスト**：`Dockerfile` の `test` ステージを作り、その既定のコマンドでテストを実行します。必要なら PostgreSQL も立てます。
2. **イメージ作成**：`runtime` ステージを作り、GHCR に置きます。VPS ではビルドしません。
3. **デプロイ**：Actions が SSH で VPS に入り、`remote/deploy.sh` を実行します。
   - 空き容量が足りなければ、何も変えずに止まる
   - イメージを取得し、DB をバックアップする
   - マイグレーションを実行し、新しいイメージで起動して、ヘルスチェックが通るまで待つ
   - 通らなければ、前のイメージに戻して失敗として終わる
   - 成功したら、古いイメージとバックアップを消す

VPS には、テストを通ったものと同じイメージをダイジェスト指定で渡します。

## VPS の容量を守る仕組み

| 対象 | 残す数・上限 | 変える方法 |
| --- | --- | --- |
| サービスのイメージ | 動いているものを含めて3世代 | `KEEP_IMAGES` |
| DB のバックアップ | 新しい3つ | `KEEP_BACKUPS` |
| コンテナのログ | 1サービスあたり 10MB × 3ファイル | `compose.yml` の `logging` |
| デプロイ前の空き容量 | 2GB 未満なら何もせず止める | `MIN_FREE_MB` |

GHCR 側のイメージは自動では消しません。コンテナイメージの保存は現在無料ですが、push のたびに増えていきます。必要になったら整理の仕組みを足します。

## サービス側に置くもの

| ファイル | 内容 |
| --- | --- |
| `Dockerfile` | `test` と `runtime` の2つのステージを持つ |
| `deploy/compose.yml` | VPS での起動構成。[examples/compose.yml](examples/compose.yml) が雛形 |
| `.github/workflows/deploy.yml` | 共通ワークフローの呼び出し。[examples/deploy.yml](examples/deploy.yml) が雛形 |

`compose.yml` の約束事は次のとおりです。

- 自分のサービスのイメージは `${APP_IMAGE}` と書く
- 動き続けるサービスにはヘルスチェックを付ける（デプロイはこれが通るまで待つ）
- PostgreSQL のサービス名は `db` にする（デプロイ前にバックアップされる）
- マイグレーションは `ops` プロファイルの `migrate` サービスにする（任意）
- 本番の設定値は VPS の `/opt/<サービス名>/.env` にだけ置き、`env_file: .env` で読む

## 最初に一度だけ行う準備

### VPS

1. デプロイ専用のユーザーを作り、`docker` グループに入れる
2. `/opt/<サービス名>/` を作り、そのユーザーの持ち物にする
3. `/opt/<サービス名>/.env` に本番の設定値を書く
4. Actions 用の SSH 鍵の公開鍵を、そのユーザーの `authorized_keys` に登録する

`docker` グループは実質的に root と同じ権限です。このユーザーの鍵が漏れれば VPS 全体を操作されます。対象を漏れても困らないサービスに限っているのは、このためです。

### GitHub（サービスごと）

リポジトリの Secrets に次の4つを登録します。

- `VPS_HOST`：VPS のホスト名か IP アドレス
- `VPS_USER`：デプロイ専用のユーザー名
- `VPS_SSH_KEY`：Actions 用の SSH 秘密鍵
- `VPS_SSH_KNOWN_HOSTS`：VPS のホスト鍵（`ssh-keyscan` の結果）

## 入口（Cloudflare Tunnel）

[infra/tunnel/](infra/tunnel/) は、VPS の入口を Cloudflare Tunnel にするための接続役（cloudflared）です。
`install.sh` を VPS で実行すると、トークンを聞いて起動し、接続できたかまで確かめます。
接続役は共通ネットワーク `proxy` に入るので、各サービスもこのネットワークにつなげば、Cloudflare の画面から公開先を設定できます。

## 公開について

この共通部品は公開リポジトリに置いています。別の GitHub アカウントのリポジトリからも呼び出せるようにするためです。
中に鍵や接続先は含みません。公開しているのは手順だけです。
呼び出し側は `@v1` のようにタグで版を固定し、共通部品を直したらタグを進めます。

## 確かめたこと、まだのこと

確かめたこと

- `remote/deploy.sh` の判定処理（入力の検査、保持数の計算、履歴の更新、消すイメージの選び方）のテスト24件
- `infra/tunnel/install.sh` のトークンの読み取り処理のテスト8件

まだのこと

- `remote/deploy.sh` と `infra/tunnel/install.sh` を実際のサーバーで通しで動かすこと
- 共通ワークフローを GitHub 上で動かすこと
- ワークフローの静的検査（actionlint）

```bash
bash tests/test_deploy.sh
```

```bash
bash tests/test_tunnel_install.sh
```
