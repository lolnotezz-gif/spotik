FROM python:3.12-slim

RUN apt-get update && apt-get install -y ffmpeg && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY audio/ /app/audio/
COPY server.py /app/server.py

ENV PORT=8080
EXPOSE 8080

CMD ["python", "server.py"]
