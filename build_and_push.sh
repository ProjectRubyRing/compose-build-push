#!/usr/bin/env bash
#
# build_and_push.sh
# -----------------------------------------------------------------------------
# 想定実行環境: RHEL 9.6 の EC2 インスタンス (bash / GNU coreutils / Docker CE)。
#
# compose.yml で定義したローカルベースイメージ (既定: j1/base.local) を
# docker compose build でビルドし、ECR へタグ付けしてプッシュ、結果として
# imagedefinition.json を出力する。
#
# 権限まわりの前提:
#   - このステージでは CodeCommit の操作は不要。ECR の操作権限のみが必要。
#   - 現在の操作権限で ECR を操作できない場合の挙動を 2 通りから選べる:
#       (A) 既定 (--warn-only)  : スイッチバックを促す警告を出して終了 (exit 1)
#       (B)     (--auto-switchback): 別チーム提供のスイッチバック用シェルを
#                                    source で呼び出し、自動的にスイッチバック
#                                    してから処理を継続する。
#   - スイッチバック用シェルの配置場所は --switchback-shell で指定可能。
#
# 使い方:
#   ./build_and_push.sh --account-id 123456789012 --region ap-northeast-1 \
#       --auto-switchback --switchback-shell /opt/team/switchback.sh
# -----------------------------------------------------------------------------

set -uo pipefail

# ---- 既定値 -----------------------------------------------------------------
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"
ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
REGISTRY="${ECR_REGISTRY:-}"      # ECR レジストリ名(URL)。未指定なら <account>.dkr.ecr.<region>.amazonaws.com を組み立てる
REPOSITORY="BaseImage"            # ECR 側リポジトリ名 (= プッシュするイメージ名)
TAG_PREFIX="BaseImage"            # イメージタグの接頭辞。タグは <TAG_PREFIX>-<YYYYMMDDHHMMSS> となる (リポジトリ名とは独立)
LOCAL_IMAGE="j1/base.local"       # compose build で生成されるローカルベースイメージ名
CONTAINER_NAME=""                 # imagedefinition.json の name。未指定なら REPOSITORY を使用
COMPOSE_FILE="compose.yml"
COMPOSE_SERVICE=""                # 指定時はそのサービスのみビルド
NO_CACHE="false"                  # true: キャッシュを破棄してビルド (--no-cache)
OUTPUT_FILE="imagedefinition.json"
ECR_USERNAME="AWS"                # ECR ログイン時の固定ユーザー名
DRY_RUN="false"                   # true: 実際の変更は行わず、実行内容のプレビューのみ表示

# スイッチバック関連
SWITCHBACK_SHELL="${SWITCHBACK_SHELL:-}"
AUTO_SWITCHBACK="false"           # false: 警告して終了 / true: 自動スイッチバック

# ---- ログ用ヘルパ -----------------------------------------------------------
log()  { printf '[%s] %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] [WARN] %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
# dry-run 時は実行内容を表示するだけ、通常時はそのままコマンドを実行する。
run()  {
  if [ "$DRY_RUN" = "true" ]; then
    printf '[%s] [DRY-RUN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
    return 0
  fi
  "$@"
}

usage() {
  cat <<'EOF'
Usage: build_and_push.sh [OPTIONS]

Options:
  --account-id ID          ECR レジストリの AWS アカウント ID (env: AWS_ACCOUNT_ID)
  --region REGION          AWS リージョン (既定: ap-northeast-1 / env: AWS_REGION)
  --registry URL           ECR レジストリ名(URL) を明示指定 (env: ECR_REGISTRY)
                           例: 123456789012.dkr.ecr.ap-northeast-1.amazonaws.com
                           (未指定時は <account-id>.dkr.ecr.<region>.amazonaws.com を組み立て)
  --repository NAME        ECR リポジトリ名 = プッシュするイメージ名 (既定: BaseImage)
  --tag-prefix PREFIX      イメージタグの接頭辞 (既定: BaseImage)。リポジトリ名とは独立に
                           指定でき、タグは <PREFIX>-<YYYYMMDDHHMMSS> となる
                           例: BaseImage-20260702153000
  --local-image NAME       compose build で生成されるローカルイメージ名 (既定: j1/base.local)
  --container-name NAME    imagedefinition.json の name (既定: --repository の値)
  --compose-file FILE      compose ファイル (既定: compose.yml)
  --compose-service NAME   ビルド対象サービス名 (未指定なら全サービス)
  --no-cache               キャッシュを破棄して compose build する
  --output FILE            imagedefinition の出力先 (既定: imagedefinition.json)
  --dry-run                実際のビルド/ログイン/タグ付け/プッシュ/ファイル出力は
                           行わず、実行される内容のプレビューのみ表示する

  --switchback-shell PATH  別チーム提供のスイッチバック用シェルのパス (source で呼び出し)
  --auto-switchback        ECR 権限が無い場合に自動でスイッチバックして継続する
  --warn-only              ECR 権限が無い場合に警告して終了する (既定)

  -h, --help               このヘルプを表示
EOF
}

# ---- 引数パース -------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --account-id)       ACCOUNT_ID="$2"; shift 2 ;;
    --region)           REGION="$2"; shift 2 ;;
    --registry)         REGISTRY="$2"; shift 2 ;;
    --repository)       REPOSITORY="$2"; shift 2 ;;
    --tag-prefix)       TAG_PREFIX="$2"; shift 2 ;;
    --local-image)      LOCAL_IMAGE="$2"; shift 2 ;;
    --container-name)   CONTAINER_NAME="$2"; shift 2 ;;
    --compose-file)     COMPOSE_FILE="$2"; shift 2 ;;
    --compose-service)  COMPOSE_SERVICE="$2"; shift 2 ;;
    --no-cache)         NO_CACHE="true"; shift ;;
    --output)           OUTPUT_FILE="$2"; shift 2 ;;
    --dry-run)          DRY_RUN="true"; shift ;;
    --switchback-shell) SWITCHBACK_SHELL="$2"; shift 2 ;;
    --auto-switchback)  AUTO_SWITCHBACK="true"; shift ;;
    --warn-only)        AUTO_SWITCHBACK="false"; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) err "不明なオプション: $1"; usage; exit 2 ;;
  esac
