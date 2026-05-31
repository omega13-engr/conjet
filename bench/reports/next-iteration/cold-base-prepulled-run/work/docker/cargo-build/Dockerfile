# syntax=docker/dockerfile:1.7
FROM rust:1-alpine
WORKDIR /app
COPY Cargo.toml ./
COPY deps ./deps
COPY src ./src
ARG CONJET_BENCH_ITERATION=0
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    echo "$CONJET_BENCH_ITERATION" >/tmp/conjet-bench-iteration \
    && cargo build --release