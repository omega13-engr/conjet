FROM alpine:3.22 AS compiler
RUN apk add --no-cache build-base
WORKDIR /src
COPY memory-fixture.c .
RUN cc -std=c11 -O2 -Wall -Wextra -Werror -o /memory-fixture memory-fixture.c

FROM alpine:3.22 AS runtime
COPY --from=compiler /memory-fixture /usr/local/bin/memory-fixture
ENTRYPOINT ["/usr/local/bin/memory-fixture"]
CMD ["serve", "64"]

FROM runtime AS build-workload
ARG E2E_BUILD_ID=manual
ARG E2E_BUILD_MIB=512
RUN test -n "$E2E_BUILD_ID" && memory-fixture build "$E2E_BUILD_MIB" /tmp/conjet-build-canary
