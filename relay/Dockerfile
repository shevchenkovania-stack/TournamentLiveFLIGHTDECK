FROM alpine:3.20

# ffmpeg only (no bash needed). Keeps the image small and POSIX-portable.
RUN apk add --no-cache ffmpeg

COPY relayer.sh /relayer/relayer.sh
RUN chmod +x /relayer/relayer.sh

ENTRYPOINT ["/bin/sh", "/relayer/relayer.sh"]
