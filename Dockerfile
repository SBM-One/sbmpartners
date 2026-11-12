# The agent team, packaged to run on a small cloud server (Railway, Fly.io or similar).
# Set DATABASE_URL and ANTHROPIC_API_KEY as secrets in the hosting dashboard, never in this file.
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY agents ./agents
CMD ["python", "-m", "agents.team", "run"]