done

# ---- 依存コマンド確認 -------------------------------------------------------
for cmd in aws docker; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "必須コマンドが見つかりません: $cmd"
    exit 1
  fi
done

# docker compose (v2) / docker-compose (v1) の判定
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(docker-compose)
else
  err "docker compose / docker-compose が見つかりません"
  exit 1
fi

# ---- レジストリ URL の組み立て ---------------------------------------------
if [ -z "$REGISTRY" ]; then
  if [ -z "$ACCOUNT_ID" ]; then
    err "--account-id もしくは --registry を指定してください (レジストリ URL を決定できません)"
    exit 2
  fi
  REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
fi

[ -n "$CONTAINER_NAME" ] || CONTAINER_NAME="$REPOSITORY"

if [ "$DRY_RUN" = "true" ]; then
  log "*** DRY-RUN モードです。実際のビルド/ログイン/タグ付け/プッシュ/ファイル出力は行いません。 ***"
fi

# ---- ECR 操作権限チェック ---------------------------------------------------
# ecr:GetAuthorizationToken を要求する get-login-password を叩けるかどうかで判定する。
# 成功すればパスワードを取得できるので、そのまま docker login に流用する。
ECR_PASSWORD=""
check_ecr_permission() {
  ECR_PASSWORD="$(aws ecr get-login-password --region "$REGION" 2>/dev/null)"
  if [ $? -ne 0 ] || [ -z "$ECR_PASSWORD" ]; then
    return 1
  fi
  return 0
}

# ---- スイッチバック処理 -----------------------------------------------------
do_switchback() {
  if [ -z "$SWITCHBACK_SHELL" ]; then
    err "スイッチバック用シェルのパスが未指定です。--switchback-shell で指定してください。"
    return 1
  fi
  if [ ! -f "$SWITCHBACK_SHELL" ]; then
    err "スイッチバック用シェルが見つかりません: $SWITCHBACK_SHELL"
    return 1
  fi
  log "スイッチバック用シェルを source で呼び出します: $SWITCHBACK_SHELL"
  # 別チーム提供のシェルを現在のシェルに source して認証情報 / ロールを切り替える。
  # shellcheck disable=SC1090
  source "$SWITCHBACK_SHELL"
  return 0
}

