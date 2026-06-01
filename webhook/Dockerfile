FROM python:3.11-slim

WORKDIR /app

# Install kubectl and helm CLI
RUN apt-get update && \
    apt-get install -y git && \
    rm -rf /var/lib/apt/lists/*

# Install helm diff plugin
RUN helm plugin install https://github.com/databus23/helm-diff

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
