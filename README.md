# Container Compose Build & Push

ローカルベースイメージをビルドし、ECR へタグ付けしてプッシュ、
`imagedefinition.json` を出力するためのスクリプトです。ビルド方法の異なる
2 つのスクリプトを提供します (ビルド以降の処理・オプションは共通)。

| スクリプト | ビルド方法 |
| --- | --- |
| `build_and_push.sh` | `compose.yml` を使った `docker compose build` |
| `buildx_build_and_push.sh` | `docker buildx build` (compose 不使用)。ECR ログイン (`aws ecr get-login-password \| docker login`)、`docker image tag`、`docker image push` を個別コマンドで実行 |

想定実行環境: RHEL 9.6 の EC2 インスタンス (bash / GNU coreutils / Docker CE)。

## 使い方

```bash
# compose 版
./build_and_push.sh --account-id 123456789012 --region ap-northeast-1 \
    --auto-switchback --switchback-shell /opt/team/switchback.sh

# buildx 版
./buildx_build_and_push.sh --account-id 123456789012 --region ap-northeast-1 \
    --auto-switchback --switchback-shell /opt/team/switchback.sh
```

## イメージタグについて

イメージタグは `<TAG_PREFIX>-<YYYYMMDDHHMMSS>` の形式で生成されます。
接頭辞 (`--tag-prefix`) は **ECR リポジトリ名 (`--repository`) とは独立** して指定でき、
既定値は `BaseImage` です。

- 例 (既定): `BaseImage-20260702153000`
- リポジトリ名を変更してもタグ接頭辞は影響を受けません。

```bash
# リポジトリ名は my-repo、タグ接頭辞は BaseImage
./build_and_push.sh --repository my-repo --tag-prefix BaseImage
#  => my-repo:BaseImage-20260702153000
```

## オプション

2 スクリプトで共通のオプション (ビルド関連のみ異なります。後述の「buildx 版のみのオプション」参照)。

| オプション | 説明 | 既定値 / 環境変数 |
| --- | --- | --- |
| `--account-id ID` | ECR レジストリの AWS アカウント ID | env: `AWS_ACCOUNT_ID` |
| `--region REGION` | AWS リージョン | `ap-northeast-1` / env: `AWS_REGION` |
| `--registry URL` | ECR レジストリ名(URL) を明示指定 | env: `ECR_REGISTRY`<br>未指定時は `<account-id>.dkr.ecr.<region>.amazonaws.com` を組み立て |
| `--repository NAME` | ECR リポジトリ名 = プッシュするイメージ名 | `BaseImage` |
| `--tag-prefix PREFIX` | イメージタグの接頭辞。リポジトリ名とは独立に指定でき、タグは `<PREFIX>-<YYYYMMDDHHMMSS>` となる | `BaseImage` |
| `--local-image NAME` | ビルドで生成されるローカルイメージ名 | `j1/base.local` |
| `--container-name NAME` | `imagedefinition.json` の name | `--repository` の値 |
| `--compose-file FILE` | compose ファイル (**compose 版のみ**) | `compose.yml` |
| `--compose-service NAME` | ビルド対象サービス名 (未指定なら全サービス) (**compose 版のみ**) | (全サービス) |
| `--no-cache` | キャッシュを破棄してビルドする | `false` |
| `--output FILE` | imagedefinition の出力先 | `imagedefinition.json` |
| `--dry-run` | 実際のビルド/ログイン/タグ付け/プッシュ/ファイル出力は行わず、実行内容のプレビューのみ表示する | `false` |
| `--copy-file SRC:DEST_DIR` | ビルド前に `SRC` を `DEST_DIR` へコピーし、ビルド終了後に自動削除する。繰り返し指定で複数ファイルに対応 | (なし) |
| `--switchback-shell PATH` | 別チーム提供のスイッチバック用シェルのパス (source で呼び出し) | env: `SWITCHBACK_SHELL` |
| `--auto-switchback` | ECR 権限が無い場合に自動でスイッチバックして継続する | `false` |
| `--warn-only` | ECR 権限が無い場合に警告して終了する (既定) | (既定) |
| `-h`, `--help` | ヘルプを表示 | |

### buildx 版のみのオプション

`buildx_build_and_push.sh` は compose を使わず `docker buildx build` でビルドします。
`docker image tag` / `docker image push` を個別コマンドとして使うため、ビルド結果は
`--load` でローカルの docker イメージストアへ取り込みます (このため単一プラットフォームのみ対応)。