log "ECR 操作権限を確認します (region=${REGION}) ..."
if ! check_ecr_permission; then
  warn "現在の操作権限では ECR を操作できません。"
  if [ "$AUTO_SWITCHBACK" = "true" ]; then
    # (B) 終了せず、自動的にスイッチバックして継続する
    log "自動スイッチバックモードです。スイッチバックを実行します。"
    if ! do_switchback; then
      err "スイッチバックに失敗しました。処理を中止します。"
      exit 1
    fi
    log "スイッチバック後に再度 ECR 操作権限を確認します ..."
    if ! check_ecr_permission; then
      err "スイッチバック後も ECR を操作できません。権限設定を確認してください。"
      exit 1
    fi
    log "スイッチバックにより ECR 操作が可能になりました。処理を継続します。"
  elif [ "$DRY_RUN" = "true" ]; then
    # dry-run では中止せず、権限が無い旨を警告してプレビューを継続する
    warn "ECR 操作権限がありませんが、DRY-RUN のため中止せずにプレビューを継続します。"
    warn "  実際に実行する場合はスイッチバック (--auto-switchback など) が必要です。"
  else
    # (A) 警告して終了する
    err "ECR への操作権限がありません。スイッチバックしてから再実行してください。"
    if [ -n "$SWITCHBACK_SHELL" ]; then
      err "  例) source \"$SWITCHBACK_SHELL\" を実行してスイッチバックしてください。"
    else
      err "  スイッチバック用シェル (別チーム提供) を source で読み込んでスイッチバックしてください。"
    fi
    err "  自動でスイッチバックする場合は --auto-switchback を付けて再実行してください。"
    exit 1
  fi
fi

# ---- ビルド -----------------------------------------------------------------
BUILD_OPTS=()
if [ "$NO_CACHE" = "true" ]; then
  BUILD_OPTS+=(--no-cache)
  log "キャッシュを破棄して (--no-cache) ビルドします。"
fi

log "docker compose build を実行します (${COMPOSE_FILE}) ..."
if [ -n "$COMPOSE_SERVICE" ]; then
  run "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" build "${BUILD_OPTS[@]}" "$COMPOSE_SERVICE" || { err "compose build に失敗しました"; exit 1; }
else
  run "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" build "${BUILD_OPTS[@]}" || { err "compose build に失敗しました"; exit 1; }
fi

# ローカルベースイメージが生成されたか確認 (dry-run ではビルドしていないためスキップ)
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] ローカルベースイメージの存在確認をスキップします: $LOCAL_IMAGE"
elif ! docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1; then
  err "ローカルベースイメージが見つかりません: $LOCAL_IMAGE (compose.yml の image 指定を確認してください)"
  exit 1
else
  log "ローカルベースイメージを確認しました: $LOCAL_IMAGE"
fi

# ---- タグ (<接頭辞>-<処理年月日時分秒>) -------------------------------------
# タグの接頭辞 (TAG_PREFIX) はリポジトリ名とは独立に --tag-prefix で指定できる。
# 例: TAG_PREFIX=BaseImage のとき BaseImage-20260702153000
IMAGE_TAG="${TAG_PREFIX}-$(date '+%Y%m%d%H%M%S')"
TARGET_IMAGE="${REGISTRY}/${REPOSITORY}:${IMAGE_TAG}"

# ---- ECR ログイン (get-login-password | docker login --password-stdin) -----
log "ECR にログインします: $REGISTRY (user=${ECR_USERNAME}) ..."
# ECR_PASSWORD は権限チェック時に取得済み。--password-stdin で安全に渡す。
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] docker login --username ${ECR_USERNAME} --password-stdin ${REGISTRY} (password は非表示)"
elif ! printf '%s' "$ECR_PASSWORD" | docker login --username "$ECR_USERNAME" --password-stdin "$REGISTRY"; then
  err "docker login に失敗しました: $REGISTRY"
  exit 1
fi

# ---- タグ付け & プッシュ ----------------------------------------------------
log "docker image tag ${LOCAL_IMAGE} -> ${TARGET_IMAGE}"
if ! run docker image tag "$LOCAL_IMAGE" "$TARGET_IMAGE"; then
  err "docker image tag に失敗しました"
  exit 1
fi

log "docker push ${TARGET_IMAGE} ..."
if ! run docker push "$TARGET_IMAGE"; then
  err "docker push に失敗しました"
  exit 1
fi

# ---- imagedefinition.json 出力 ---------------------------------------------
# CodePipeline の ECS デプロイ等で使われる標準フォーマット。
IMAGEDEF_CONTENT="$(cat <<EOF
[
  {
    "name": "${CONTAINER_NAME}",
    "imageUri": "${TARGET_IMAGE}"
  }
]
EOF
)"

if [ "$DRY_RUN" = "true" ]; then
  log "[DRY-RUN] ${OUTPUT_FILE} に以下を出力します (実際には書き込みません):"
  printf '%s\n' "$IMAGEDEF_CONTENT"
else
  printf '%s\n' "$IMAGEDEF_CONTENT" > "$OUTPUT_FILE"
  log "imagedefinition を出力しました: ${OUTPUT_FILE}"
fi

log "  name     = ${CONTAINER_NAME}"
log "  imageUri = ${TARGET_IMAGE}"
if [ "$DRY_RUN" = "true" ]; then
  log "DRY-RUN が完了しました (実際の変更は行われていません)。"
else
  log "完了しました。"
fi
