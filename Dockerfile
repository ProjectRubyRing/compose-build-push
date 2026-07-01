# ベースイメージのサンプル。実際のベースイメージ内容に置き換えてください。
FROM public.ecr.aws/docker/library/alpine:3.20

LABEL org.opencontainers.image.title="j1/base.local"

# 例: 共通で入れておきたいパッケージなど
RUN apk add --no-cache ca-certificates

CMD ["/bin/sh"]
