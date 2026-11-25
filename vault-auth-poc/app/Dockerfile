FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
USER 10001:10001
EXPOSE 8080 8443
CMD ["sh","-c","uvicorn main:app --host 0.0.0.0 --port 8080 & exec uvicorn main:app --host 0.0.0.0 --port 8443 --ssl-keyfile=/tls/tls.key --ssl-certfile=/tls/tls.crt --ssl-ca-certs=/tls/ca.crt --ssl-cert-reqs=2"]
