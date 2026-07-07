FROM python:3.12-slim

RUN pip install --no-cache-dir fastmcp httpx

COPY server.py /app/server.py

WORKDIR /app

USER 10001

EXPOSE 8000

CMD ["python", "server.py"]
