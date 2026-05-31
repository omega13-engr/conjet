FROM alpine:3.20
WORKDIR /app
COPY node_modules ./node_modules
RUN find node_modules -type f | wc -l >/node-modules-file-count
CMD ["cat", "/node-modules-file-count"]