# syntax=docker/dockerfile:1
FROM alpine:3.21 AS first
COPY conjet-policy-probe /probe
RUN set -e; /probe --verify-build-policy; date +%s > /first-start; sleep 60; yes conjet-stream | head -c 131072; printf '\nconjet-stream-complete\n'; date +%s > /first-end; echo first > /first
FROM alpine:3.21 AS second
RUN date +%s > /second-start; sleep 3; date +%s > /second-end; echo second > /second
FROM alpine:3.21
COPY --from=first /first /first-start /first-end /probe /
COPY --from=second /second /second-start /second-end /
CMD ["sh", "-c", "test $(cat /second-start) -lt $(cat /first-end) && test $(cat /first-start) -lt $(cat /second-end) && cat /first /second"]
