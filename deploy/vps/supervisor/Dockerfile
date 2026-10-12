# Supervisor image: Alpine + ffmpeg + curl + python3.
#   curl   -> poll MediaMTX control API
#   ffmpeg -> copy live / loop fallback
#   python3-> tiny control HTTP server (operator END/RESUME per tatami)
FROM alpine:3.20
RUN apk add --no-cache ffmpeg curl python3
COPY supervisor.sh /supervisor/supervisor.sh
COPY ctl.py /supervisor/ctl.py
RUN chmod +x /supervisor/supervisor.sh
EXPOSE 8090
ENTRYPOINT ["/bin/sh", "/supervisor/supervisor.sh"]