| オプション | 説明 | 既定値 |
| --- | --- | --- |
| `--dockerfile FILE` | Dockerfile のパス | `Dockerfile` |
| `--context DIR` | ビルドコンテキスト | `.` |
| `--platform PLATFORM` | ターゲットプラットフォーム (例: `linux/amd64`)。複数指定は不可 | (現在のプラットフォーム) |
| `--builder NAME` | 使用する buildx ビルダー名 | (現在のビルダー) |
| `--build-arg KEY=VALUE` | ビルド引数 (繰り返し指定可) | (なし) |

buildx 版が実行するコマンドの流れ:

```bash
docker buildx build --load -t j1/base.local -f Dockerfile .
aws ecr get-login-password --region <region> \
  | docker login --username AWS --password-stdin <registry>
docker image tag j1/base.local <registry>/<repository>:<tag>
docker image push <registry>/<repository>:<tag>
```

## ビルド前後の一時ファイルコピー (`--copy-file`)

ビルドコンテキストに一時的に必要なファイル (例: `.npmrc`、証明書、資格情報ファイルなど) を
ビルド直前にコピーし、**ビルド終了後 (成功・失敗・途中終了のいずれでも) に自動削除**します。
`--copy-file` を繰り返し指定することで複数ファイルに対応できます。

```bash
./build_and_push.sh --account-id 123456789012 \
    --copy-file .npmrc:./app \
    --copy-file certs/ca.pem:./app/certs
```

- 書式は `SRC:DEST_DIR`。`SRC` はコピー元ファイル、`DEST_DIR` は**既存の**コピー先ディレクトリ。
- コピー先ファイル名は `SRC` のベース名になります (例: `.npmrc` → `./app/.npmrc`)。
- **安全策**: コピー先に同名ファイルが既に存在する場合は、自動削除で既存ファイルを
  消してしまう事故を防ぐため処理を中止します。
- `--dry-run` 併用時は、実際のコピー/削除は行わず実行内容のみ表示します。

## push 失敗時の原因診断 / 調査ガイド

`docker push` が失敗した場合、スクリプトは自動的に以下を行います。

1. **AWS API の応答を確認**
   - `aws sts get-caller-identity` … どの IAM プリンシパルとして実行しているか
   - `aws ecr describe-repositories` … プッシュ先リポジトリが実在するか
2. **`docker push` の出力を解析**し、該当する原因カテゴリを推定
3. 各原因について、**詳細な説明 + 具体的な AWS CLI 調査コマンド + AWS コンソールの確認箇所**を表示

判定・ガイドする原因カテゴリ:

| カテゴリ | 主な兆候 | ガイド内容 |
| --- | --- | --- |
| **A. IAM 権限エラー** | `denied` / `not authorized to perform` / `ecr:*` | 必要な ECR アクション一覧、`iam simulate-principal-policy`、CloudTrail での AccessDenied 追跡 |
| **B. ECR エンドポイント権限設定エラー** | `denied` (IAM は正常でも発生) | リポジトリポリシー / VPC エンドポイントポリシーの確認 (`get-repository-policy`, `describe-vpc-endpoints`) |
| **C. ECR エンドポイント不存在疑い** | `no such host` / `timeout` / `dial tcp` | ecr.api / ecr.dkr / s3 の VPC エンドポイント有無・PrivateDNS・ルート・SG(443) の確認 |
| **D. ECR リポジトリが存在しない** | `name unknown` / `does not exist` | `describe-repositories` での一覧確認、リージョン取り違え、`create-repository` |
| **E. 認証トークン期限切れ** | `token has expired` / `401 Unauthorized` | `get-login-password | docker login` での再ログイン |

パターンに一致しない場合は、上記すべての観点を切り分け用チェックリストとして表示します。

## スイッチバックについて

このステージでは CodeCommit の操作は不要で、ECR の操作権限のみが必要です。
現在の操作権限で ECR を操作できない場合の挙動を 2 通りから選べます。

- **(A) 既定 (`--warn-only`)**: スイッチバックを促す警告を出して終了 (exit 1)
- **(B) (`--auto-switchback`)**: 別チーム提供のスイッチバック用シェルを `source` で呼び出し、
  自動的にスイッチバックしてから処理を継続する

スイッチバック用シェルの配置場所は `--switchback-shell` で指定します。
