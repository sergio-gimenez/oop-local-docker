FROM python:3.12-slim

ARG KUBECTL_VERSION=v1.28.2
ADD https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl /usr/local/bin/kubectl
RUN chmod +x /usr/local/bin/kubectl \
    && pip install --no-cache-dir fastapi==0.115.* uvicorn==0.32.*

WORKDIR /app
COPY app.py .
EXPOSE 8090
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8090"]
